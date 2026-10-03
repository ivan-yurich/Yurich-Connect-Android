import 'dart:async';

import 'package:aurum_vpn/src/app.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_singbox_vpn/flutter_singbox_method_channel.dart';
import 'package:flutter_singbox_vpn/flutter_singbox_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const pluginPrefix = 'com.tecclub.flutter_singbox';
  final nativeCalls = <String>[];
  var nativeStatus = 'Started';
  late _EventTestPlatform platform;

  setUp(() {
    nativeCalls.clear();
    nativeStatus = 'Started';
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
          'getVPNStatus' => nativeStatus,
          'getManualDisconnectRequested' => false,
          'getNetworkSnapshot' => {'type': 'wifi', 'generation': 0},
          'getLogs' => <String>[],
          'getConfig' => '{}',
          _ => true,
        };
      },
    );
    expect(FlutterSingboxPlatform.instance, isA<MethodChannelFlutterSingbox>());
    platform = _EventTestPlatform();
    FlutterSingboxPlatform.instance = platform;
  });

  tearDown(() async {
    await platform.status.close();
    await platform.traffic.close();
    await platform.logs.close();
  });

  Future<void> emitTraffic(WidgetTester tester) async {
    platform.traffic.add({
      'type': 'wifi',
      'generation': 1,
      'uplinkSpeed': 8192,
      'downlinkSpeed': 16384,
      'sessionTotal': 1048576,
      'formattedUplinkSpeed': '8 KB/s',
      'formattedDownlinkSpeed': '16 KB/s',
      'formattedSessionTotal': '1 MB',
    });
    await tester.pump();
  }

  Future<void> emitStreamError(WidgetTester tester, String stream) async {
    final controller = stream == 'status' ? platform.status : platform.traffic;
    controller.addError(
      PlatformException(
        code: 'temporary_delivery_error',
        message: 'Event delivery interrupted',
      ),
    );
    await tester.pump();
  }

  Future<void> emitConnected(WidgetTester tester) async {
    platform.status.add({
      'status': 'Started',
      'manualDisconnectRequested': false,
      'type': 'wifi',
      'generation': 0,
    });
    await tester.pump();
  }

  testWidgets('Android stream errors do not overrule native readiness', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 10));
    });
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(const YurichConnectApp());
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 250));
    }
    await emitConnected(tester);
    await tester.pump();
    expect(find.text('Подключено'), findsOneWidget);
    nativeCalls.clear();

    await emitStreamError(tester, 'traffic');
    await emitStreamError(tester, 'status');
    await tester.pump();
    expect(find.text('Нет стабильного соединения'), findsNothing);
    expect(find.text('Подключено'), findsOneWidget);
    expect(nativeCalls, contains('getVPNStatus'));
    expect(
      nativeCalls.where(
        (method) => ['startVPN', 'stopVPN', 'reloadVPN'].contains(method),
      ),
      isEmpty,
    );

    nativeStatus = 'Starting';
    await emitStreamError(tester, 'status');
    await tester.pump();
    expect(find.text('Подключено'), findsNothing);
    expect(tester.takeException(), isNull);
  });

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
      final backgroundCallCount = nativeCalls.length;
      await tester.pump(const Duration(minutes: 2));
      expect(nativeCalls.length, backgroundCallCount);
      expect(binding.transientCallbackCount, 0);

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

  testWidgets('TV shares native status and counters without mobile animation', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(960, 540);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 10));
    });
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(const YurichConnectApp(tvMode: true));
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 250));
    }
    await emitConnected(tester);
    expect(find.text('Подключено'), findsOneWidget);
    await emitTraffic(tester);
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Yurich Connect TV'), findsOneWidget);
    expect(find.text('Смена сети'), findsOneWidget);
    expect(find.text('8 KB/s'), findsOneWidget);
    expect(find.text('16 KB/s'), findsOneWidget);
    expect(find.text('1 MB'), findsOneWidget);
    expect(binding.transientCallbackCount, 0);
    nativeCalls.clear();
    binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    await tester.pump(const Duration(minutes: 2));
    expect(binding.transientCallbackCount, 0);
    expect(nativeCalls, isEmpty);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    expect(binding.transientCallbackCount, 0);
    expect(tester.takeException(), isNull);
    expect(
      nativeCalls.where(
        (method) => ['startVPN', 'stopVPN', 'reloadVPN'].contains(method),
      ),
      isEmpty,
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 10));
  });

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

class _EventTestPlatform extends MethodChannelFlutterSingbox {
  final status = StreamController<Map<String, dynamic>>.broadcast();
  final traffic = StreamController<Map<String, dynamic>>.broadcast();
  final logs = StreamController<Map<String, dynamic>>.broadcast();

  @override
  Stream<Map<String, dynamic>> get onStatusChanged => status.stream;

  @override
  Stream<Map<String, dynamic>> get onTrafficUpdate => traffic.stream;

  @override
  Stream<Map<String, dynamic>> get onLogMessage => logs.stream;
}
