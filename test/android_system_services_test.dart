import 'dart:io';

import 'package:aurum_vpn/src/services/android_vpn_engine.dart';
import 'package:aurum_vpn/src/services/app_update_service.dart';
import 'package:aurum_vpn/src/services/installed_apps_service.dart';
import 'package:aurum_vpn/src/services/kill_switch_http_policy.dart';
import 'package:aurum_vpn/src/services/kill_switch_service.dart';
import 'package:aurum_vpn/src/services/power_manager_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final messenger =
      TestWidgetsFlutterBinding.ensureInitialized().defaultBinaryMessenger;
  const apps = MethodChannel('online.dnsai.ivanvpn/apps');
  const power = MethodChannel('online.dnsai.ivanvpn/power');
  const updater = MethodChannel('online.dnsai.ivanvpn/updater');
  const vpn = MethodChannel('com.tecclub.flutter_singbox/methods');
  final appService = InstalledAppsService();
  final powerService = PowerManagerService();

  tearDown(() {
    messenger.setMockMethodCallHandler(apps, null);
    messenger.setMockMethodCallHandler(power, null);
    messenger.setMockMethodCallHandler(updater, null);
    messenger.setMockMethodCallHandler(vpn, null);
    debugDefaultTargetPlatformOverride = null;
  });

  test(
    'app inventory drops non-string data and tolerates optional services',
    () async {
      messenger.setMockMethodCallHandler(apps, (call) async {
        expect(call.method, 'getInstalledPackages');
        return ['fixture.example', null, 42, 'fixture.other'];
      });
      expect(await appService.installedPackageNames(), [
        'fixture.example',
        'fixture.other',
      ]);
      messenger.setMockMethodCallHandler(apps, (_) async => null);
      expect(await appService.installedPackageNames(), isEmpty);
      messenger.setMockMethodCallHandler(
        apps,
        (_) async => throw PlatformException(code: 'unavailable'),
      );
      expect(await appService.installedPackageNames(), isEmpty);
      messenger.setMockMethodCallHandler(apps, null);
      expect(await appService.installedPackageNames(), isEmpty);
    },
  );

  test('battery settings never call the Android channel on desktop', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final calls = <String>[];
    messenger.setMockMethodCallHandler(power, (call) async {
      calls.add(call.method);
      return null;
    });
    expect(powerService.supported, isFalse);
    expect(await powerService.isIgnoringBatteryOptimizations(), isNull);
    expect(await powerService.openAppBatterySettings(), isFalse);
    expect(calls, isEmpty);
  });

  test(
    'battery settings fail gracefully on absent or broken Android handlers',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      expect(powerService.supported, isTrue);
      expect(await powerService.isIgnoringBatteryOptimizations(), isNull);
      expect(await powerService.openAppBatterySettings(), isFalse);
      messenger.setMockMethodCallHandler(
        power,
        (_) async => throw PlatformException(code: 'settings-unavailable'),
      );
      expect(await powerService.isIgnoringBatteryOptimizations(), isNull);
      expect(await powerService.openAppBatterySettings(), isFalse);
      messenger.setMockMethodCallHandler(power, (call) async {
        return switch (call.method) {
          'isIgnoringBatteryOptimizations' => true,
          'openAppBatterySettings' => null,
          _ => fail('Unexpected call: ${call.method}'),
        };
      });
      expect(await powerService.isIgnoringBatteryOptimizations(), isTrue);
      expect(await powerService.openAppBatterySettings(), isFalse);
    },
  );

  test(
    'unknown or enabled Android protection never allows a direct HTTP client',
    () {
      expect(
        KillSwitchHttpPolicy.requiresProxy(const KillSwitchState()),
        isTrue,
      );
      expect(
        KillSwitchHttpPolicy.requiresProxy(
          const KillSwitchState(known: true, requested: true),
        ),
        isTrue,
      );
      expect(
        KillSwitchHttpPolicy.requiresProxy(
          const KillSwitchState(known: true, lockdown: true),
        ),
        isTrue,
      );
      expect(
        KillSwitchHttpPolicy.requiresProxy(
          const KillSwitchState(known: true, alwaysOn: true),
        ),
        isTrue,
      );
      expect(
        KillSwitchHttpPolicy.requiresProxy(
          const KillSwitchState(known: true, vpnActive: true),
        ),
        isTrue,
      );
      expect(
        KillSwitchHttpPolicy.requiresProxy(const KillSwitchState(known: true)),
        isFalse,
      );
      expect(
        KillSwitchHttpPolicy.requiresProxy(
          const KillSwitchState(supported: false),
        ),
        isFalse,
      );
    },
  );

  test(
    'VPN engine reads native notification labels without mutating the session',
    () async {
      final calls = <String>[];
      var hasMetadata = true;
      messenger.setMockMethodCallHandler(vpn, (call) async {
        expect(call.arguments, isNull);
        calls.add(call.method);
        return switch (call.method) {
          'getNotificationTitle' => hasMetadata ? 'Fixture VPN' : null,
          'getNotificationDescription' =>
            hasMetadata ? 'Fixture connected' : null,
          _ => fail('Unexpected VPN call: ${call.method}'),
        };
      });
      final engine = AndroidVpnEngine();
      expect(await engine.getNotificationTitle(), 'Fixture VPN');
      expect(await engine.getNotificationDescription(), 'Fixture connected');
      hasMetadata = false;
      expect(await engine.getNotificationTitle(), 'VPN Service');
      expect(await engine.getNotificationDescription(), 'Connected');
      expect(calls, [
        'getNotificationTitle',
        'getNotificationDescription',
        'getNotificationTitle',
        'getNotificationDescription',
      ]);
    },
  );

  test(
    'APK installer requires native identity and reports install permission separately',
    () async {
      final service = AppUpdateService();
      final file = File('fixture-never-opened.apk');
      const metadata = <String, Object?>{
        'packageName': 'online.dnsai.ivanvpn',
        'versionName': '1.0.132',
        'versionCode': '43213',
        'signatureMatchesInstalled': true,
        'signingCertificateSha256': ['fixture-digest', 123],
      };
      final calls = <String>[];
      Map<String, Object?>? reply;
      PlatformException? installError;
      messenger.setMockMethodCallHandler(updater, (call) async {
        expect(call.arguments, {'path': file.path});
        calls.add(call.method);
        if (call.method == 'inspectApk') return reply;
        expect(call.method, 'installApk');
        if (installError case final error?) throw error;
        return null;
      });
      Future<void> install() => service.installApk(
        file,
        currentBuildNumber: 43212,
        expectedVersion: '1.0.132',
      );

      await expectLater(install(), throwsStateError);
      reply = {...metadata, 'signatureMatchesInstalled': false};
      await expectLater(install(), throwsA(isA<AppUpdateIdentityException>()));
      expect(calls, ['inspectApk', 'inspectApk']);

      reply = metadata;
      final inspected = await service.inspectApk(file);
      expect(inspected.buildNumber, 43213);
      expect(inspected.signingCertificateSha256, ['fixture-digest']);
      installError = PlatformException(code: 'INSTALL_PERMISSION');
      await expectLater(
        install(),
        throwsA(isA<AppUpdatePermissionException>()),
      );
      installError = PlatformException(code: 'INSTALLER_UNAVAILABLE');
      await expectLater(
        install(),
        throwsA(
          isA<PlatformException>().having(
            (error) => error.code,
            'code',
            'INSTALLER_UNAVAILABLE',
          ),
        ),
      );
      installError = null;
      await install();
      expect(calls.skip(3), [
        'inspectApk',
        'installApk',
        'inspectApk',
        'installApk',
        'inspectApk',
        'installApk',
      ]);
    },
  );
}
