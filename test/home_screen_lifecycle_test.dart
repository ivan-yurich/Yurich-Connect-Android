import 'dart:async';

import 'package:aurum_vpn/src/app.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const pluginPrefix = 'com.tecclub.flutter_singbox';
  final nativeCalls = <String>[];

  setUp(() {
    nativeCalls.clear();
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    PackageInfo.setMockInitialValues(
      appName: 'Yurich Connect',
      packageName: 'online.dnsai.ivanvpn',
      version: '1.0.126',
      buildNumber: '43138',
      buildSignature: '',
    );
    for (final name in ['status_events', 'traffic_events', 'log_events']) {
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        MethodChannel('$pluginPrefix/$name'),
        (_) async => null,
      );
    }
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('$pluginPrefix/methods'),
      (call) async {
        nativeCalls.add(call.method);
        return switch (call.method) {
          'getVPNStatus' => 'Started',
          'getManualDisconnectRequested' => false,
          'getNetworkSnapshot' => {'type': 'wifi', 'generation': 1},
          'getLogs' => <String>[],
          'getConfig' => '{}',
          _ => true,
        };
      },
    );
  });

  Future<void> emitTraffic(WidgetTester tester) async {
    final delivered = Completer<void>();
    tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      '$pluginPrefix/traffic_events',
      const StandardMethodCodec().encodeSuccessEnvelope({
        'type': 'wifi',
        'generation': 1,
        'uplinkSpeed': 8192,
        'downlinkSpeed': 16384,
        'sessionTotal': 1048576,
        'formattedUplinkSpeed': '8 KB/s',
        'formattedDownlinkSpeed': '16 KB/s',
        'formattedSessionTotal': '1 MB',
      }),
      (_) => delivered.complete(),
    );
    await delivered.future;
  }

  testWidgets(
    'pauses UI animation in background and restores traffic on resume',
    (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpWidget(const YurichConnectApp());
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 250));
      }
      expect(tester.takeException(), isNull);
      expect(binding.transientCallbackCount, greaterThan(0));
      nativeCalls.clear();

      binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      expect(binding.transientCallbackCount, 0);

      await emitTraffic(tester);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(binding.transientCallbackCount, 0);
      expect(binding.hasScheduledFrame, isFalse);
      expect(find.textContaining('8 KB/s'), findsNothing);

      binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(binding.transientCallbackCount, greaterThan(0));
      expect(find.textContaining('8 KB/s'), findsOneWidget);
      expect(find.textContaining('16 KB/s'), findsOneWidget);
      expect(find.text('1 MB'), findsOneWidget);
      expect(tester.takeException(), isNull);
      expect(
        nativeCalls.where(
          (method) => ['startVPN', 'stopVPN', 'reloadVPN'].contains(method),
        ),
        isEmpty,
      );

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 10));
    },
  );

  testWidgets('fits a narrow screen with larger accessibility text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(960, 1920);
    tester.view.devicePixelRatio = 3;
    tester.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(const YurichConnectApp());
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 250));
    }
    expect(find.text('Yurich Connect'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 10));
  });
}
