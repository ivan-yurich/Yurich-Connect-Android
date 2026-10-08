import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:aurum_vpn/src/services/app_update_service.dart';

void main() {
  Future<AppUpdateService> testingService(Object payload) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      expect(request.uri.path, '/releases');
      request.response
        ..headers.contentType = ContentType.json
        ..write(jsonEncode(payload));
      await request.response.close();
    });
    return AppUpdateService(
      testingReleaseApiUri: Uri.parse(
        'http://127.0.0.1:${server.port}/releases',
      ),
    );
  }

  Map<String, Object> release(
    String version, {
    bool draft = false,
    bool prerelease = true,
    String? assetName,
    String state = 'uploaded',
  }) => {
    'tag_name': 'v$version',
    'draft': draft,
    'prerelease': prerelease,
    'assets': [
      {
        'name': assetName ?? 'YurichConnect-android-arm64-v8a-v$version.apk',
        'browser_download_url':
            'https://github.com/ivan-yurich/Yurich-Connect-Android/releases/download/v$version/${assetName ?? 'YurichConnect-android-arm64-v8a-v$version.apk'}',
        'state': state,
        'size': 4,
      },
    ],
  };

  const currentTest = '1.0.128-test.20261007.9';
  const nextTest = '1.0.128-test.20261008.10';

  test(
    'manual and automatic lookups share only an in-flight request',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      var requests = 0;
      server.listen((request) async {
        requests += 1;
        request.response
          ..headers.contentType = ContentType.json
          ..write(jsonEncode([release(nextTest)]));
        await request.response.close();
      });
      final service = AppUpdateService(
        testingReleaseApiUri: Uri.parse(
          'http://127.0.0.1:${server.port}/releases',
        ),
      );
      Future<AppUpdateInfo?> lookup() => service.findLatest(
        currentVersion: currentTest,
        supportedAbis: const ['arm64-v8a'],
      );
      final first = lookup();
      final second = lookup();
      expect(identical(first, second), isTrue);
      final result = await Future.wait([first, second]);
      expect(result.map((update) => update!.version), [nextTest, nextTest]);
      expect(requests, 1);
      expect((await lookup())!.version, nextTest);
      expect(requests, 2);
    },
  );

  test('testing channel selects a newer published phone prerelease', () async {
    final service = await testingService([
      release(nextTest),
      release(currentTest),
      release('1.0.127', prerelease: false),
    ]);
    final update = await service.findLatest(
      currentVersion: currentTest,
      supportedAbis: const ['arm64-v8a'],
    );
    expect(update!.version, nextTest);
    expect(update.downloadUrl.path, contains('/v$nextTest/'));
    expect(update.fallbackDownloadUrls, isNotEmpty);
    expect(
      update.fallbackDownloadUrls.every(
        (uri) =>
            uri.path.contains('/v$nextTest/') && !uri.path.contains('/latest/'),
      ),
      isTrue,
    );
  });

  test('selects newest testing iteration from an unordered list', () async {
    final service = await testingService([
      release('1.0.128-test.20261008.9'),
      release(nextTest),
      release('1.0.128-test.20261008.2'),
    ]);
    final update = await service.findLatest(
      currentVersion: currentTest,
      supportedAbis: const ['arm64-v8a'],
    );
    expect(update!.version, nextTest);
  });

  test('ignores draft, TV, arbitrary APK and incomplete upload', () async {
    final service = await testingService([
      release('9.0.0-test.20261008.1', draft: true),
      release('9.0.0-tv.20261008.1', assetName: 'YurichConnect-TV-arm.apk'),
      release('9.0.0-test.20261008.2', assetName: 'unrelated-arm64-v8a.apk'),
      release('9.0.0-test.20261008.3', state: 'new'),
      release(nextTest),
    ]);
    final update = await service.findLatest(
      currentVersion: currentTest,
      supportedAbis: const ['arm64-v8a'],
    );
    expect(update!.version, nextTest);
  });

  test(
    'does not select an incompatible APK or guess when ABI is unknown',
    () async {
      final service = await testingService([release(nextTest)]);
      for (final abis in [
        <String>[],
        ['armeabi-v7a'],
        ['x86_64'],
      ]) {
        expect(
          await service.findLatest(
            currentVersion: currentTest,
            supportedAbis: abis,
          ),
          isNull,
        );
      }
    },
  );

  test('does not advertise the installed or older testing build', () async {
    final service = await testingService([
      release(currentTest),
      release('1.0.128-test.20261007.8'),
    ]);
    expect(
      await service.findLatest(
        currentVersion: currentTest,
        supportedAbis: const ['arm64-v8a'],
      ),
      isNull,
    );
  });

  test('testing users can move to a newer stable phone release', () async {
    final service = await testingService([
      release(nextTest),
      release('1.0.129', prerelease: false),
    ]);
    final update = await service.findLatest(
      currentVersion: currentTest,
      supportedAbis: const ['arm64-v8a'],
    );
    expect(update!.version, '1.0.129');
  });

  test(
    'rejects malformed testing feed instead of treating it as no updates',
    () async {
      final service = await testingService({'tag_name': 'v$nextTest'});
      await expectLater(
        service.findLatest(
          currentVersion: currentTest,
          supportedAbis: const ['arm64-v8a'],
        ),
        throwsStateError,
      );
    },
  );

  test('test tag and prerelease flag must agree', () async {
    final service = await testingService([
      release('1.0.999', prerelease: true),
      release('1.0.999-test.20261008.1', prerelease: false),
      release(nextTest),
    ]);
    final update = await service.findLatest(
      currentVersion: currentTest,
      supportedAbis: const ['arm64-v8a'],
    );
    expect(update!.version, nextTest);
  });

  test('stable channel skips prerelease and draft metadata', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final requested = <String>[];
    server.listen((request) async {
      requested.add(request.uri.path);
      final payload = switch (request.uri.path) {
        '/test' => release('9.0.0-test.20261008.1'),
        '/draft' => release('9.0.0', draft: true, prerelease: false),
        '/tv' => release('9.0.0-tv.20261008.1'),
        _ => release('1.0.129', prerelease: false),
      };
      request.response
        ..headers.contentType = ContentType.json
        ..write(jsonEncode(payload));
      await request.response.close();
    });
    final service = AppUpdateService(
      releaseApiUris: [
        for (final path in ['/test', '/draft', '/tv', '/stable'])
          Uri.parse('http://127.0.0.1:${server.port}$path'),
      ],
    );
    final update = await service.findLatest(
      currentVersion: '1.0.127',
      supportedAbis: const ['arm64-v8a'],
    );
    expect(update!.version, '1.0.129');
    expect(requested, ['/test', '/draft', '/tv', '/stable']);
  });

  test('verifies complete APK version identity before installation', () {
    final service = AppUpdateService();
    const apk = AppUpdateApkInfo(
      packageName: 'online.dnsai.ivanvpn',
      version: currentTest,
      buildNumber: 43151,
      signatureMatchesInstalled: true,
      signingCertificateSha256: ['abc123'],
    );
    expect(
      () => service.validateInspectedApk(
        apk,
        currentBuildNumber: 43150,
        expectedVersion: currentTest,
      ),
      returnsNormally,
    );
    expect(
      () => service.validateInspectedApk(apk, expectedVersion: nextTest),
      throwsA(isA<AppUpdateIdentityException>()),
    );
  });

  test(
    'testing cache is isolated between iterations with the same APK name',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      var requests = 0;
      server.listen((request) async {
        requests += 1;
        request.response.add([0x50, 0x4B, 0x03, 0x04, requests]);
        await request.response.close();
      });
      final name = 'testing-${DateTime.now().microsecondsSinceEpoch}.apk';
      final files = <File>[];
      addTearDown(() async {
        for (final file in files) {
          if (await file.exists()) await file.delete();
        }
      });
      final service = AppUpdateService();
      for (final version in [currentTest, nextTest]) {
        files.add(
          await service.download(
            AppUpdateInfo(
              version: version,
              assetName: name,
              downloadUrl: Uri.parse(
                'http://127.0.0.1:${server.port}/update.apk',
              ),
              size: 5,
            ),
            onProgress: (_) {},
          ),
        );
      }
      expect(requests, 2);
      expect(files.first.path, isNot(files.last.path));
      expect(files.last.path, contains(nextTest));
    },
  );

  test('parses every supported app distribution channel', () {
    expect(
      AppDistributionChannel.fromWireValue('github'),
      AppDistributionChannel.github,
    );
    expect(
      AppDistributionChannel.fromWireValue(' PLAY '),
      AppDistributionChannel.play,
    );
    expect(
      AppDistributionChannel.fromWireValue('soak'),
      AppDistributionChannel.soak,
    );
    expect(
      AppDistributionChannel.fromWireValue(' TV '),
      AppDistributionChannel.tv,
    );
    expect(
      AppDistributionChannel.fromWireValue('unexpected'),
      AppDistributionChannel.unknown,
    );
    expect(
      AppDistributionChannel.fromWireValue(null),
      AppDistributionChannel.unknown,
    );
  });

  test('enables external APK updates only for the GitHub channel', () {
    expect(AppDistributionChannel.github.externalUpdatesEnabled, isTrue);
    expect(AppDistributionChannel.tv.externalUpdatesEnabled, isFalse);
    expect(AppDistributionChannel.play.externalUpdatesEnabled, isFalse);
    expect(AppDistributionChannel.soak.externalUpdatesEnabled, isFalse);
    expect(AppDistributionChannel.unknown.externalUpdatesEnabled, isFalse);
  });

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

  test('accepts versioned GitHub release APK name', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));

    server.listen((request) async {
      final payload = {
        'tag_name': 'v1.0.80',
        'assets': [
          {
            'name': 'Yurich-Connect-Android-v1.0.80.apk',
            'browser_download_url':
                'http://127.0.0.1:${server.port}/versioned.apk',
            'size': 199738363,
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
      currentVersion: '1.0.79',
      supportedAbis: const ['arm64-v8a'],
    );

    expect(update, isNotNull);
    expect(update!.version, '1.0.80');
    expect(update.assetName, 'Yurich-Connect-Android-v1.0.80.apk');
    expect(update.downloadUrl.path, '/versioned.apk');
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
        'yurich_connect_updates${Platform.pathSeparator}1.0.63'
        '${Platform.pathSeparator}$assetName',
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
          ..headers.contentLength = 4
          ..add(const [0x50, 0x4B, 0x03, 0x04]);
        await request.response.close();
      });

      final service = AppUpdateService();
      final update = AppUpdateInfo(
        version: '1.0.63',
        assetName: assetName,
        downloadUrl: Uri.parse('http://127.0.0.1:${server.port}/update.apk'),
        size: 4,
      );

      final first = await service.download(update, onProgress: (_) {});
      final second = await service.download(update, onProgress: (_) {});

      expect(first.path, second.path);
      expect(await second.readAsBytes(), const [0x50, 0x4B, 0x03, 0x04]);
      expect(downloadCount, 1);
    },
  );

  test('rejects a downloaded HTML error page as invalid APK', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));

    final body = utf8.encode('<html>temporary error</html>');
    server.listen((request) async {
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentLength = body.length
        ..add(body);
      await request.response.close();
    });

    final service = AppUpdateService();
    final update = AppUpdateInfo(
      version: '1.0.81',
      assetName:
          'YurichConnect-invalid-${DateTime.now().microsecondsSinceEpoch}.apk',
      downloadUrl: Uri.parse('http://127.0.0.1:${server.port}/update.apk'),
      size: body.length,
    );

    await expectLater(
      service.download(update, onProgress: (_) {}),
      throwsA(isA<StateError>()),
    );
  });

  test(
    'does not reuse a previous release cache when metadata has no size',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      var requests = 0;
      server.listen((request) async {
        requests += 1;
        request.response.add([0x50, 0x4B, 0x03, 0x04, requests]);
        await request.response.close();
      });
      final assetName = 'cache-${DateTime.now().microsecondsSinceEpoch}.apk';
      final files = <File>[];
      addTearDown(() async {
        for (final file in files) {
          if (await file.exists()) await file.delete();
        }
      });
      final service = AppUpdateService();
      for (final version in ['1.0.124', '1.0.125']) {
        files.add(
          await service.download(
            AppUpdateInfo(
              version: version,
              assetName: assetName,
              downloadUrl: Uri.parse(
                'http://127.0.0.1:${server.port}/update.apk',
              ),
              size: null,
            ),
            onProgress: (_) {},
          ),
        );
      }
      expect(requests, 2);
      expect(files.first.path, isNot(files.last.path));
      expect((await files.last.readAsBytes()).last, 2);
    },
  );

  test(
    'rejects APK filenames that escape the update cache directory',
    () async {
      final service = AppUpdateService();
      for (final name in ['../other.apk', r'..\other.apk', '/other.apk']) {
        await expectLater(
          service.download(
            AppUpdateInfo(
              version: '1.0.125',
              assetName: name,
              downloadUrl: Uri.parse('https://example.com/update.apk'),
              size: null,
            ),
            onProgress: (_) {},
          ),
          throwsStateError,
        );
      }
    },
  );

  test(
    'retries a stalled download instead of waiting forever for its body',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      var requests = 0;
      server.listen((request) async {
        requests += 1;
        if (requests == 1) {
          request.response.add([0x50, 0x4B]);
          await request.response.flush();
        } else {
          request.response.add([0x50, 0x4B, 0x03, 0x04]);
          await request.response.close();
        }
      });
      final service = AppUpdateService(
        downloadIdleTimeout: const Duration(milliseconds: 150),
      );
      final file = await service.download(
        AppUpdateInfo(
          version: '1.0.125',
          assetName: 'stalled-${DateTime.now().microsecondsSinceEpoch}.apk',
          downloadUrl: Uri.parse('http://127.0.0.1:${server.port}/update.apk'),
          size: 4,
        ),
        onProgress: (_) {},
      );
      addTearDown(() => file.delete());
      expect(requests, 2);
      expect(await file.readAsBytes(), [0x50, 0x4B, 0x03, 0x04]);
    },
  );

  test('accepts only the installed package and signing certificate', () {
    final service = AppUpdateService();
    const apk = AppUpdateApkInfo(
      packageName: 'online.dnsai.ivanvpn',
      version: '1.0.108',
      buildNumber: 22108,
      signatureMatchesInstalled: true,
      signingCertificateSha256: ['abc123'],
    );

    expect(
      () => service.validateInspectedApk(apk, currentBuildNumber: 22107),
      returnsNormally,
    );
  });

  test('rejects update APK from another package or signer', () {
    final service = AppUpdateService();
    const wrongPackage = AppUpdateApkInfo(
      packageName: 'example.attacker',
      version: '9.9.9',
      buildNumber: 99999,
      signatureMatchesInstalled: true,
      signingCertificateSha256: ['abc123'],
    );
    const wrongSigner = AppUpdateApkInfo(
      packageName: 'online.dnsai.ivanvpn',
      version: '1.0.108',
      buildNumber: 22108,
      signatureMatchesInstalled: false,
      signingCertificateSha256: ['attacker'],
    );

    expect(
      () => service.validateInspectedApk(wrongPackage),
      throwsA(isA<AppUpdateIdentityException>()),
    );
    expect(
      () => service.validateInspectedApk(wrongSigner),
      throwsA(isA<AppUpdateIdentityException>()),
    );
  });

  test('rejects update APK with a non-increasing build number', () {
    final service = AppUpdateService();
    const apk = AppUpdateApkInfo(
      packageName: 'online.dnsai.ivanvpn',
      version: '1.0.107',
      buildNumber: 22107,
      signatureMatchesInstalled: true,
      signingCertificateSha256: ['abc123'],
    );

    expect(
      () => service.validateInspectedApk(apk, currentBuildNumber: 22107),
      throwsA(isA<AppUpdateDowngradeException>()),
    );
  });
}
