import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:aurum_vpn/src/app.dart';
import 'package:aurum_vpn/src/models/vpn_profile.dart';
import 'package:aurum_vpn/src/services/local_connection_incidents.dart';
import 'package:aurum_vpn/src/services/profile_importer.dart';
import 'package:aurum_vpn/src/theme/yurich_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
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
  const powerChannel = MethodChannel('online.dnsai.ivanvpn/power');
  const incidentChannel = MethodChannel('online.dnsai.ivanvpn/local_incidents');
  final nativeCalls = <String>[];
  final nativeConfigs = <String>[];
  final managedConfigSaves = <bool>[];
  final smartRouteSelections = <List<String>>[];
  var nativeStatus = 'Started';
  var killSwitch = <String, Object>{};
  var configSaved = true;
  var rejectNativeStart = false;
  final scriptedStarts = <bool>[];
  var moveToCellularOnStart = false;
  var networkSnapshot = <String, Object>{};
  Completer<bool>? pendingStopAck;
  Completer<bool>? pendingManualDisconnectRead;
  Completer<bool>? pendingSmartRouteInstallCheck;
  Completer<bool>? pendingSmartRouteSave;
  Completer<String?>? pendingDirectGate;
  late _EventTestPlatform platform;
  final captureDir = Platform.environment['YURICH_UI_CAPTURE_DIR'];
  final captureFonts = Platform.environment['YURICH_UI_CAPTURE_FONTS'];
  const captureKey = ValueKey('mobile-ui-capture');
  const powerKey = ValueKey('mobile-vpn-power');
  const activeServerKey = ValueKey('mobile-active-server');
  const serverPickerKey = ValueKey('mobile-server-picker');
  const settingsKey = ValueKey('mobile-settings-tab');
  const quickSettingsKey = ValueKey('mobile-quick-settings');
  const smartRouteKey = ValueKey('mobile-smart-route');
  const checkServersKey = ValueKey('mobile-check-servers');
  const udpProfile = VpnProfile(
    id: 'qa-udp',
    name: 'QA Netherlands',
    kind: VpnProfileKind.hysteria2,
    originalInput: 'hy2://fixture@127.0.0.1:0',
    server: '127.0.0.1',
    port: 0,
    countryCode: 'NL',
  );
  const offlineProfile = VpnProfile(
    id: 'qa-offline',
    name: 'QA Sweden offline',
    kind: VpnProfileKind.vlessTls,
    originalInput: '',
    countryCode: 'SE',
  );

  setUp(() {
    nativeCalls.clear();
    nativeConfigs.clear();
    managedConfigSaves.clear();
    smartRouteSelections.clear();
    nativeStatus = 'Started';
    killSwitch = {};
    configSaved = true;
    rejectNativeStart = false;
    scriptedStarts.clear();
    moveToCellularOnStart = false;
    networkSnapshot = {
      'type': 'wifi',
      'generation': 0,
      'validated': true,
      'probePhysicalNetwork': 'test-wifi',
      'autoPhysicalRouteConfirmed': true,
    };
    pendingStopAck = null;
    pendingManualDisconnectRead = null;
    pendingSmartRouteInstallCheck = null;
    pendingSmartRouteSave = null;
    pendingDirectGate = null;
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    PackageInfo.setMockInitialValues(
      appName: 'Yurich Connect',
      packageName: 'online.dnsai.ivanvpn',
      version: '1.0.126',
      buildNumber: '43138',
      buildSignature: '',
    );
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      powerChannel,
      (_) async => false,
    );
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      incidentChannel,
      (_) async => {'enabled': false, 'queued': 0},
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
        if (call.method == 'saveConfig') {
          nativeConfigs.add(call.arguments['config'] as String);
          managedConfigSaves.add(call.arguments['smartRouteApps'] == true);
        }
        if (call.method == 'saveSmartRouteApps') {
          smartRouteSelections.add(
            (call.arguments['packages'] as List<Object?>).cast<String>(),
          );
          if (pendingSmartRouteSave != null) {
            return pendingSmartRouteSave!.future;
          }
        }
        if (call.method == 'stopVPN' && pendingStopAck != null) {
          return pendingStopAck!.future;
        }
        if (call.method == 'initializeSmartRouteInstallDefault') {
          return await pendingSmartRouteInstallCheck?.future ?? false;
        }
        if (call.method == 'getManualDisconnectRequested' &&
            pendingManualDisconnectRead != null) {
          return pendingManualDisconnectRead!.future;
        }
        if (call.method == 'startVPN' && moveToCellularOnStart) {
          moveToCellularOnStart = false;
          networkSnapshot = {
            'type': 'cellular',
            'generation': 1,
            'validated': true,
            'probePhysicalNetwork': 'test-cellular',
            'autoPhysicalRouteConfirmed': true,
          };
          nativeStatus = 'Stopped';
          return true;
        }
        if (call.method == 'startVPN' && scriptedStarts.isNotEmpty) {
          final ready = scriptedStarts.removeAt(0);
          nativeStatus = ready ? 'Started' : 'Stopped';
          return ready;
        }
        if (call.method == 'getDirectProbeNetwork' &&
            pendingDirectGate != null) {
          return pendingDirectGate!.future;
        }
        return switch (call.method) {
          'getVPNStatus' => nativeStatus,
          'getManualDisconnectRequested' => false,
          'getNetworkSnapshot' => networkSnapshot,
          'getLogs' => <String>[],
          'getConfig' => '{}',
          'saveConfig' => configSaved,
          'startVPN' => !rejectNativeStart,
          'getKillSwitchState' => killSwitch,
          'getSmartRouteApps' => {
            'supported': true,
            'protectionKnown': true,
            'protected': killSwitch['strictRuntime'] == true,
            'candidates': [
              {
                'packageId': 'test.example.fixture',
                'name': 'QA App',
                'availability': 'installed',
              },
            ],
          },
          _ => true,
        };
      },
    );
    expect(FlutterSingboxPlatform.instance, isA<MethodChannelFlutterSingbox>());
    platform = _EventTestPlatform();
    FlutterSingboxPlatform.instance = platform;
  });

  tearDown(() async {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(powerChannel, null);
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      incidentChannel,
      null,
    );
    await platform.status.close();
    await platform.traffic.close();
    await platform.logs.close();
  });

  Future<void> emitTraffic(WidgetTester tester, {int generation = 1}) async {
    platform.traffic.add({
      'type': 'wifi',
      'generation': generation,
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

  Future<void> launchWithProfile(
    WidgetTester tester, {
    String cachedCountryCode = 'PL',
    String cachedCountryName = 'Poland',
    bool connected = true,
    bool waitForStopGuard = true,
    bool capture = false,
    List<VpnProfile> extraProfiles = const [],
    Size viewport = const Size(360, 800),
    VpnProfile? initialProfile,
    Map<String, Object> preferences = const {},
  }) async {
    final profile =
        initialProfile ??
        VpnProfile(
          id: 'qa-profile',
          name: 'QA Poland',
          kind: VpnProfileKind.naive,
          originalInput: 'naive+https://fixture:fixture@127.0.0.1:0',
          server: '127.0.0.1',
          port: 0,
          countryCode: cachedCountryCode,
          countryName: cachedCountryName,
        );
    SharedPreferences.setMockInitialValues({
      'selectedProfileId': profile.id,
      ...preferences,
    });
    FlutterSecureStorage.setMockInitialValues({
      'profiles.v1': jsonEncode(
        [profile, ...extraProfiles].map((item) => item.toJson()).toList(),
      ),
    });
    nativeStatus = connected ? 'Started' : 'Stopped';
    tester.view.physicalSize = viewport * 3;
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 10));
    });
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(
      capture && captureDir != null
          ? const RepaintBoundary(key: captureKey, child: YurichConnectApp())
          : const YurichConnectApp(),
    );
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 250));
    }
    if (connected) await emitConnected(tester);
    if (connected && waitForStopGuard) {
      // The stop guard uses DateTime.now(), not the widget test's frame clock.
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 4300)),
      );
    }
    await tester.pump();
  }

  Future<void> prepareCaptureFonts(WidgetTester tester) async {
    if (captureDir == null || captureFonts == null) return;
    await tester.runAsync(() async {
      Future<void> load(String family, String file) async {
        final bytes = await File('$captureFonts/$file').readAsBytes();
        final loader = FontLoader(family)
          ..addFont(Future.value(ByteData.sublistView(bytes)));
        await loader.load();
      }

      await load('Roboto', 'Roboto-Regular.ttf');
      await load('Noto Color Emoji', 'NotoColorEmoji.ttf');
      final icons = FontLoader('MaterialIcons')
        ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
      await icons.load();
    });
  }

  Future<void> capture(WidgetTester tester, String name) async {
    if (captureDir == null) return;
    // Let the actual bundled raster asset finish decoding before capturing.
    await tester.runAsync(() async {
      await precacheImage(
        const ResizeImage(
          AssetImage('assets/images/mobile_world_map.png'),
          width: 900,
        ),
        tester.element(find.byKey(captureKey)),
      );
    });
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(captureKey),
    );
    final shadowsWereDisabled = debugDisableShadows;
    try {
      debugDisableShadows = false;
      void repaint(RenderObject object) {
        object.markNeedsPaint();
        object.visitChildren(repaint);
      }

      repaint(boundary);
      await tester.pump();
      await tester.runAsync(() async {
        final screenshot = await boundary.toImage(pixelRatio: 2);
        try {
          final bytes = (await screenshot.toByteData(
            format: ui.ImageByteFormat.png,
          ))!;
          await Directory(captureDir).create(recursive: true);
          await File('$captureDir/$name.png').writeAsBytes(
            bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
          );
        } finally {
          screenshot.dispose();
        }
      });
    } finally {
      debugDisableShadows = shadowsWereDisabled;
    }
  }

  Iterable<String> getVpnMutations() => nativeCalls.where(
    (method) => const {
      'startVPN',
      'stopVPN',
      'reloadVPN',
      'saveConfig',
      'saveSmartRouteApps',
      'setKillSwitchRequested',
    }.contains(method),
  );

  VpnProfile autoFixture(String id, int port, String country) => VpnProfile(
    id: id,
    name: 'QA $id',
    kind: VpnProfileKind.naive,
    originalInput: '',
    server: '127.0.0.1',
    port: port,
    countryCode: country,
    outbound: {
      'type': 'naive',
      'server': '127.0.0.1',
      'server_port': port,
      'username': 'fixture',
      'password': 'fixture',
      'tls': {'enabled': true, 'server_name': 'fixture.invalid'},
    },
  );

  Future<void> pressAndConsent(WidgetTester tester) async {
    await tester.tap(find.byKey(powerKey));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Принимаю'));
    await tester.pump();
  }

  Future<void> openSmartRouteAppSelection(WidgetTester tester) async {
    await tester.tap(find.byKey(settingsKey));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Приложения напрямую'));
    await tester.pumpAndSettle();
    final candidate = find.byKey(
      const ValueKey('smart-route-app-test.example.fixture'),
    );
    await tester.ensureVisible(candidate);
    await tester.tap(candidate);
    await tester.pumpAndSettle();
  }

  Future<void> pumpUntilNativeCall(WidgetTester tester, String method) async {
    for (var i = 0; i < 16 && !nativeCalls.contains(method); i++) {
      await tester.pump(const Duration(milliseconds: 250));
    }
    expect(nativeCalls, contains(method));
  }

  testWidgets('Smart Route toggle waits for the saved preference on boot', (
    tester,
  ) async {
    pendingManualDisconnectRead = Completer<bool>();
    nativeStatus = 'Stopped';
    SharedPreferences.setMockInitialValues({'smartRouteRuDirect': true});
    await tester.pumpWidget(const YurichConnectApp());
    await tester.pump(const Duration(milliseconds: 250));
    await tester.tap(find.byKey(settingsKey));
    await tester.pumpAndSettle();
    final control = find.byKey(smartRouteKey);
    expect(tester.widget<SwitchListTile>(control).onChanged, isNull);

    pendingManualDisconnectRead!.complete(false);
    pendingManualDisconnectRead = null;
    await tester.pumpAndSettle();
    final loaded = tester.widget<SwitchListTile>(control);
    expect(loaded.value, isTrue);
    expect(loaded.onChanged, isNotNull);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets(
    'fresh Android import waits for Smart Route before first VPN',
    (tester) async {
      final installedAt = DateTime.utc(2026, 11, 13);
      PackageInfo.setMockInitialValues(
        appName: 'Yurich Connect',
        packageName: 'online.dnsai.ivanvpn',
        version: '1.0.132',
        buildNumber: '43200',
        buildSignature: '',
        installTime: installedAt,
        updateTime: installedAt,
      );
      nativeStatus = 'Stopped';
      pendingSmartRouteInstallCheck = Completer<bool>();
      scriptedStarts.add(true);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(seconds: 10));
      });
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpWidget(const YurichConnectApp());
      await pumpUntilNativeCall(tester, 'initializeSmartRouteInstallDefault');
      await tester.tap(find.byKey(const ValueKey('mobile-import')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('mobile-subscription-input')),
        'naive+https://fixture:fixture@127.0.0.1:443#QA%20Poland',
      );
      await tester.pump();
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('mobile-subscription-submit')),
            )
            .onPressed,
        isNotNull,
      );
      await tester.tap(
        find.byKey(const ValueKey('mobile-subscription-submit')),
      );
      await tester.pumpAndSettle();
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('selectedProfileId'), isNull);
      expect(tester.widget<InkWell>(find.byKey(powerKey)).onTap, isNull);
      expect(getVpnMutations(), isEmpty);

      pendingSmartRouteInstallCheck!.complete(true);
      pendingSmartRouteInstallCheck = null;
      await tester.pumpAndSettle();
      expect(prefs.getBool('smartRouteRuDirect'), isTrue);
      expect(prefs.getString('selectedProfileId'), isNotNull);
      await tester.tap(find.byKey(settingsKey));
      await tester.pumpAndSettle();
      expect(
        tester.widget<SwitchListTile>(find.byKey(smartRouteKey)).value,
        isTrue,
      );
      await tester.tap(find.byKey(const ValueKey('mobile-home-tab')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(powerKey));
      await tester.pumpAndSettle();
      expect(find.textContaining('видеть обычный IP сети'), findsOneWidget);
      expect(prefs.containsKey('vpnDisclosureVersion'), isFalse);
      expect(getVpnMutations(), isEmpty);

      await tester.tap(find.text('Принимаю'));
      await tester.pump();
      // Direct latency probes are a separate permission; skip them here.
      final skip = find.text('Без прямого замера');
      await tester.pumpAndSettle();
      if (skip.evaluate().isNotEmpty) {
        await tester.tap(skip);
        await tester.pump();
      }
      await pumpUntilNativeCall(tester, 'startVPN');
      expect(managedConfigSaves, [true]);
      expect(nativeCalls, isNot(contains('saveSmartRouteApps')));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 2));
      expect(tester.takeException(), isNull);
    },
    variant: const TargetPlatformVariant({TargetPlatform.android}),
  );

  testWidgets(
    'Android update leaves an implicit Smart Route off on first VPN',
    (tester) async {
      final installedAt = DateTime.utc(2026, 11, 12);
      PackageInfo.setMockInitialValues(
        appName: 'Yurich Connect',
        packageName: 'online.dnsai.ivanvpn',
        version: '1.0.132',
        buildNumber: '43200',
        buildSignature: '',
        installTime: installedAt,
        updateTime: installedAt.add(const Duration(days: 1)),
      );
      scriptedStarts.add(true);
      await launchWithProfile(
        tester,
        connected: false,
        initialProfile: autoFixture('upgrade', 443, 'PL'),
      );
      await tester.tap(find.byKey(settingsKey));
      await tester.pumpAndSettle();
      expect(
        tester.widget<SwitchListTile>(find.byKey(smartRouteKey)).value,
        isFalse,
      );
      await tester.tap(find.byKey(const ValueKey('mobile-home-tab')));
      await tester.pumpAndSettle();
      await pressAndConsent(tester);
      await pumpUntilNativeCall(tester, 'startVPN');
      expect(managedConfigSaves, [false]);
      expect(
        nativeCalls,
        isNot(contains('initializeSmartRouteInstallDefault')),
      );
      expect(nativeCalls, isNot(contains('saveSmartRouteApps')));
      expect(
        (await SharedPreferences.getInstance()).containsKey(
          'smartRouteRuDirect',
        ),
        isFalse,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 2));
      expect(tester.takeException(), isNull);
    },
    variant: const TargetPlatformVariant({TargetPlatform.android}),
  );

  testWidgets('Smart Route app edit waits for Stopped before saving', (
    tester,
  ) async {
    killSwitch = {'known': true, 'runtimeKnown': true};
    scriptedStarts.add(true);
    await launchWithProfile(
      tester,
      initialProfile: autoFixture('qa-smart-route', 443, 'PL'),
      preferences: const {'smartRouteRuDirect': true},
      waitForStopGuard: false,
    );
    await openSmartRouteAppSelection(tester);
    nativeCalls.clear();
    pendingStopAck = Completer<bool>();
    await tester.tap(find.text('Сохранить и переподключить'));
    await pumpUntilNativeCall(tester, 'stopVPN');
    expect(getVpnMutations(), ['stopVPN']);

    nativeStatus = 'Stopping';
    pendingStopAck!.complete(true);
    pendingStopAck = null;
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 250));
    }
    expect(getVpnMutations(), ['stopVPN']);
    expect(smartRouteSelections, isEmpty);

    nativeStatus = 'Stopped';
    await pumpUntilNativeCall(tester, 'startVPN');
    await tester.pumpAndSettle();
    expect(getVpnMutations(), [
      'stopVPN',
      'saveSmartRouteApps',
      'saveConfig',
      'startVPN',
    ]);
    expect(smartRouteSelections, [
      ['test.example.fixture'],
    ]);
    expect(managedConfigSaves, [true]);
    expect(tester.takeException(), isNull);
    // Dispose before advancing the deferred country refresh from the start.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('Smart Route app edit saves without stopping protected VPN', (
    tester,
  ) async {
    killSwitch = {'known': true, 'runtimeKnown': true};
    await launchWithProfile(
      tester,
      initialProfile: autoFixture('qa-smart-route', 443, 'PL'),
      preferences: const {'smartRouteRuDirect': true},
      waitForStopGuard: false,
    );
    await openSmartRouteAppSelection(tester);
    nativeCalls.clear();
    killSwitch = {
      'known': true,
      'runtimeKnown': true,
      'alwaysOn': true,
      'lockdown': true,
      'strictRuntime': true,
    };
    await tester.tap(find.text('Сохранить и переподключить'));
    await pumpUntilNativeCall(tester, 'saveSmartRouteApps');
    await tester.pumpAndSettle();
    expect(getVpnMutations(), ['saveSmartRouteApps']);
    expect(smartRouteSelections, [
      ['test.example.fixture'],
    ]);
    expect(nativeStatus, 'Started');
    expect(tester.takeException(), isNull);
  });

  testWidgets('Smart Route app edit cancelled during save does not start VPN', (
    tester,
  ) async {
    killSwitch = {'known': true, 'runtimeKnown': true};
    await launchWithProfile(
      tester,
      initialProfile: autoFixture('qa-smart-route', 443, 'PL'),
      preferences: const {'smartRouteRuDirect': true},
      waitForStopGuard: false,
    );
    await openSmartRouteAppSelection(tester);
    nativeCalls.clear();
    pendingStopAck = Completer<bool>();
    pendingSmartRouteSave = Completer<bool>();
    await tester.tap(find.text('Сохранить и переподключить'));
    await pumpUntilNativeCall(tester, 'stopVPN');
    nativeStatus = 'Stopped';
    pendingStopAck!.complete(true);
    pendingStopAck = null;
    await pumpUntilNativeCall(tester, 'saveSmartRouteApps');

    await tester.tap(find.byKey(const ValueKey('mobile-home-tab')));
    await tester.pump();
    expect(find.byTooltip('Отменить подключение'), findsOneWidget);
    await tester.tap(find.byKey(powerKey));
    await tester.pump();
    pendingSmartRouteSave!.complete(true);
    pendingSmartRouteSave = null;
    await tester.pumpAndSettle();
    expect(getVpnMutations(), ['stopVPN', 'saveSmartRouteApps', 'stopVPN']);
    expect(managedConfigSaves, isEmpty);
    expect(find.byTooltip('Подключить VPN'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Smart Route app edit keeps managed binding on Hysteria retry', (
    tester,
  ) async {
    killSwitch = {'known': true, 'runtimeKnown': true};
    scriptedStarts.addAll([false, true]);
    await launchWithProfile(
      tester,
      initialProfile: const VpnProfile(
        id: 'qa-smart-route-hy2',
        name: 'QA Hysteria',
        kind: VpnProfileKind.hysteria2,
        originalInput: 'hy2://fixture@127.0.0.1:443',
        server: '127.0.0.1',
        port: 443,
        countryCode: 'PL',
        outbound: {
          'type': 'hysteria2',
          'server': '127.0.0.1',
          'server_port': 443,
          'password': 'fixture',
          'tls': {'enabled': true, 'server_name': 'fixture.invalid'},
        },
      ),
      preferences: const {'smartRouteRuDirect': true},
      waitForStopGuard: false,
    );
    await openSmartRouteAppSelection(tester);
    nativeCalls.clear();
    pendingStopAck = Completer<bool>();
    await tester.tap(find.text('Сохранить и переподключить'));
    await pumpUntilNativeCall(tester, 'stopVPN');
    nativeStatus = 'Stopped';
    pendingStopAck!.complete(true);
    pendingStopAck = null;
    for (
      var i = 0;
      i < 20 && nativeCalls.where((call) => call == 'startVPN').length < 2;
      i++
    ) {
      await tester.pump(const Duration(milliseconds: 250));
    }
    await tester.pumpAndSettle();
    expect(getVpnMutations(), [
      'stopVPN',
      'saveSmartRouteApps',
      'saveConfig',
      'startVPN',
      'stopVPN',
      'saveConfig',
      'startVPN',
    ]);
    expect(managedConfigSaves, [true, true]);
    expect(nativeConfigs[1], nativeConfigs[0]);
    expect(nativeStatus, 'Started');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('Auto A then B then C with one attempt per server and cleanup', (
    tester,
  ) async {
    scriptedStarts.addAll([false, false, true]);
    pendingStopAck = Completer<bool>();
    await launchWithProfile(
      tester,
      connected: false,
      initialProfile: autoFixture('a', 1443, 'NL'),
      extraProfiles: [
        autoFixture('b', 2443, 'PL'),
        autoFixture('c', 3443, 'DE'),
      ],
      preferences: {
        'automaticProfileSelection': true,
        'directLatencyAllowed': false,
      },
    );
    nativeCalls.clear();
    await pressAndConsent(tester);
    for (var i = 0; i < 10 && !nativeCalls.contains('stopVPN'); i++) {
      await tester.pump(const Duration(milliseconds: 250));
    }
    expect(getVpnMutations(), ['saveConfig', 'startVPN', 'stopVPN']);
    nativeStatus = 'Stopping';
    pendingStopAck!.complete(true);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));
    expect(getVpnMutations(), ['saveConfig', 'startVPN', 'stopVPN']);
    nativeStatus = 'Stopped';
    for (
      var i = 0;
      i < 20 && find.byKey(activeServerKey).evaluate().isEmpty;
      i++
    ) {
      await tester.pump(const Duration(milliseconds: 300));
    }
    expect(getVpnMutations(), [
      'saveConfig',
      'startVPN',
      'stopVPN',
      'saveConfig',
      'startVPN',
      'stopVPN',
      'saveConfig',
      'startVPN',
    ]);
    expect(
      nativeConfigs.map(
        (value) => RegExp(
          r'"server_port":\s*(1443|2443|3443)',
        ).firstMatch(value)?.group(1),
      ),
      ['1443', '2443', '3443'],
    );
    expect(find.byKey(activeServerKey), findsOneWidget);
    expect(
      (await SharedPreferences.getInstance()).getString('selectedProfileId'),
      'c',
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 10));
  });

  testWidgets('manual failure fences a stopped report before connecting B', (
    tester,
  ) async {
    final first = udpProfile.copyWith(
      port: 1443,
      outbound: {
        'type': 'hysteria2',
        'server': '127.0.0.1',
        'server_port': 1443,
        'password': 'fixture',
        'tls': {'enabled': true, 'server_name': 'fixture.invalid'},
      },
    );
    scriptedStarts.addAll([false, false, true]);
    await launchWithProfile(
      tester,
      connected: false,
      initialProfile: first,
      extraProfiles: [autoFixture('b', 2443, 'PL')],
      preferences: {'automaticProfileSelection': false},
    );
    nativeCalls.clear();
    nativeConfigs.clear();
    await pressAndConsent(tester);
    for (
      var i = 0;
      i < 24 && getVpnMutations().where((call) => call == 'stopVPN').length < 2;
      i++
    ) {
      await tester.pump(const Duration(milliseconds: 250));
    }
    await tester.pumpAndSettle();
    expect(getVpnMutations(), [
      'saveConfig',
      'startVPN',
      'stopVPN',
      'saveConfig',
      'startVPN',
      'stopVPN',
    ]);
    expect(nativeStatus, 'Stopped');
    await tester.tap(find.byKey(serverPickerKey));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('mobile-server-b')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(powerKey));
    for (
      var i = 0;
      i < 20 && find.byKey(activeServerKey).evaluate().isEmpty;
      i++
    ) {
      await tester.pump(const Duration(milliseconds: 250));
    }
    expect(find.byKey(activeServerKey), findsOneWidget);
    expect(nativeConfigs.last, contains('"server_port":2443'));
    expect(getVpnMutations().toList().sublist(6), ['saveConfig', 'startVPN']);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 10));
  });

  testWidgets('manual XHTTP failure does not start the same core twice', (
    tester,
  ) async {
    final first = (await ProfileImporter().importFromText(
      'vless://12345678-1234-4234-8234-123456789abc@127.0.0.1:1443'
      '?security=tls&type=xhttp&sni=fixture.invalid&path=%2Fqa#QA',
    )).single;
    scriptedStarts.addAll([false, true]);
    await launchWithProfile(
      tester,
      connected: false,
      initialProfile: first,
      extraProfiles: [autoFixture('b', 2443, 'PL')],
      preferences: {'automaticProfileSelection': false},
    );
    nativeCalls.clear();
    nativeConfigs.clear();
    await pressAndConsent(tester);
    for (var i = 0; i < 12 && !nativeCalls.contains('stopVPN'); i++) {
      await tester.pump(const Duration(milliseconds: 250));
    }
    await tester.pumpAndSettle();
    expect(getVpnMutations(), ['saveConfig', 'startVPN', 'stopVPN']);
    await tester.tap(find.byKey(serverPickerKey));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('mobile-server-b')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(powerKey));
    for (
      var i = 0;
      i < 20 && find.byKey(activeServerKey).evaluate().isEmpty;
      i++
    ) {
      await tester.pump(const Duration(milliseconds: 250));
    }
    expect(find.byKey(activeServerKey), findsOneWidget);
    expect(nativeConfigs.last, contains('"server_port":2443'));
    expect(getVpnMutations(), [
      'saveConfig',
      'startVPN',
      'stopVPN',
      'saveConfig',
      'startVPN',
    ]);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 10));
  });

  testWidgets('Auto waits without native starts, then follows a new network', (
    tester,
  ) async {
    scriptedStarts.add(true);
    moveToCellularOnStart = true;
    networkSnapshot = {'type': 'none', 'generation': 0, 'validated': false};
    await launchWithProfile(
      tester,
      connected: false,
      initialProfile: autoFixture('a', 1443, 'NL'),
      preferences: {
        'automaticProfileSelection': true,
        'directLatencyAllowed': false,
      },
    );
    nativeCalls.clear();
    await pressAndConsent(tester);
    await tester.pump(const Duration(seconds: 2));
    expect(getVpnMutations(), isEmpty);
    expect(find.text('Жду интернет…'), findsWidgets);
    networkSnapshot = {
      'type': 'wifi',
      'generation': 1,
      'validated': true,
      'probePhysicalNetwork': 'test-wifi',
      'autoPhysicalRouteConfirmed': true,
    };
    for (
      var i = 0;
      i < 25 && find.byKey(activeServerKey).evaluate().isEmpty;
      i++
    ) {
      await tester.pump(const Duration(milliseconds: 300));
    }
    expect(getVpnMutations(), [
      'saveConfig',
      'startVPN',
      'stopVPN',
      'saveConfig',
      'startVPN',
    ]);
    expect(find.byKey(activeServerKey), findsOneWidget);
    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getString('profileNetworkStabilityStats') ?? '',
      isNot(contains('auto-attempt-unavailable')),
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 10));
  });

  testWidgets(
    'fresh start offers import and connects in Auto after reopening',
    (tester) async {
      nativeStatus = 'Stopped';
      await tester.pumpWidget(const YurichConnectApp());
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 250));
      }
      await tester.tap(
        find.byKey(const ValueKey('mobile-empty-add-subscription')),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('mobile-subscription-input')),
        'hy2://fixture@127.0.0.1:443#Germany',
      );
      await tester.pump();
      await tester.tap(
        find.byKey(const ValueKey('mobile-subscription-submit')),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('mobile-empty-add-subscription')),
        findsNothing,
      );
      expect(
        (await SharedPreferences.getInstance()).getBool(
          'automaticProfileSelection',
        ),
        isTrue,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpWidget(const YurichConnectApp());
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 250));
      }
      expect(
        find.descendant(
          of: find.byKey(serverPickerKey),
          matching: find.text('Авто'),
        ),
        findsOneWidget,
      );
      expect(getVpnMutations(), isEmpty);
      scriptedStarts.add(true);
      await pressAndConsent(tester);
      for (
        var i = 0;
        i < 20 && find.byKey(activeServerKey).evaluate().isEmpty;
        i++
      ) {
        await tester.pump(const Duration(milliseconds: 300));
      }
      expect(find.byKey(activeServerKey), findsOneWidget);
      expect(getVpnMutations(), ['saveConfig', 'startVPN']);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 10));
    },
  );

  Color powerSurface(WidgetTester tester) {
    final element = tester.element(find.byKey(powerKey));
    return element.findAncestorWidgetOfExactType<Material>()!.color!;
  }

  Future<void> emitUnexpectedStop(WidgetTester tester) async {
    nativeStatus = 'Stopped';
    platform.status.add({
      'status': 'Stopped',
      'manualDisconnectRequested': false,
    });
    await tester.pump();
    // The asynchronous status stream can schedule the UI rebuild after the
    // current test frame. Do not rely on a perpetual animation for that frame.
    await tester.pump();
    expect(find.textContaining('VPN остановлен неожиданно'), findsOneWidget);
  }

  testWidgets('picker and active server agree despite stale Geo-IP', (
    tester,
  ) async {
    await launchWithProfile(
      tester,
      cachedCountryCode: 'DE',
      cachedCountryName: 'Germany',
    );
    final card = find.byKey(activeServerKey);
    expect(
      find.descendant(of: card, matching: find.textContaining('Польша')),
      findsOneWidget,
    );
    expect(find.text('🇵🇱'), findsOneWidget);
    expect(find.text('QA Poland'), findsNothing);
    expect(find.text('NaiveProxy'), findsNothing);
    expect(find.textContaining('Germany'), findsNothing);
    expect(find.textContaining('🇩🇪'), findsNothing);
    expect(find.text('Подключено'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'mobile server list keeps checks on VPN and preserves navigation',
    (tester) async {
      await prepareCaptureFonts(tester);
      await launchWithProfile(
        tester,
        waitForStopGuard: false,
        capture: true,
        viewport: const Size(360, 724),
        extraProfiles: const [udpProfile, offlineProfile],
      );
      await emitTraffic(tester, generation: 0);
      await tester.pump(const Duration(seconds: 1));
      expect(powerSurface(tester), YurichMobileColors.powerActive);
      expect(find.byKey(activeServerKey), findsOneWidget);
      await tester.ensureVisible(find.byKey(activeServerKey));
      await tester.pump();
      expect(
        tester.getBottomLeft(find.byKey(activeServerKey)).dy,
        lessThanOrEqualTo(tester.getTopLeft(find.byKey(quickSettingsKey)).dy),
      );
      expect(find.byKey(smartRouteKey), findsNothing);
      expect(find.textContaining('127.0.0.1'), findsNothing);
      await capture(tester, 'home-connected');

      nativeCalls.clear();
      await tester.tap(find.byKey(activeServerKey));
      await tester.pumpAndSettle();
      expect(find.byKey(serverPickerKey), findsNothing);
      expect(
        find.byKey(const ValueKey('mobile-server-qa-profile')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('mobile-server-qa-udp')),
        findsOneWidget,
      );
      expect(find.byTooltip('Активен'), findsOneWidget);
      expect(find.byType(ChoiceChip), findsNothing);
      expect(find.byKey(const ValueKey('mobile-auto-server')), findsOneWidget);
      expect(find.text('UDP: подключитесь'), findsOneWidget);
      expect(find.textContaining('127.0.0.1'), findsNothing);
      expect(
        tester.widget<IconButton>(find.byKey(checkServersKey)).onPressed,
        isNotNull,
      );
      await capture(tester, 'servers-connected');
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('mobile-server-qa-offline')),
        110,
        scrollable: find.byWidgetPredicate(
          (widget) =>
              widget is Scrollable &&
              widget.axisDirection == AxisDirection.down,
        ),
      );
      expect(find.text('offline'), findsOneWidget);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byKey(activeServerKey), findsOneWidget);
      await tester.tap(find.byKey(settingsKey));
      await tester.pumpAndSettle();
      expect(find.byKey(smartRouteKey), findsOneWidget);
      expect(find.text('Приложения напрямую'), findsOneWidget);
      final settingsScroll = find.descendant(
        of: find.byKey(const PageStorageKey('mobile-settings-scroll')),
        matching: find.byType(Scrollable),
      );
      await tester.scrollUntilVisible(
        find.text('Kill switch'),
        100,
        scrollable: settingsScroll,
      );
      expect(find.text('Kill switch'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('Приложения напрямую'),
        -100,
        scrollable: settingsScroll,
      );
      await capture(tester, 'settings');
      await tester.tap(find.text('Приложения напрямую'));
      await tester.pumpAndSettle();
      expect(find.text('QA App'), findsOneWidget);
      expect(nativeCalls, contains('getSmartRouteApps'));
      expect(getVpnMutations(), isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'offline home, quick settings and profile selection do not start VPN',
    (tester) async {
      await prepareCaptureFonts(tester);
      await launchWithProfile(
        tester,
        connected: false,
        capture: true,
        viewport: const Size(360, 724),
        extraProfiles: const [udpProfile],
      );
      expect(powerSurface(tester), YurichMobileColors.paper);
      expect(find.text('Нажмите для подключения'), findsOneWidget);
      expect(find.byKey(activeServerKey), findsNothing);
      await capture(tester, 'home-disconnected');

      nativeCalls.clear();
      await tester.tap(find.byKey(powerKey));
      await tester.pumpAndSettle();
      expect(find.text('Защита трафика через VPN'), findsOneWidget);
      await tester.tap(find.text('Отмена'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('mobile-import')));
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsOneWidget);
      expect(find.text('Добавить подписку'), findsOneWidget);
      expect(find.text('Ссылка или профиль'), findsOneWidget);
      expect(find.text('Из буфера'), findsOneWidget);
      expect(find.text('Сканировать QR'), findsOneWidget);
      final dialog = find.byKey(const ValueKey('mobile-subscription-dialog'));
      expect(
        tester.widget<Dialog>(dialog).backgroundColor,
        YurichMobileColors.canvas,
      );
      await capture(tester, 'mobile-add-subscription');
      final submit = find.byKey(const ValueKey('mobile-subscription-submit'));
      expect(tester.widget<FilledButton>(submit).onPressed, isNull);
      await tester.enterText(
        find.byKey(const ValueKey('mobile-subscription-input')),
        'https://example.invalid/subscription',
      );
      await tester.pump();
      expect(tester.widget<FilledButton>(submit).onPressed, isNotNull);
      await tester.tap(find.byTooltip('Закрыть'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(quickSettingsKey));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(smartRouteKey));
      await tester.pumpAndSettle();
      expect(
        (await SharedPreferences.getInstance()).getBool('smartRouteRuDirect'),
        isTrue,
      );
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(serverPickerKey));
      await tester.pumpAndSettle();
      expect(
        tester.widget<IconButton>(find.byKey(checkServersKey)).onPressed,
        isNull,
      );
      expect(find.text('Нужен VPN'), findsNWidgets(2));
      await tester.tap(find.byKey(const ValueKey('mobile-auto-server')));
      await tester.pumpAndSettle();
      expect(find.text('Авто'), findsOneWidget);
      expect(
        (await SharedPreferences.getInstance()).getBool(
          'automaticProfileSelection',
        ),
        isTrue,
      );
      await tester.tap(find.byKey(serverPickerKey));
      await tester.pumpAndSettle();
      await tester.tap(find.text(udpProfile.name));
      await tester.pumpAndSettle();
      expect(find.byKey(activeServerKey), findsNothing);
      expect(find.text(udpProfile.name), findsOneWidget);
      expect(
        (await SharedPreferences.getInstance()).getString('selectedProfileId'),
        udpProfile.id,
      );
      expect(
        (await SharedPreferences.getInstance()).getBool(
          'automaticProfileSelection',
        ),
        isFalse,
      );
      expect(getVpnMutations(), isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Stop cancels readiness and allows a new selection during cleanup',
    (tester) async {
      const initial = VpnProfile(
        id: 'qa-pending-start',
        name: 'QA pending start',
        kind: VpnProfileKind.naive,
        originalInput: '',
        server: '127.0.0.1',
        port: 443,
        countryCode: 'PL',
        outbound: {
          'type': 'naive',
          'server': '127.0.0.1',
          'server_port': 443,
          'username': 'fixture',
          'password': 'fixture',
          'tls': {'enabled': true, 'server_name': 'fixture.test'},
        },
      );
      await launchWithProfile(
        tester,
        connected: false,
        initialProfile: initial,
        extraProfiles: const [udpProfile],
      );
      nativeCalls.clear();
      await tester.tap(find.byKey(powerKey));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Принимаю'));
      for (var i = 0; i < 12 && !nativeCalls.contains('startVPN'); i++) {
        await tester.pump(const Duration(milliseconds: 250));
      }
      expect(nativeCalls.where((call) => call == 'startVPN'), hasLength(1));
      expect(find.byTooltip('Отменить подключение'), findsOneWidget);
      // Native may still return Stopped before Android dispatches the service.
      // Stop still needs to fence that start, and a selection is not a restart.
      pendingStopAck = Completer<bool>();
      await tester.tap(find.byKey(powerKey));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(nativeCalls.where((call) => call == 'stopVPN'), hasLength(1));
      await tester.tap(find.byKey(serverPickerKey));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('mobile-server-qa-udp')));
      await tester.pumpAndSettle();
      pendingStopAck!.complete(true);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(nativeCalls.where((call) => call == 'startVPN'), hasLength(1));
      expect(find.byTooltip('Подключить VPN'), findsOneWidget);
      expect(find.byKey(activeServerKey), findsNothing);
      expect(
        (await SharedPreferences.getInstance()).getString('selectedProfileId'),
        udpProfile.id,
      );
      expect(find.text('Нет стабильного соединения'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'cancelling Auto ignores a late probe gate and does not start VPN',
    (tester) async {
      const candidate = VpnProfile(
        id: 'qa-auto',
        name: 'QA Auto',
        kind: VpnProfileKind.naive,
        originalInput: '',
        server: 'vpn.example.org',
        port: 443,
        countryCode: 'PL',
      );
      killSwitch = {'supported': true, 'known': true, 'vpnActive': false};
      pendingDirectGate = Completer<String?>();
      await launchWithProfile(
        tester,
        connected: false,
        initialProfile: candidate,
        preferences: {
          'automaticProfileSelection': true,
          'directLatencyAllowed': true,
        },
      );
      nativeCalls.clear();
      await tester.tap(find.byKey(powerKey));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Принимаю'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(nativeCalls, contains('getDirectProbeNetwork'));
      expect(find.byTooltip('Отменить подключение'), findsOneWidget);
      await tester.tap(find.byKey(powerKey));
      await tester.pump();
      pendingDirectGate!.complete('late-network');
      await tester.pumpAndSettle();
      expect(find.byTooltip('Подключить VPN'), findsOneWidget);
      expect(getVpnMutations(), isEmpty);
      expect(nativeCalls, isNot(contains('resolveDirectProbeHost')));
    },
  );

  testWidgets(
    'selection replaces pending start only after native stop is confirmed',
    (tester) async {
      const first = VpnProfile(
        id: 'qa-replace-first',
        name: 'QA first profile',
        kind: VpnProfileKind.naive,
        originalInput: '',
        server: '127.0.0.1',
        port: 443,
        countryCode: 'PL',
        outbound: {
          'type': 'naive',
          'server': '127.0.0.1',
          'server_port': 443,
          'username': 'fixture',
          'password': 'fixture',
          'tls': {'enabled': true, 'server_name': 'fixture.test'},
        },
      );
      final next = first.copyWith(
        id: 'qa-replace-next',
        name: 'QA next profile',
        port: 7443,
        outbound: {...first.outbound!, 'server_port': 7443},
      );
      await launchWithProfile(
        tester,
        connected: false,
        initialProfile: first,
        extraProfiles: [next],
      );
      nativeCalls.clear();
      nativeConfigs.clear();
      await tester.tap(find.byKey(powerKey));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Принимаю'));
      for (var i = 0; i < 12 && !nativeCalls.contains('startVPN'); i++) {
        await tester.pump(const Duration(milliseconds: 250));
      }
      expect(getVpnMutations(), ['saveConfig', 'startVPN']);
      expect(nativeStatus, 'Stopped');
      expect(find.byTooltip('Отменить подключение'), findsOneWidget);

      pendingStopAck = Completer<bool>();
      await tester.tap(find.byKey(serverPickerKey));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('mobile-server-qa-replace-next')),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(getVpnMutations(), ['saveConfig', 'startVPN', 'stopVPN']);

      // Returning the stop command acknowledgement is not evidence that the
      // previous service finished cleanup.
      nativeStatus = 'Stopping';
      pendingStopAck!.complete(true);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 700));
      expect(getVpnMutations(), ['saveConfig', 'startVPN', 'stopVPN']);
      expect(nativeConfigs, hasLength(1));

      nativeStatus = 'Stopped';
      for (var i = 0; i < 12 && nativeConfigs.length < 2; i++) {
        await tester.pump(const Duration(milliseconds: 250));
      }
      await tester.pump();
      expect(getVpnMutations(), [
        'saveConfig',
        'startVPN',
        'stopVPN',
        'saveConfig',
        'startVPN',
      ]);
      expect(
        nativeConfigs.last,
        matches(RegExp(r'"server_port"\s*:\s*7443\b')),
      );
      expect(find.byKey(activeServerKey), findsNothing);
      nativeStatus = 'Started';
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pumpAndSettle();
      expect(find.byKey(activeServerKey), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 2));
    },
  );

  testWidgets('failed profile switch is not shown as a confirmed server', (
    tester,
  ) async {
    const next = VpnProfile(
      id: 'qa-other-naive',
      name: 'QA Stockholm',
      kind: VpnProfileKind.naive,
      originalInput: 'naive+https://fixture:fixture@127.0.0.1:443',
      server: '127.0.0.1',
      port: 0,
      outbound: {
        'type': 'naive',
        'server': '127.0.0.1',
        'server_port': 443,
        'username': 'fixture',
        'password': 'fixture',
        'tls': {'enabled': true, 'server_name': 'fixture.test'},
      },
      countryCode: 'SE',
    );
    await launchWithProfile(
      tester,
      waitForStopGuard: false,
      extraProfiles: const [next],
    );
    expect(find.byKey(activeServerKey), findsOneWidget);
    configSaved = false;
    await tester.tap(find.byKey(serverPickerKey));
    await tester.pumpAndSettle();
    await tester.tap(find.text(next.name));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(nativeCalls, contains('saveConfig'));
    expect(find.text(next.name), findsOneWidget);
    expect(find.byKey(activeServerKey), findsNothing);
    expect(find.byKey(const ValueKey('mobile-active-latency')), findsNothing);
    expect(powerSurface(tester), YurichMobileColors.powerError);
    await tester.tap(find.byKey(serverPickerKey));
    await tester.pumpAndSettle();
    expect(find.byType(SnackBar), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('terminal start failure glows red without a false active card', (
    tester,
  ) async {
    const profile = VpnProfile(
      id: 'qa-start-failure',
      name: 'QA Poland',
      kind: VpnProfileKind.naive,
      originalInput: '',
      server: '127.0.0.1',
      port: 0,
      countryCode: 'PL',
      outbound: {
        'type': 'naive',
        'server': '127.0.0.1',
        'server_port': 443,
        'username': 'fixture',
        'password': 'fixture',
        'tls': {'enabled': true, 'server_name': 'fixture.test'},
      },
    );
    configSaved = false;
    await prepareCaptureFonts(tester);
    await launchWithProfile(
      tester,
      connected: false,
      capture: true,
      viewport: const Size(360, 724),
      initialProfile: profile,
    );
    expect(powerSurface(tester), YurichMobileColors.paper);
    await tester.tap(find.byKey(powerKey));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Принимаю'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(nativeCalls, contains('saveConfig'));
    expect(find.text('Нет стабильного соединения'), findsOneWidget);
    expect(powerSurface(tester), YurichMobileColors.powerError);
    expect(find.byKey(activeServerKey), findsNothing);
    final snackbar = tester.widget<SnackBar>(find.byType(SnackBar));
    expect(snackbar.duration, const Duration(seconds: 3));
    expect(snackbar.action, isNull);
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
    expect(find.byType(SnackBar), findsNothing);
    await capture(tester, 'home-error');
    expect(tester.takeException(), isNull);
  });

  testWidgets('ordinary network transition does not glow red', (tester) async {
    await launchWithProfile(tester, waitForStopGuard: false);
    expect(powerSurface(tester), YurichMobileColors.powerActive);
    await emitTraffic(tester, generation: 1);
    await tester.pump(const Duration(seconds: 1));
    expect(powerSurface(tester), YurichMobileColors.paper);
    expect(find.text('Нет стабильного соединения'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('strict Kill Switch suspends Smart Route in the gear screen', (
    tester,
  ) async {
    killSwitch = {
      'known': true,
      'runtimeKnown': true,
      'requested': true,
      'alwaysOn': true,
      'lockdown': true,
      'strictRuntime': true,
      'vpnActive': true,
    };
    tester.platformDispatcher.textScaleFactorTestValue = 1.5;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await launchWithProfile(
      tester,
      waitForStopGuard: false,
      viewport: const Size(320, 640),
    );
    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(settingsKey));
    await tester.pumpAndSettle();
    expect(
      tester.widget<SwitchListTile>(find.byKey(smartRouteKey)).onChanged,
      isNull,
    );
    expect(find.text('Приостановлен Kill Switch'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('kill-switch-status')),
      100,
      scrollable: find.descendant(
        of: find.byKey(const PageStorageKey('mobile-settings-scroll')),
        matching: find.byType(Scrollable),
      ),
    );
    expect(find.text('Включён: Android + строгий TUN'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('battery policy is optional and opens only from settings', (
    tester,
  ) async {
    final calls = <String>[];
    binding.defaultBinaryMessenger.setMockMethodCallHandler(powerChannel, (
      call,
    ) async {
      calls.add(call.method);
      return switch (call.method) {
        'isIgnoringBatteryOptimizations' => false,
        'openAppBatterySettings' => true,
        _ => fail('Unexpected battery action: ${call.method}'),
      };
    });
    await launchWithProfile(tester, waitForStopGuard: false);
    expect(calls, isEmpty);
    expect(find.byType(SnackBar), findsNothing);

    await tester.tap(find.byKey(settingsKey));
    await tester.pumpAndSettle();
    expect(calls, ['isIgnoringBatteryOptimizations']);
    final tile = find.byKey(const ValueKey('mobile-background-power'));
    await tester.ensureVisible(tile);
    await tester.tap(tile);
    await tester.pumpAndSettle();
    expect(calls, ['isIgnoringBatteryOptimizations', 'openAppBatterySettings']);
    expect(find.byType(SnackBar), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('mobile app support keeps settings, FAQ and log lifecycle', (
    tester,
  ) async {
    const settingsScrollKey = PageStorageKey('mobile-settings-scroll');
    const supportKey = PageStorageKey('mobile-app-settings-expanded');
    const supportTabKey = ValueKey('mobile-app-support-tab');
    const languageKey = ValueKey('mobile-app-language');
    const updatesKey = PageStorageKey('mobile-app-updates');
    const faqKey = PageStorageKey('mobile-app-faq');
    const logsKey = ValueKey('mobile-app-logs');

    tester.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await launchWithProfile(
      tester,
      connected: false,
      viewport: const Size(320, 640),
    );
    nativeCalls.clear();
    await tester.tap(find.byKey(settingsKey));
    await tester.pumpAndSettle();
    expect(find.byKey(smartRouteKey), findsOneWidget);
    final settings = find.byKey(settingsScrollKey);
    Future<void> reveal(Finder finder, {double delta = 140}) async {
      // An expanded parent builds every nested control, including those
      // well below the viewport. Existence alone is not enough to tap it.
      for (var i = 0; i < 24; i++) {
        var step = delta;
        if (finder.evaluate().length == 1) {
          final viewport = tester.getRect(settings).deflate(8);
          final target = tester.getRect(finder).center;
          if (viewport.contains(target)) return;
          step = target.dy < viewport.top ? -delta.abs() : delta.abs();
        }
        await tester.drag(settings, Offset(0, -step));
        await tester.pumpAndSettle();
      }
      expect(finder.hitTestable(), findsOneWidget);
    }

    final delegate = tester.widget<ListView>(settings).childrenDelegate;
    final rowKeys = (delegate as SliverChildListDelegate).children.map(
      (widget) => widget.key,
    );
    expect(
      rowKeys,
      isNot(contains(const PageStorageKey('mobile-profile-insight-expanded'))),
    );
    await reveal(find.byKey(const ValueKey('kill-switch-status')));
    expect(find.text('Kill switch'), findsOneWidget);
    await reveal(find.text('Приложение и поддержка'));
    expect(find.text('Профиль и сеть'), findsNothing);
    expect(find.byKey(supportKey), findsOneWidget);
    await tester.tap(find.text('Приложение и поддержка'));
    await tester.pumpAndSettle();

    final community = find.descendant(
      of: find.byKey(supportTabKey),
      matching: find.text('Проект'),
    );
    await reveal(community);
    expect(
      Theme.of(tester.element(community)).colorScheme.primary,
      YurichMobileColors.blue,
    );
    await tester.tap(community);
    await tester.pumpAndSettle();
    await reveal(find.text('Telegram'));
    expect(find.text('VK'), findsOneWidget);

    final english = find.descendant(
      of: find.byKey(languageKey),
      matching: find.text('EN'),
    );
    await reveal(english);
    await tester.tap(english);
    await tester.pumpAndSettle();
    expect(
      (await SharedPreferences.getInstance()).getString('languageCode'),
      'en',
    );
    expect(find.text('App and support'), findsOneWidget);

    await reveal(find.byKey(updatesKey));
    expect(find.byKey(updatesKey), findsOneWidget);
    final faq = find.descendant(
      of: find.byKey(faqKey),
      matching: find.text('FAQ'),
    );
    await reveal(faq);
    await tester.tap(faq);
    await tester.pumpAndSettle();
    expect(
      find.text('How do I enable and verify Smart Route?'),
      findsOneWidget,
    );
    expect(find.textContaining('Profile and network'), findsNothing);
    await tester.tap(faq);
    await tester.pumpAndSettle();

    final logs = find.descendant(
      of: find.byKey(logsKey),
      matching: find.text('Logs and diagnostics'),
    );
    await reveal(logs);
    expect(platform.logs.hasListener, isFalse);
    await tester.tap(logs);
    await tester.pumpAndSettle();
    expect(platform.logs.hasListener, isTrue);
    expect(nativeCalls, contains('getLogs'));

    final supportTitle = find.text('App and support');
    await reveal(supportTitle, delta: -140);
    await tester.tap(supportTitle);
    await tester.pumpAndSettle();
    expect(platform.logs.hasListener, isFalse);
    await tester.tap(supportTitle);
    await tester.pumpAndSettle();
    await reveal(logs);
    expect(platform.logs.hasListener, isFalse);
    await tester.tap(logs);
    await tester.pumpAndSettle();
    expect(platform.logs.hasListener, isTrue);

    await tester.tap(find.byKey(const ValueKey('mobile-home-tab')));
    await tester.pumpAndSettle();
    expect(platform.logs.hasListener, isFalse);
    expect(getVpnMutations(), isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'local pilot asks consent and records only one terminal failure',
    (tester) async {
      const key = ValueKey('mobile-local-incidents');
      const pilotEpoch = 'synthetic-local-consent';
      final records = <Map<Object?, Object?>>[];
      var enabled = false;
      var queued = 0;
      binding.defaultBinaryMessenger.setMockMethodCallHandler(incidentChannel, (
        call,
      ) async {
        switch (call.method) {
          case 'state':
            break;
          case 'setEnabled':
            enabled = call.arguments['enabled'] == true;
            if (!enabled) queued = 0;
          case 'record':
            records.add(Map<Object?, Object?>.from(call.arguments as Map));
            queued++;
          default:
            fail('Unexpected local action: ${call.method}');
        }
        return {
          'enabled': enabled,
          'queued': queued,
          if (enabled) 'epoch': pilotEpoch,
        };
      });
      const profile = VpnProfile(
        id: 'fixture',
        name: 'QA profile',
        kind: VpnProfileKind.naive,
        originalInput: '',
        server: '127.0.0.1',
        port: 443,
        outbound: {
          'type': 'naive',
          'server': '127.0.0.1',
          'server_port': 443,
          'username': 'fixture',
          'password': 'fixture',
          'tls': {'enabled': true, 'server_name': 'fixture.invalid'},
        },
      );
      await launchWithProfile(
        tester,
        connected: false,
        initialProfile: profile,
      );
      await tester.tap(find.byKey(settingsKey));
      await tester.pumpAndSettle();
      Future<void> showPilot() => tester.scrollUntilVisible(
        find.byKey(key),
        170,
        scrollable: find.descendant(
          of: find.byKey(const PageStorageKey('mobile-settings-scroll')),
          matching: find.byType(Scrollable),
        ),
      );
      await showPilot();
      expect(tester.widget<SwitchListTile>(find.byKey(key)).value, isFalse);
      await tester.tap(find.byKey(key));
      await tester.pumpAndSettle();
      expect(enabled, isFalse);
      await tester.tap(find.text('Сохранять на телефоне'));
      await tester.pumpAndSettle();
      expect(enabled, isTrue);
      expect(records, isEmpty);

      await tester.tap(find.byKey(const ValueKey('mobile-home-tab')));
      await tester.pumpAndSettle();
      rejectNativeStart = true;
      await tester.tap(find.byKey(powerKey));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Принимаю'));
      for (var frame = 0; frame < 70 && records.isEmpty; frame++) {
        await tester.pump(const Duration(milliseconds: 250));
      }
      expect(nativeCalls.where((call) => call == 'startVPN'), isNotEmpty);
      expect(records, hasLength(1));
      expect(records.single, {
        'epoch': pilotEpoch,
        'protocol': 'naive',
        'network': 'wifi',
        'stage': 'vpn_start',
        'code': 'start_failed',
      });
      await tester.tap(find.byKey(settingsKey));
      await tester.pumpAndSettle();
      await showPilot();
      await tester.tap(find.byKey(key));
      await tester.pumpAndSettle();
      expect(enabled, isFalse);
      expect(queued, 0);
    },
    skip: !LocalConnectionIncidentsService.pilotBuild,
  );

  testWidgets(
    'Hermes preview displays only a synthetic example while consent is off',
    (tester) async {
      var previewReads = 0;
      binding.defaultBinaryMessenger.setMockMethodCallHandler(incidentChannel, (
        call,
      ) async {
        switch (call.method) {
          case 'state':
            return {'enabled': false, 'queued': 0};
          case 'hermesPreview':
            previewReads++;
            return '{"schema_version":1,"report_id":"sample-only"}';
          default:
            fail('Unexpected diagnostic action: ${call.method}');
        }
      });
      await launchWithProfile(tester, connected: false);
      await tester.tap(find.byKey(settingsKey));
      await tester.pumpAndSettle();
      final tile = find.byKey(const ValueKey('mobile-hermes-preview'));
      final settings = find.byKey(
        const PageStorageKey('mobile-settings-scroll'),
      );
      for (var i = 0; i < 12 && tile.hitTestable().evaluate().isEmpty; i++) {
        await tester.drag(settings, const Offset(0, -140));
        await tester.pumpAndSettle();
      }
      expect(tile.hitTestable(), findsOneWidget);
      await tester.tap(tile);
      await tester.pumpAndSettle();
      expect(previewReads, 1);
      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('Отчёт Yurich'),
        ),
        findsOneWidget,
      );
      expect(find.byType(SelectableText), findsOneWidget);
      expect(find.textContaining('sample-only'), findsOneWidget);
      expect(
        find.textContaining(
          LocalConnectionIncidentsService.hermesDeliveryPilotBuild
              ? 'Отправка включается отдельно'
              : 'отправка недоступна',
        ),
        findsWidgets,
      );
      expect(getVpnMutations(), isEmpty);
      await tester.tap(find.text('Закрыть'));
      await tester.pumpAndSettle();
    },
    skip: !LocalConnectionIncidentsService.hermesPilotBuild,
  );

  Future<Finder> findHermesDeliveryTile(WidgetTester tester) async {
    await tester.tap(find.byKey(settingsKey));
    await tester.pumpAndSettle();
    final tile = find.byKey(const ValueKey('mobile-hermes-delivery'));
    final settings = find.byKey(const PageStorageKey('mobile-settings-scroll'));
    for (var i = 0; i < 12 && tile.hitTestable().evaluate().isEmpty; i++) {
      await tester.drag(settings, const Offset(0, -140));
      await tester.pumpAndSettle();
    }
    return tile;
  }

  testWidgets(
    'ordinary Android builds do not expose Hermes delivery',
    (tester) async {
      var nativeDeliveryCalls = 0;
      binding.defaultBinaryMessenger.setMockMethodCallHandler(incidentChannel, (
        call,
      ) async {
        if (call.method != 'state') nativeDeliveryCalls++;
        return {'enabled': false, 'queued': 0};
      });
      await launchWithProfile(tester, connected: false);
      expect(await findHermesDeliveryTile(tester), findsNothing);
      final incidents = const LocalConnectionIncidentsService();
      expect(await incidents.hermesDeliveryState(), isNull);
      expect(
        await incidents.configureHermesDelivery(
          enabled: true,
          bearer: 'fixture-only',
        ),
        isNull,
      );
      expect(await incidents.setHermesSecretScreen(true), isFalse);
      expect(nativeDeliveryCalls, 0);
    },
    skip: LocalConnectionIncidentsService.hermesDeliveryPilotBuild,
  );

  testWidgets(
    'Hermes delivery needs its own consent and clears the token on revoke',
    (tester) async {
      const token = 'fixture-only';
      var enabled = false;
      var secretScreen = false;
      var configured = 0;
      var localEpoch = 'fixture-local-epoch';
      final screenEvents = <bool>[];
      binding.defaultBinaryMessenger.setMockMethodCallHandler(incidentChannel, (
        call,
      ) async {
        switch (call.method) {
          case 'state':
            return {'enabled': true, 'queued': 0, 'epoch': localEpoch};
          case 'hermesDeliveryState':
            return {
              'enabled': enabled,
              'tokenConfigured': enabled,
              'routeReady': false,
            };
          case 'setHermesSecretScreen':
            secretScreen = call.arguments['enabled'] == true;
            screenEvents.add(secretScreen);
            return true;
          case 'configureHermesDelivery':
            expect(secretScreen, isTrue);
            configured++;
            enabled = call.arguments['enabled'] == true;
            if (enabled) {
              expect(call.arguments, {'enabled': true, 'bearer': token});
            } else {
              expect(call.arguments, {'enabled': false});
              localEpoch = 'fixture-new-local-epoch';
            }
            return {
              'enabled': enabled,
              'tokenConfigured': enabled,
              'routeReady': false,
            };
          default:
            fail('Unexpected diagnostic action: ${call.method}');
        }
      });
      await launchWithProfile(tester, connected: false);
      await tester.tap((await findHermesDeliveryTile(tester)).hitTestable());
      await tester.pumpAndSettle();
      expect(screenEvents, [true]);
      expect(find.text('Отправка выключена.'), findsOneWidget);
      final save = find.byKey(const ValueKey('hermes-delivery-save'));
      final field = find.byKey(const ValueKey('hermes-delivery-bearer'));
      final consent = find.byKey(const ValueKey('hermes-delivery-consent'));
      final fieldWidget = tester.widget<TextField>(field);
      expect(fieldWidget.obscureText, isTrue);
      expect(fieldWidget.enableInteractiveSelection, isFalse);
      expect(fieldWidget.enableIMEPersonalizedLearning, isFalse);
      expect(tester.widget<CheckboxListTile>(consent).value, isFalse);
      await tester.ensureVisible(field);
      await tester.enterText(field, token);
      await tester.pumpAndSettle();
      expect(tester.widget<FilledButton>(save).onPressed, isNull);
      expect(configured, 0);
      await tester.ensureVisible(consent);
      await tester.tap(consent);
      await tester.pumpAndSettle();
      // Backgrounding the screen discards an unsaved token and opt-in.
      for (final state in [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]) {
        binding.handleAppLifecycleStateChanged(state);
      }
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(field).controller?.text, isEmpty);
      expect(tester.widget<CheckboxListTile>(consent).value, isFalse);
      expect(tester.widget<FilledButton>(save).onPressed, isNull);
      await tester.ensureVisible(field);
      await tester.enterText(field, token);
      await tester.pumpAndSettle();
      await tester.ensureVisible(consent);
      await tester.tap(consent);
      await tester.pumpAndSettle();
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(configured, 1);
      expect(tester.widget<TextField>(field).controller?.text, isEmpty);
      expect(
        find.textContaining('пока Android не подтвердит подходящий маршрут'),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const ValueKey('hermes-delivery-revoke')));
      await tester.pumpAndSettle();
      expect(configured, 1);
      await tester.tap(
        find.byKey(const ValueKey('hermes-delivery-revoke-confirm')),
      );
      await tester.pumpAndSettle();
      expect(configured, 2);
      expect(find.text('Отправка выключена.'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, 'Закрыть'));
      await tester.pumpAndSettle();
      expect(screenEvents, [true, false]);
      expect(getVpnMutations(), isEmpty);
      expect(tester.takeException(), isNull);
    },
    skip: !LocalConnectionIncidentsService.hermesDeliveryPilotBuild,
  );

  testWidgets(
    'Hermes token field never opens when secure screen is unavailable',
    (tester) async {
      final screenEvents = <bool>[];
      binding.defaultBinaryMessenger.setMockMethodCallHandler(incidentChannel, (
        call,
      ) async {
        switch (call.method) {
          case 'state':
            return {'enabled': true, 'queued': 0, 'epoch': 'fixture-local'};
          case 'hermesDeliveryState':
            return {'enabled': false, 'tokenConfigured': false};
          case 'setHermesSecretScreen':
            screenEvents.add(call.arguments['enabled'] == true);
            return false;
          default:
            fail('Unexpected diagnostic action: ${call.method}');
        }
      });
      await launchWithProfile(tester, connected: false);
      await tester.tap((await findHermesDeliveryTile(tester)).hitTestable());
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('hermes-delivery-bearer')),
        findsNothing,
      );
      expect(find.textContaining('Не удалось защитить экран'), findsOneWidget);
      expect(screenEvents, [true, false]);
      expect(tester.takeException(), isNull);
    },
    skip: !LocalConnectionIncidentsService.hermesDeliveryPilotBuild,
  );

  testWidgets('new startup discards pending traffic from previous connection', (
    tester,
  ) async {
    await launchWithProfile(tester);
    await emitTraffic(tester);
    nativeStatus = 'Starting';
    platform.status.add({
      'status': 'Starting',
      'manualDisconnectRequested': false,
    });
    await tester.pump();
    nativeStatus = 'Started';
    await emitConnected(tester);
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('1 MB'), findsNothing);
    expect(find.text('0 B'), findsOneWidget);
    await emitTraffic(tester);
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('1 MB'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('traffic received during startup cannot overwrite new counters', (
    tester,
  ) async {
    await launchWithProfile(tester);
    nativeStatus = 'Starting';
    platform.status.add({
      'status': 'Starting',
      'manualDisconnectRequested': false,
    });
    await tester.pump();
    await emitTraffic(tester);
    nativeStatus = 'Started';
    await emitConnected(tester);
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('1 MB'), findsNothing);
    expect(find.textContaining('8 KB/s'), findsNothing);
    expect(find.text('0 B'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final reason in ['watchdog:readiness:periodic', 'network-rebind']) {
    testWidgets(
      'native recovery preserves session counters across Starting ($reason)',
      (tester) async {
        await launchWithProfile(tester);
        await emitTraffic(tester);
        await tester.pump(const Duration(seconds: 1));
        expect(find.text('1 MB'), findsOneWidget);

        nativeStatus = 'Starting';
        platform.status.add({
          'status': 'Starting',
          'manualDisconnectRequested': false,
          'desiredRunning': true,
          'sessionReason': reason,
        });
        await tester.pump();
        expect(find.text('1 MB'), findsOneWidget);

        // Periodic status polls do not carry the service's session reason. Once a
        // recovery was identified, they must not reset the same logical session.
        platform.status.add({
          'status': 'Starting',
          'manualDisconnectRequested': false,
        });
        await tester.pump();
        expect(find.text('1 MB'), findsOneWidget);

        nativeStatus = 'Started';
        await emitConnected(tester);
        expect(find.text('1 MB'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('confirmed native recovery clears stale stop message', (
    tester,
  ) async {
    await launchWithProfile(tester);
    await emitUnexpectedStop(tester);
    expect(powerSurface(tester), YurichMobileColors.powerError);
    nativeStatus = 'Starting';
    platform.status.add({
      'status': 'Starting',
      'manualDisconnectRequested': false,
    });
    await tester.pump();
    nativeStatus = 'Started';
    await emitConnected(tester);
    expect(find.byKey(activeServerKey), findsOneWidget);
    expect(powerSurface(tester), YurichMobileColors.powerActive);
    expect(find.textContaining('VPN остановлен неожиданно'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('status polling clears recovery message without status event', (
    tester,
  ) async {
    await launchWithProfile(tester);
    await emitUnexpectedStop(tester);
    nativeStatus = 'Started';
    await tester.pump(const Duration(seconds: 20));
    await tester.pump();
    expect(find.byKey(activeServerKey), findsOneWidget);
    expect(find.textContaining('VPN остановлен неожиданно'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('ready status preserves unrelated alert message', (tester) async {
    await launchWithProfile(tester);
    platform.status.add({'type': 'alert', 'message': 'QA settings notice'});
    await tester.pump();
    await emitConnected(tester);
    expect(find.text('QA settings notice'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

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

  testWidgets('keeps stable UI frame-free and restores traffic on resume', (
    tester,
  ) async {
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
    expect(binding.transientCallbackCount, 0);
    expect(binding.hasScheduledFrame, isFalse);
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
    expect(binding.transientCallbackCount, 0);
    expect(binding.hasScheduledFrame, isFalse);
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
  });

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
