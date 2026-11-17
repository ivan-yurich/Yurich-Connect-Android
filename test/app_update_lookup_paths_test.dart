import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:aurum_vpn/src/services/app_update_service.dart';
// Use the fake clock already supplied by flutter_test.
// ignore: depend_on_referenced_packages
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/update_http_fixture.dart';

const _installed = '1.0.132';
const _newest = '1.0.141';
const _abis = ['arm64-v8a'];
final _feed = Uri.parse('https://updates.example.invalid/stable.json');
final _releasePage = Uri.parse(
  'https://updates.example.invalid/releases/latest',
);

void main() {
  test('a nonpositive lookup timeout never starts an HTTP request', () async {
    final client = UpdateHttpClient((_) => fail('Invalid timeout opened HTTP'));
    final updater = _service(client);
    for (final timeout in [Duration.zero, const Duration(seconds: -1)]) {
      await expectLater(
        _latest(updater, timeout: timeout),
        throwsArgumentError,
      );
    }
    expect(client.requests, isEmpty);
  });

  test(
    'GitHub tag fallback selects only an available ABI asset via HEAD',
    () async {
      final heads = <UpdateHttpResponse>[];
      final client = UpdateHttpClient((request) {
        if (request.uri == _feed) {
          return UpdateHttpResponse(statusCode: HttpStatus.notFound);
        }
        if (request.uri == _releasePage) return _tag(_newest);
        final head = request.uri.pathSegments.last.contains('arm64-v8a')
            ? UpdateHttpResponse(
                statusCode: HttpStatus.notFound,
                contentLength: 100,
              )
            : UpdateHttpResponse(contentLength: 2048);
        heads.add(head);
        return head;
      });

      final update = (await _latest(
        _service(client),
        abis: const ['arm64-v8a', 'armeabi-v7a'],
      ))!;
      expect(update.version, _newest);
      expect(
        update.assetName,
        'YurichConnect-android-armeabi-v7a-v$_newest.apk',
      );
      expect(update.size, 2048);
      expect(
        update.downloadUrl.path,
        endsWith('/download/v$_newest/${update.assetName}'),
      );
      expect(client.requests.map((request) => request.method), [
        'GET',
        'GET',
        'HEAD',
        'HEAD',
      ]);
      expect(client.requests[1].followRedirects, isFalse);
      expect(client.requests.last.uri, update.downloadUrl);
      expect(heads.map((response) => response.drains), [1, 1]);
      expect(client.requests.map((request) => request.aborts), [1, 1, 1, 1]);
    },
  );

  test('HEAD failure and zero length do not qualify a split APK', () async {
    var heads = 0;
    final client = UpdateHttpClient((request) {
      if (request.uri == _feed) {
        return UpdateHttpResponse(statusCode: HttpStatus.notFound);
      }
      if (request.uri == _releasePage) return _tag(_newest);
      return switch (++heads) {
        1 => throw const SocketException('Fixture HEAD failed'),
        2 => UpdateHttpResponse(contentLength: 0),
        _ => UpdateHttpResponse(statusCode: HttpStatus.notFound),
      };
    });

    final update = (await _latest(_service(client)))!;
    expect(update.assetName, 'YurichConnect-android-release.apk');
    expect(update.version, _newest);
    expect(update.size, isNull);
    expect(heads, 3);
    expect(
      client.requests.skip(2).map((request) => request.method),
      everyElement('HEAD'),
    );
    expect(
      update.downloadUrl.path,
      endsWith('/download/v$_newest/${update.assetName}'),
    );
  });

  for (final tag in ['invalid-tag', '1.0.142-test.20261117.1']) {
    test('stable tag fallback ignores $tag without probing any APK', () async {
      final client = UpdateHttpClient(
        (request) => request.uri == _feed
            ? UpdateHttpResponse(statusCode: HttpStatus.notFound)
            : _tag(tag),
      );
      expect(await _latest(_service(client)), isNull);
      expect(client.requests.map((request) => request.uri), [
        _feed,
        _releasePage,
      ]);
      expect(
        client.requests.map((request) => request.method),
        everyElement('GET'),
      );
    });
  }

  test(
    'tag fallback never advertises the already installed stable version',
    () async {
      final client = UpdateHttpClient(
        (request) => request.uri == _feed
            ? UpdateHttpResponse(statusCode: HttpStatus.notFound)
            : request.uri == _releasePage
            ? _tag(_installed)
            : UpdateHttpResponse(contentLength: 100),
      );
      expect(await _latest(_service(client)), isNull);
      expect(client.requests.map((request) => request.method), [
        'GET',
        'GET',
        'HEAD',
      ]);
    },
  );

  for (final (name, reply, error) in [
    (
      'array in stable feed',
      () => UpdateHttpResponse.json([]),
      'metadata must be an object',
    ),
    (
      'asset without download address',
      () => UpdateHttpResponse.json(_release(includeUrl: false)),
      'no download URL',
    ),
    (
      'reported cleartext metadata redirect',
      () => UpdateHttpResponse(
        chunks: [
          [0x7B, 0x7D],
        ],
        redirectLocations: [
          Uri.parse('http://updates.example.invalid/reported'),
        ],
      ),
      'require HTTPS',
    ),
  ]) {
    test('$name is not treated as an up-to-date result', () async {
      final invalid = reply();
      final client = UpdateHttpClient(
        (request) => request.uri == _feed ? invalid : UpdateHttpResponse(),
      );
      await expectLater(_latest(_service(client)), throwsA(_failure(error)));
      expect(client.requests.map((request) => request.uri), [
        _feed,
        _releasePage,
      ]);
      if (name.startsWith('reported cleartext')) expect(invalid.readChunks, 0);
    });
  }

  for (final announced in [true, false]) {
    test(
      'excess metadata is rejected with announced length=$announced',
      () async {
        const limit = 1024 * 1024;
        final response = announced
            ? UpdateHttpResponse(
                contentLength: limit + 1,
                chunks: [
                  [0x7B, 0x7D],
                ],
              )
            : UpdateHttpResponse(
                chunks: [
                  Uint8List(limit),
                  [0x20],
                ],
              );
        final client = UpdateHttpClient(
          (request) => request.uri == _feed ? response : UpdateHttpResponse(),
        );
        await expectLater(
          _latest(_service(client)),
          throwsA(_failure('1 MiB safety limit')),
        );
        expect(response.drains, announced ? 1 : 0);
        expect(response.readChunks, announced ? 1 : 2);
        expect(client.requests.map((request) => request.uri), [
          _feed,
          _releasePage,
        ]);
      },
    );
  }

  test(
    'late getUrl after overall timeout is aborted without request.close',
    () async {
      late final UpdateHttpClient client;
      late final AppUpdateService updater;
      fakeAsync((clock) {
        final gate = Completer<void>();
        var opens = 0;
        client = UpdateHttpClient(
          (_) => UpdateHttpResponse.json(_release()),
          beforeOpen: (_) async {
            if (opens++ == 0) await gate.future;
          },
        );
        updater = _service(client);
        final old = _observe(
          _latest(updater, timeout: const Duration(seconds: 2)),
        );
        clock.flushMicrotasks();
        final late = client.requests.single;
        expect(late.closes, 0);
        clock.elapse(const Duration(seconds: 2));
        expect(old.single, isA<TimeoutException>());
        expect(late.aborts, 0);

        gate.complete();
        clock.flushMicrotasks();
        expect(late.aborts, 1);
        expect(late.closes, 0);
        expect(client.requests, hasLength(1));
      });
      final fresh = await _latest(updater);
      expect(fresh?.version, _newest);
      expect(client.requests.map((request) => request.uri), [_feed, _feed]);
    },
  );

  test(
    'per-endpoint HEAD timeout releases a stalled candidate and allows the next',
    () {
      fakeAsync((clock) {
        final deferred = Completer<HttpClientResponse>();
        var heads = 0;
        final client = UpdateHttpClient((request) {
          if (request.uri == _feed) {
            return UpdateHttpResponse(statusCode: HttpStatus.notFound);
          }
          if (request.uri == _releasePage) return _tag(_newest);
          return heads++ == 0
              ? deferred.future
              : UpdateHttpResponse(contentLength: 1024);
        });
        final outcomes = _observe(
          _latest(
            _service(client, endpointTimeout: const Duration(seconds: 2)),
            abis: const ['arm64-v8a', 'armeabi-v7a'],
          ),
        );
        clock.flushMicrotasks();
        final stalled = client.requests.last;
        expect(stalled.method, 'HEAD');
        expect(stalled.closes, 1);
        expect(outcomes, isEmpty);
        clock.elapse(const Duration(seconds: 2));
        expect(stalled.aborts, 1);
        expect(
          outcomes.single,
          isA<AppUpdateInfo>().having(
            (update) => update.assetName,
            'asset name',
            'YurichConnect-android-armeabi-v7a-v$_newest.apk',
          ),
        );
        expect(client.requests.map((request) => request.method), [
          'GET',
          'GET',
          'HEAD',
          'HEAD',
        ]);
        deferred.complete(UpdateHttpResponse(contentLength: 2048));
        clock.flushMicrotasks();
        expect(client.requests, hasLength(4));
      });
    },
  );

  test('fallback retry budget stops after four temporary failures', () {
    fakeAsync((clock) {
      final client = UpdateHttpClient(
        (_) => UpdateHttpResponse(statusCode: HttpStatus.serviceUnavailable),
      );
      final result = _observe(
        _latest(
          _service(
            client,
            sources: const [],
            endpointTimeout: const Duration(seconds: 30),
          ),
        ),
      );
      clock.flushMicrotasks();
      expect(client.requests, hasLength(1));
      for (final (delay, count) in [(2, 2), (5, 3), (10, 4)]) {
        clock.elapse(Duration(seconds: delay));
        expect(client.requests, hasLength(count));
      }
      expect(result.single, _failure('HTTP 503'));
      clock.elapse(const Duration(seconds: 30));
      expect(client.requests, hasLength(4));
      expect(
        client.requests.map((request) => request.uri),
        everyElement(_releasePage),
      );
      expect(client.requests.map((request) => request.aborts), everyElement(1));
    });
  });
}

AppUpdateService _service(
  UpdateHttpClient client, {
  List<Uri>? sources,
  Duration endpointTimeout = const Duration(seconds: 12),
}) => AppUpdateService(
  client: client,
  releaseApiUris: sources ?? [_feed],
  githubReleasePageUri: _releasePage,
  metadataEndpointTimeout: endpointTimeout,
);

Future<AppUpdateInfo?> _latest(
  AppUpdateService updater, {
  List<String> abis = _abis,
  Duration timeout = const Duration(seconds: 60),
}) => updater.findLatest(
  currentVersion: _installed,
  supportedAbis: abis,
  timeout: timeout,
);

UpdateHttpResponse _tag(String tag) => UpdateHttpResponse(
  statusCode: HttpStatus.found,
  headers: {HttpHeaders.locationHeader: 'tag/v$tag'},
);

Map<String, Object?> _release({bool includeUrl = true}) => {
  'tag_name': 'v$_newest',
  'assets': [
    {
      'name': 'YurichConnect-android-arm64-v8a-v$_newest.apk',
      'state': 'uploaded',
      if (includeUrl)
        'browser_download_url': 'https://updates.example.invalid/fixture.apk',
      'size': 4,
    },
  ],
};

List<Object?> _observe<T>(Future<T> future) {
  final result = <Object?>[];
  unawaited(
    future.then<void>(
      result.add,
      onError: (Object error, StackTrace _) => result.add(error),
    ),
  );
  return result;
}

Matcher _failure(String text) => isA<StateError>().having(
  (error) => error.toString(),
  'message',
  contains(text),
);
