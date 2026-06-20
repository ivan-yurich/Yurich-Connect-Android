import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:aurum_vpn/src/services/app_update_service.dart';

void main() {
  test(
    'continues to next release endpoint when first release is stale',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));

      server.listen((request) async {
        final stale = request.uri.path == '/stale';
        final payload = {
          'tag_name': stale ? 'v1.0.49' : 'v1.0.51',
          'assets': [
            {
              'name': 'YurichConnect-android-release.apk',
              'browser_download_url':
                  'http://127.0.0.1:${server.port}/download.apk',
              'size': 123,
            },
          ],
        };
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType.json
          ..write(jsonEncode(payload));
        await request.response.close();
      });

      final service = AppUpdateService(
        releaseApiUris: [
          Uri.parse('http://127.0.0.1:${server.port}/stale'),
          Uri.parse('http://127.0.0.1:${server.port}/latest'),
        ],
      );

      final update = await service.findLatest(
        currentVersion: '1.0.50',
        supportedAbis: const ['arm64-v8a'],
      );

      expect(update, isNotNull);
      expect(update!.version, '1.0.51');
      expect(update.assetName, 'YurichConnect-android-release.apk');
    },
  );

  test('prefers ABI split APK over universal release APK', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));

    server.listen((request) async {
      final payload = {
        'tag_name': 'v1.0.62',
        'assets': [
          {
            'name': 'YurichConnect-android-release.apk',
            'browser_download_url':
                'http://127.0.0.1:${server.port}/universal.apk',
            'size': 97988903,
          },
          {
            'name': 'YurichConnect-android-arm64-v8a-v1.0.62.apk',
            'browser_download_url': 'http://127.0.0.1:${server.port}/arm64.apk',
            'size': 34563166,
          },
        ],
      };
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType.json
        ..write(jsonEncode(payload));
      await request.response.close();
    });

    final service = AppUpdateService(
      releaseApiUris: [Uri.parse('http://127.0.0.1:${server.port}/latest')],
    );

    final update = await service.findLatest(
      currentVersion: '1.0.61',
      supportedAbis: const ['arm64-v8a', 'armeabi-v7a'],
    );

    expect(update, isNotNull);
    expect(update!.version, '1.0.62');
    expect(update.assetName, 'YurichConnect-android-arm64-v8a-v1.0.62.apk');
  });

  test(
    'reuses a complete downloaded APK instead of downloading again',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));

      final assetName =
          'YurichConnect-test-${DateTime.now().microsecondsSinceEpoch}.apk';
      final cachedFile = File(
        '${Directory.systemTemp.path}${Platform.pathSeparator}'
        'yurich_connect_updates${Platform.pathSeparator}$assetName',
      );
      addTearDown(() async {
        if (await cachedFile.exists()) {
          await cachedFile.delete();
        }
      });

      var downloadCount = 0;
      server.listen((request) async {
        downloadCount += 1;
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentLength = 3
          ..add(const [1, 2, 3]);
        await request.response.close();
      });

      final service = AppUpdateService();
      final update = AppUpdateInfo(
        version: '1.0.63',
        assetName: assetName,
        downloadUrl: Uri.parse('http://127.0.0.1:${server.port}/update.apk'),
        size: 3,
      );

      final first = await service.download(update, onProgress: (_) {});
      final second = await service.download(update, onProgress: (_) {});

      expect(first.path, second.path);
      expect(await second.readAsBytes(), const [1, 2, 3]);
      expect(downloadCount, 1);
    },
  );
}
