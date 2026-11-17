import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:aurum_vpn/src/services/app_update_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/update_http_fixture.dart';

const _version = '9.8.7';
const _asset = 'fixture-update.apk';
const _zipPrefix = [0x50, 0x4B, 0x03, 0x04]; // Header only; not an APK.
final _primary = Uri.parse('https://updates.example.invalid/primary.apk');
final _mirror = Uri.parse('https://updates.example.invalid/mirror.apk');

void main() {
  test(
    'invalid version refuses download before opening the cache or HTTP',
    () async {
      await _withCache((root) async {
        final client = UpdateHttpClient(
          (_) => fail('Invalid version requested HTTP'),
        );
        final updater = AppUpdateService(client: client);
        await expectLater(
          updater.download(
            _update(version: 'not-a-version'),
            onProgress: (_) {},
          ),
          throwsA(_failure('Invalid update version.')),
        );
        expect(client.requests, isEmpty);
        expect(await root.list().isEmpty, isTrue);
      });
    },
  );

  test(
    'cache discards a truncated ZIP prefix before trying the mirror',
    () async {
      await _withCache((root) async {
        final cacheFile = _cached(root);
        final finalBytes = [..._zipPrefix, 2, 3];
        bool? fileExistedAtMirror;
        final client = UpdateHttpClient(
          (request) => UpdateHttpResponse(
            contentLength: 6,
            chunks: [request.uri == _primary ? _zipPrefix : finalBytes],
          ),
          beforeOpen: (request) async {
            if (request.uri == _mirror) {
              fileExistedAtMirror = await cacheFile.exists();
            }
          },
        );
        final progress = <double?>[];
        final result = await AppUpdateService(client: client).download(
          _update(size: 6, fallbacks: [_primary, _mirror, _mirror]),
          onProgress: progress.add,
        );

        expect(client.requests.map((request) => request.uri), [
          _primary,
          _mirror,
        ]);
        expect(fileExistedAtMirror, isFalse);
        expect(result.path, cacheFile.path);
        expect(await result.readAsBytes(), finalBytes);
        expect(progress.last, 1.0);
      });
    },
  );

  test('an empty response is never returned or left in the cache', () async {
    await _withCache((root) async {
      final client = UpdateHttpClient(
        (_) => UpdateHttpResponse(contentLength: 0),
      );
      await expectLater(
        AppUpdateService(
          client: client,
        ).download(_update(), onProgress: (_) {}),
        throwsA(_failure('APK file is empty.')),
      );
      expect(client.requests, hasLength(1));
      expect(await _cached(root).exists(), isFalse);
    });
  });

  test('wrong archive size is rejected with no cached partial data', () async {
    await _withCache((root) async {
      final client = UpdateHttpClient(
        (_) => UpdateHttpResponse(contentLength: 4, chunks: [_zipPrefix]),
      );
      await expectLater(
        AppUpdateService(
          client: client,
        ).download(_update(size: 6), onProgress: (_) {}),
        throwsA(_failure('APK size mismatch: expected 6 bytes, got 4.')),
      );
      expect(client.requests, hasLength(1));
      expect(await _cached(root).exists(), isFalse);
    });
  });

  for (final (name, reportedStatus, declaredLength, expectedError) in [
    ('HTTP error', HttpStatus.notFound, 4, 'HTTP 404'),
    ('oversized APK', HttpStatus.ok, 512 * 1024 * 1024 + 1, '512 MiB'),
  ]) {
    test('$name aborts before reading the download body', () async {
      await _withCache((root) async {
        final response = UpdateHttpResponse(
          statusCode: reportedStatus,
          contentLength: declaredLength,
          chunks: [_zipPrefix],
        );
        final client = UpdateHttpClient((_) => response);
        await expectLater(
          AppUpdateService(
            client: client,
          ).download(_update(size: 4), onProgress: (_) {}),
          throwsA(_failure(expectedError)),
        );
        expect(client.requests.single.aborts, 1);
        expect(response.readChunks, 0);
        expect(await _cached(root).exists(), isFalse);
      });
    });
  }

  test(
    'streamed APK rejects the first byte beyond the cumulative limit',
    () async {
      await _withCache((root) async {
        const bytesPerMiB = 1024 * 1024;
        const acceptedChunks = 512;
        final block = Uint8List(bytesPerMiB)
          ..setRange(0, _zipPrefix.length, _zipPrefix);
        final response = UpdateHttpResponse(
          // No declared size: the limit has to be enforced across chunks.
          chunks: [
            for (var i = 0; i < acceptedChunks; i++) block,
            const [1], // First byte over the limit.
            const [2], // Must not be consumed after cancellation.
          ],
        );
        final client = UpdateHttpClient((_) => response);
        final diskPath = _cached(root);
        final output = _CountingApkFile(diskPath.path);
        final progress = <double?>[];

        await IOOverrides.runZoned(
          () => expectLater(
            AppUpdateService(
              client: client,
            ).download(_update(), onProgress: progress.add),
            throwsA(_failure('Update APK exceeds the 512 MiB safety limit.')),
          ),
          createFile: (path) {
            if (path != diskPath.path) {
              throw StateError('Unexpected file in APK limit fixture');
            }
            return output;
          },
        );

        expect(client.requests.single.uri, _primary);
        expect(client.requests.single.aborts, 1);
        expect(response.readChunks, acceptedChunks + 1);
        expect(output.sink.bytes, acceptedChunks * bytesPerMiB);
        expect(output.sink.chunks, acceptedChunks);
        expect(progress, List<double?>.filled(acceptedChunks, null));
        expect(output.events, ['open', 'close', 'delete']);
        expect(await output.exists(), isFalse);
        expect(await diskPath.exists(), isFalse);
      });
    },
  );

  test('rejects a cleartext download URL without requesting it', () async {
    await _withCache((root) async {
      final client = UpdateHttpClient(
        (_) => fail('Cleartext opened a request'),
      );
      await expectLater(
        AppUpdateService(client: client).download(
          _update(url: Uri.parse('http://updates.example.invalid/fixture.apk')),
          onProgress: (_) {},
        ),
        throwsA(_failure('require HTTPS')),
      );
      expect(client.requests, isEmpty);
      expect(await _cached(root).exists(), isFalse);
    });
  });

  test(
    'rejects a reported cleartext redirect before writing APK data',
    () async {
      await _withCache((root) async {
        // The history is supplied by the fake, not followed on the network.
        final response = UpdateHttpResponse(
          contentLength: 4,
          chunks: [_zipPrefix],
          redirectLocations: [
            Uri.parse('http://updates.example.invalid/redirect.apk'),
          ],
        );
        final client = UpdateHttpClient((_) => response);
        await expectLater(
          AppUpdateService(
            client: client,
          ).download(_update(size: 4), onProgress: (_) {}),
          throwsA(_failure('require HTTPS')),
        );
        expect(client.requests.single.uri, _primary);
        expect(response.readChunks, 0);
        expect(await _cached(root).exists(), isFalse);
      });
    },
  );

  test(
    'download response deadline aborts the stuck request before a retry',
    () async {
      await _withCache((root) async {
        final stalled = Completer<HttpClientResponse>();
        var attempts = 0;
        final client = UpdateHttpClient(
          (_) => attempts++ == 0
              ? stalled.future
              : UpdateHttpResponse(contentLength: 4, chunks: [_zipPrefix]),
        );
        final scheduled = <Duration>[];
        final result = await _accelerateResponseAndBackoff(
          scheduled,
          () => AppUpdateService(
            client: client,
          ).download(_update(size: 4), onProgress: (_) {}),
        );
        expect(scheduled.take(2), [
          const Duration(seconds: 60),
          const Duration(seconds: 2),
        ]);
        expect(client.requests.map((request) => request.uri), [
          _primary,
          _primary,
        ]);
        expect(client.requests.map((request) => request.aborts), [1, 0]);
        expect(result.path, _cached(root).path);
        expect(await result.readAsBytes(), _zipPrefix);

        final late = UpdateHttpResponse(
          contentLength: 6,
          chunks: [
            [..._zipPrefix, 7, 8],
          ],
        );
        stalled.complete(late);
        await Future<void>.delayed(Duration.zero);
        expect(late.readChunks, 0);
        expect(await result.readAsBytes(), _zipPrefix);
      });
    },
  );
}

Future<void> _withCache(Future<void> Function(Directory root) run) async {
  final build = await Directory('build').absolute.create(recursive: true);
  final root = await build.createTemp('updater-fixture-');
  addTearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });
  await IOOverrides.runZoned(
    () => run(root),
    getSystemTempDirectory: () => root,
  );
}

File _cached(Directory root) =>
    File.fromUri(root.uri.resolve('yurich_connect_updates/$_version/$_asset'));

AppUpdateInfo _update({
  String version = _version,
  Uri? url,
  int? size,
  List<Uri> fallbacks = const [],
}) => AppUpdateInfo(
  version: version,
  assetName: _asset,
  downloadUrl: url ?? _primary,
  size: size,
  fallbackDownloadUrls: fallbacks,
);

Matcher _failure(String text) => isA<StateError>().having(
  (error) => error.toString(),
  'message',
  contains(text),
);

/// The byte count and lifecycle are real observations; no contents are stored.
final class _CountingApkFile extends Fake implements File {
  _CountingApkFile(this.path);

  @override
  final String path;
  final events = <String>[];
  late final sink = _CountingApkSink(events);
  var _exists = false;

  @override
  Future<bool> exists() async => _exists;

  @override
  IOSink openWrite({FileMode mode = FileMode.write, Encoding encoding = utf8}) {
    events.add('open');
    _exists = true;
    return sink;
  }

  @override
  Future<File> delete({bool recursive = false}) async {
    events.add('delete');
    _exists = false;
    return this;
  }
}

final class _CountingApkSink extends Fake implements IOSink {
  _CountingApkSink(this.events);

  final List<String> events;
  var bytes = 0;
  var chunks = 0;

  @override
  void add(List<int> data) {
    bytes += data.length;
    chunks++;
  }

  @override
  Future<void> close() async => events.add('close');
}

// Keep real filesystem futures; accelerate only the specified fixture timers.
Future<T> _accelerateResponseAndBackoff<T>(
  List<Duration> scheduled,
  Future<T> Function() action,
) => runZoned(
  action,
  zoneSpecification: ZoneSpecification(
    createTimer: (self, parent, zone, duration, callback) {
      if (duration == const Duration(seconds: 60) ||
          duration == const Duration(seconds: 2)) {
        scheduled.add(duration);
        return parent.createTimer(zone, Duration.zero, callback);
      }
      return parent.createTimer(zone, duration, callback);
    },
  ),
);
