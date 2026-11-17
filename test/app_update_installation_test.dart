import 'dart:async';
import 'dart:io';

import 'package:aurum_vpn/src/services/app_update_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/update_http_fixture.dart';

const _channel = MethodChannel('online.dnsai.ivanvpn/updater');
const _expectedVersion = '1.0.132';
const _installedBuild = 43214;
const _metadata = <String, Object?>{
  'packageName': 'online.dnsai.ivanvpn',
  'versionName': _expectedVersion,
  'versionCode': 43215,
  'signatureMatchesInstalled': true,
  'signingCertificateSha256': ['fixture-certificate'],
};

void main() {
  final messenger =
      TestWidgetsFlutterBinding.ensureInitialized().defaultBinaryMessenger;
  final file = File('installer-fixture-never-executed.apk');

  AppUpdateService service() => AppUpdateService(
    client: UpdateHttpClient((_) => fail('Installer fixture used HTTP')),
  );

  Future<void> install(AppUpdateService updater) => updater.installApk(
    file,
    expectedVersion: _expectedVersion,
    currentBuildNumber: _installedBuild,
  );

  tearDown(() => messenger.setMockMethodCallHandler(_channel, null));

  for (final (name, reply, expected) in [
    (
      'missing inspection',
      null,
      isA<StateError>().having(
        (error) => error.toString(),
        'message',
        contains('Android cannot inspect update APK'),
      ),
    ),
    (
      'unexpected package',
      {..._metadata, 'packageName': 'fixture.other.app'},
      _identity('package mismatch'),
    ),
    (
      'signer mismatch',
      {..._metadata, 'signatureMatchesInstalled': false},
      _identity('signing certificate does not match'),
    ),
    (
      'untyped signer confirmation',
      {..._metadata, 'signatureMatchesInstalled': 'true'},
      _identity('signing certificate does not match'),
    ),
    (
      'no certificate strings',
      {
        ..._metadata,
        'signingCertificateSha256': [12, false],
      },
      _identity('signing certificate does not match'),
    ),
    (
      'prerelease instead of selected stable version',
      {..._metadata, 'versionName': '1.0.132-test.20261116.1'},
      _identity('does not match selected release'),
    ),
    (
      'missing build number',
      {..._metadata, 'versionCode': null},
      _downgrade(0),
    ),
    (
      'same build number',
      {..._metadata, 'versionCode': _installedBuild},
      _downgrade(_installedBuild),
    ),
    (
      'lower build number',
      {..._metadata, 'versionCode': _installedBuild - 1},
      _downgrade(_installedBuild - 1),
    ),
  ]) {
    test('never opens the installer after $name', () async {
      final calls = <String>[];
      messenger.setMockMethodCallHandler(_channel, (call) async {
        calls.add(call.method);
        expect(call.arguments, {'path': file.path});
        if (call.method != 'inspectApk') fail('Unexpected ${call.method}');
        return reply;
      });

      await expectLater(install(service()), throwsA(expected));
      expect(calls, ['inspectApk']);
    });
  }

  test(
    'inspection failure propagates without suggesting install permission',
    () async {
      final calls = <String>[];
      messenger.setMockMethodCallHandler(_channel, (call) async {
        calls.add(call.method);
        throw PlatformException(code: 'APK_INVALID');
      });

      await expectLater(
        install(service()),
        throwsA(
          isA<PlatformException>().having(
            (error) => error.code,
            'code',
            'APK_INVALID',
          ),
        ),
      );
      expect(calls, ['inspectApk']);
    },
  );

  test('installer waits for matching inspection of that exact file', () async {
    final calls = <String>[];
    final started = Completer<void>();
    final inspection = Completer<Map<String, Object?>>();
    messenger.setMockMethodCallHandler(_channel, (call) async {
      calls.add(call.method);
      expect(call.arguments, {'path': file.path});
      if (call.method == 'inspectApk') {
        started.complete();
        return inspection.future;
      }
      expect(call.method, 'installApk');
      return null;
    });

    final installing = install(service());
    await started.future;
    expect(calls, ['inspectApk']);
    inspection.complete(_metadata);
    await installing;
    expect(calls, ['inspectApk', 'installApk']);
  });

  for (final code in [
    'INSTALL_PERMISSION',
    'INSTALL_FAILED',
    'EXTERNAL_INSTALL_DISABLED',
  ]) {
    test(
      'keeps native installation failure $code distinct and does not retry',
      () async {
        final calls = <String>[];
        messenger.setMockMethodCallHandler(_channel, (call) async {
          calls.add(call.method);
          expect(call.arguments, {'path': file.path});
          if (call.method == 'inspectApk') return _metadata;
          expect(call.method, 'installApk');
          throw PlatformException(
            code: code,
            message: 'Fixture installer error',
          );
        });

        await expectLater(
          install(service()),
          throwsA(
            code == 'INSTALL_PERMISSION'
                ? isA<AppUpdatePermissionException>().having(
                    (error) => error.toString(),
                    'message',
                    'Install permission is required.',
                  )
                : isA<PlatformException>()
                      .having((error) => error.code, 'code', code)
                      .having(
                        (error) => error.message,
                        'message',
                        'Fixture installer error',
                      ),
          ),
        );
        expect(calls, ['inspectApk', 'installApk']);
      },
    );
  }

  test(
    'desktop cannot request Android architecture or installer settings',
    () async {
      final calls = <String>[];
      messenger.setMockMethodCallHandler(_channel, (call) async {
        calls.add(call.method);
        fail('Desktop test called ${call.method}');
      });
      final updater = service();
      final abis = await updater.supportedAbis();
      expect(abis, isEmpty);
      expect(await updater.externalUpdatesEnabled(), isFalse);
      await updater.openInstallSettings();
      await expectLater(
        updater.findLatest(
          currentVersion: _expectedVersion,
          supportedAbis: abis,
        ),
        throwsA(
          isA<AppUpdateArchitectureException>().having(
            (error) => error.toString(),
            'message',
            'Unable to determine Android CPU architecture.',
          ),
        ),
      );
      expect(calls, isEmpty);
    },
    skip: Platform.isAndroid,
  );
}

Matcher _identity(String detail) => isA<AppUpdateIdentityException>().having(
  (error) => error.toString(),
  'message',
  contains(detail),
);

Matcher _downgrade(int candidate) => isA<AppUpdateDowngradeException>()
    .having((error) => error.currentBuildNumber, 'installed', _installedBuild)
    .having((error) => error.updateBuildNumber, 'downloaded', candidate)
    .having(
      (error) => error.toString(),
      'message',
      contains('APK is not newer'),
    );
