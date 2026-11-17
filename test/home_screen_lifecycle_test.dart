import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:aurum_vpn/main.dart' as entrypoint;
import 'package:aurum_vpn/src/app.dart';
import 'package:aurum_vpn/src/models/vpn_profile.dart';
import 'package:aurum_vpn/src/screens/home_screen.dart';
import 'package:aurum_vpn/src/screens/tv_home_screen.dart';
import 'package:aurum_vpn/src/services/app_update_service.dart';
import 'package:aurum_vpn/src/services/local_connection_incidents.dart';
import 'package:aurum_vpn/src/services/on_device_diagnostics.dart';
import 'package:aurum_vpn/src/services/profile_geo_service.dart';
import 'package:aurum_vpn/src/services/profile_importer.dart';
import 'package:aurum_vpn/src/services/profile_store.dart';
import 'package:aurum_vpn/src/services/runtime_config_matcher.dart';
import 'package:aurum_vpn/src/services/sing_box_config_builder.dart';
import 'package:aurum_vpn/src/theme/yurich_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
// The public helper cannot simulate failure of an individual secure write.
// ignore: depend_on_referenced_packages
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_singbox_vpn/flutter_singbox_method_channel.dart';
import 'package:flutter_singbox_vpn/flutter_singbox_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
// The public SharedPreferences test helper cannot simulate a failed write.
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const pluginPrefix = 'com.tecclub.flutter_singbox';
  const powerChannel = MethodChannel('online.dnsai.ivanvpn/power');
  const incidentChannel = MethodChannel('online.dnsai.ivanvpn/local_incidents');
  const soakChannel = MethodChannel('online.dnsai.ivanvpn/soak');
  final nativeCalls = <String>[];
  final nativeConfigs = <String>[];
  final appNotifications = <Map<Object?, Object?>>[];
  final connectionNotifications = <Map<Object?, Object?>>[];
  final managedConfigSaves = <bool>[];
  final smartRouteSelections = <List<String>>[];
  final bufferedNativeLogs = <String>[];
  var nativeStatus = 'Started';
  var nativeStatusMissing = false;
  var appNotificationAllowed = true;
  PlatformException? appNotificationError;
  PlatformException? statusReadError;
  Completer<String>? pendingVpnStatusRead;
  PlatformException? manualDisconnectReadError;
  var restoredNativeConfig = '{}';
  PlatformException? configReadError;
  Completer<String>? pendingRuntimeConfigRead;
  var nativeManualStopRequested = false;
  var killSwitch = <String, Object>{};
  final scriptedProtectionReads = <Map<String, Object>>[];
  PlatformException? killSwitchWriteError;
  PlatformException? killSwitchSettingsError;
  var configSaved = true;
  var rejectNativeStart = false;
  final scriptedStarts = <bool>[];
  PlatformException? startCommandError;
  PlatformException? reloadCommandError;
  Completer<bool>? pendingConfigAck;
  Completer<bool>? pendingStartAck;
  Completer<bool>? pendingReloadAck;
  Completer<List<String>>? pendingBufferedLogs;
  Completer<bool>? pendingConnectionNotification;
  var acknowledgeFailedStartup = false;
  var moveToCellularOnStart = false;
  var networkSnapshot = <String, Object>{};
  Completer<Map<String, Object>>? pendingNetworkRead;
  PlatformException? networkSnapshotError;
  Map<String, Object>? networkOnNextStatusRead;
  Completer<bool>? pendingStopAck;
  Completer<bool>? pendingManualDisconnectRead;
  Completer<bool>? pendingSmartRouteInstallCheck;
  Completer<bool>? pendingSmartRouteSave;
  var smartRouteAppsUnavailable = false;
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
    appNotifications.clear();
    connectionNotifications.clear();
    managedConfigSaves.clear();
    smartRouteSelections.clear();
    bufferedNativeLogs.clear();
    nativeStatus = 'Started';
    nativeStatusMissing = false;
    appNotificationAllowed = true;
    appNotificationError = null;
    statusReadError = null;
    pendingVpnStatusRead = null;
    manualDisconnectReadError = null;
    restoredNativeConfig = '{}';
    configReadError = null;
    pendingRuntimeConfigRead = null;
    nativeManualStopRequested = false;
    killSwitch = {};
    scriptedProtectionReads.clear();
    killSwitchWriteError = null;
    killSwitchSettingsError = null;
    configSaved = true;
    rejectNativeStart = false;
    scriptedStarts.clear();
    startCommandError = null;
    reloadCommandError = null;
    pendingConfigAck = null;
    pendingStartAck = null;
    pendingReloadAck = null;
    pendingBufferedLogs = null;
    pendingConnectionNotification = null;
    networkOnNextStatusRead = null;
    networkSnapshotError = null;
    pendingNetworkRead = null;
    acknowledgeFailedStartup = false;
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
    smartRouteAppsUnavailable = false;
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
          if (pendingConfigAck case final ack?) return ack.future;
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
        if (call.method == 'setKillSwitchRequested') {
          if (killSwitchWriteError case final error?) throw error;
          killSwitch = {
            ...killSwitch,
            'requested': call.arguments['enabled'] as bool,
          };
          return true;
        }
        if (call.method == 'openVpnSettings') {
          if (killSwitchSettingsError case final error?) throw error;
        }
        if (call.method == 'initializeSmartRouteInstallDefault') {
          return await pendingSmartRouteInstallCheck?.future ?? false;
        }
        if (call.method == 'getManualDisconnectRequested') {
          if (manualDisconnectReadError case final error?) throw error;
          if (pendingManualDisconnectRead case final read?) return read.future;
        }
        if (call.method == 'getVPNStatus') {
          if (statusReadError case final error?) throw error;
          if (pendingVpnStatusRead case final read?) return read.future;
          if (networkOnNextStatusRead case final snapshot?) {
            networkSnapshot = snapshot;
            networkOnNextStatusRead = null;
          }
        }
        if (call.method == 'startVPN') {
          if (startCommandError case final error?) throw error;
          if (pendingStartAck case final ack?) return ack.future;
        }
        if (call.method == 'reloadVPN') {
          if (reloadCommandError case final error?) throw error;
          if (pendingReloadAck case final ack?) return ack.future;
        }
        if (call.method == 'getConfig') {
          if (configReadError case final error?) throw error;
          if (pendingRuntimeConfigRead case final read?) return read.future;
        }
        if (call.method == 'getLogs') {
          if (pendingBufferedLogs case final logs?) return logs.future;
        }
        if (call.method == 'showAppNotification') {
          appNotifications.add(
            Map<Object?, Object?>.from(call.arguments as Map),
          );
          if (appNotificationError case final error?) throw error;
          return appNotificationAllowed;
        }
        if (call.method == 'updateConnectionNotification') {
          connectionNotifications.add(
            Map<Object?, Object?>.from(call.arguments['state'] as Map),
          );
          if (pendingConnectionNotification case final ack?) return ack.future;
        }
        if (call.method == 'getNetworkSnapshot') {
          if (networkSnapshotError case final error?) throw error;
          if (pendingNetworkRead case final reply?) return reply.future;
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
          if (!ready && acknowledgeFailedStartup) {
            acknowledgeFailedStartup = false;
            return true;
          }
          return ready;
        }
        if (call.method == 'getDirectProbeNetwork' &&
            pendingDirectGate != null) {
          return pendingDirectGate!.future;
        }
        return switch (call.method) {
          'getVPNStatus' => nativeStatusMissing ? null : nativeStatus,
          'getManualDisconnectRequested' => nativeManualStopRequested,
          'getNetworkSnapshot' => networkSnapshot,
          'getLogs' => bufferedNativeLogs.toList(),
          'getConfig' => restoredNativeConfig,
          'saveConfig' => configSaved,
          'startVPN' => !rejectNativeStart,
          'getKillSwitchState' =>
            scriptedProtectionReads.isEmpty
                ? killSwitch
                : scriptedProtectionReads.removeAt(0),
          'getSmartRouteApps' => {
            'supported': true,
            'protectionKnown': true,
            'protected': killSwitch['strictRuntime'] == true,
            'candidates': [
              if (!smartRouteAppsUnavailable)
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
    bool seedProfile = true,
    int bootstrapFrames = 12,
    List<VpnProfile> extraProfiles = const [],
    Size viewport = const Size(360, 800),
    VpnProfile? initialProfile,
    Map<String, Object> preferences = const {},
    AppUpdateService? updateService,
    ProfileImporter? profileImporter,
    ProfileStore? profileStore,
    ProfileGeoService? profileGeoService,
    String? initialNativeStatus,
    bool useTestStatusClock = false,
    bool useTestReconnectClock = false,
    DateTime Function()? vpnHealthNow,
    DateTime Function()? subscriptionRefreshNow,
    bool tvMode = false,
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
      if (seedProfile) 'selectedProfileId': profile.id,
      ...preferences,
    });
    FlutterSecureStorage.setMockInitialValues({
      'profiles.v1': jsonEncode(
        [
          if (seedProfile) profile,
          ...extraProfiles,
        ].map((item) => item.toJson()).toList(),
      ),
    });
    nativeStatus = initialNativeStatus ?? (connected ? 'Started' : 'Stopped');
    tester.view.physicalSize = viewport * 3;
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 10));
    });
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final app =
        updateService == null &&
            profileImporter == null &&
            profileStore == null &&
            profileGeoService == null &&
            !useTestStatusClock &&
            !useTestReconnectClock &&
            vpnHealthNow == null &&
            subscriptionRefreshNow == null
        ? YurichConnectApp(tvMode: tvMode)
        : MaterialApp(
            theme: YurichTheme.dark(),
            home: HomeScreen(
              tvMode: tvMode,
              updateService: updateService,
              profileImporter: profileImporter,
              profileStore: profileStore,
              profileGeoService: profileGeoService,
              vpnStatusNow: useTestStatusClock
                  ? tester.binding.clock.now
                  : null,
              vpnHealthNow: vpnHealthNow,
              subscriptionRefreshNow: subscriptionRefreshNow,
              vpnReconnectStopwatch: useTestReconnectClock
                  ? tester.binding.clock.stopwatch
                  : Stopwatch.new,
            ),
          );
    await tester.pumpWidget(
      capture && captureDir != null
          ? RepaintBoundary(key: captureKey, child: app)
          : app,
    );
    for (var i = 0; i < bootstrapFrames; i++) {
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

  Future<void> refreshSubscriptionsFromServerList(WidgetTester tester) async {
    await tester.tap(find.byKey(serverPickerKey));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('mobile-server-list-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Обновить подписки'));
    await tester.pump();
  }

  Color powerSurface(WidgetTester tester) {
    final element = tester.element(find.byKey(powerKey));
    return element.findAncestorWidgetOfExactType<Material>()!.color!;
  }

  Future<void> chooseServer(WidgetTester tester, VpnProfile profile) async {
    await tester.tap(find.byKey(serverPickerKey));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('mobile-server-${profile.id}')));
    await tester.pump();
  }

  Future<void> pickMobileServerAction(WidgetTester tester, String label) async {
    await tester.tap(find.byKey(const ValueKey('mobile-server-list-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(label));
    await tester.pumpAndSettle();
  }

  Future<void> pickProfileAction(
    WidgetTester tester,
    VpnProfile profile,
    String label,
  ) async {
    final row = find.byKey(ValueKey('mobile-server-${profile.id}'));
    await tester.ensureVisible(row);
    await tester.tap(
      find.descendant(
        of: row,
        matching: find.byWidgetPredicate((widget) => widget is PopupMenuButton),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text(label));
    await tester.pump();
  }

  List<Uri> interceptExternalLinks({bool opened = true}) {
    const launcher = MethodChannel('plugins.flutter.io/url_launcher');
    final messenger = binding.defaultBinaryMessenger;
    final urls = <Uri>[];
    messenger.setMockMethodCallHandler(launcher, (call) async {
      expect(call.method, 'launch');
      urls.add(Uri.parse(call.arguments['url'] as String));
      return opened;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(launcher, null));
    return urls;
  }

  List<String> interceptClipboardWrites() {
    final messenger = binding.defaultBinaryMessenger;
    final clipboard = <String>[];
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        clipboard.add(call.arguments['text'] as String);
      }
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );
    return clipboard;
  }

  Future<void> tapSettingsItem(WidgetTester tester, Finder finder) async {
    final scroll = find.byKey(const PageStorageKey('mobile-settings-scroll'));
    final control = finder.hitTestable();
    for (var step = 0; step < 20 && control.evaluate().isEmpty; step++) {
      final above =
          finder.evaluate().length == 1 &&
          tester.getCenter(finder).dy < tester.getTopLeft(scroll).dy;
      await tester.drag(scroll, Offset(0, above ? 140 : -140));
      await tester.pumpAndSettle();
    }
    expect(control, findsOneWidget);
    await tester.tap(control);
    await tester.pumpAndSettle();
  }

  Future<void> openSupportReport(WidgetTester tester) async {
    await tester.tap(find.byKey(settingsKey));
    await tester.pumpAndSettle();
    final scroll = find.byKey(const PageStorageKey('mobile-settings-scroll'));
    Future<void> tapInSettings(String label) async {
      final target = find.text(label).hitTestable();
      for (var step = 0; step < 12 && target.evaluate().isEmpty; step++) {
        await tester.drag(scroll, const Offset(0, -140));
        await tester.pumpAndSettle();
      }
      expect(target, findsOneWidget);
      await tester.tap(target);
      await tester.pump();
    }

    await tapInSettings('Приложение и поддержка');
    await tester.pumpAndSettle();
    await tapInSettings('Разработчику');
  }

  Future<VpnProfile> xhttpFixture() async =>
      (await ProfileImporter().importFromText(
        'vless://11111111-1111-4111-8111-111111111111@127.0.0.1:2443'
        '?security=tls&type=xhttp&sni=fixture.invalid&path=%2Fqa#XHTTPFixture',
      )).single.copyWith(countryCode: 'SE');

  Future<Finder> openUpdatePanel(
    WidgetTester tester, {
    String actionLabel = 'Проверить и установить',
  }) async {
    await tester.tap(find.byKey(settingsKey));
    await tester.pumpAndSettle();
    final scroll = find.byKey(const PageStorageKey('mobile-settings-scroll'));
    Future<void> reveal(Finder target) async {
      for (
        var step = 0;
        step < 14 && target.hitTestable().evaluate().isEmpty;
        step++
      ) {
        await tester.drag(scroll, const Offset(0, -140));
        await tester.pumpAndSettle();
      }
      expect(target.hitTestable(), findsOneWidget);
    }

    final support = find.text('Приложение и поддержка');
    await reveal(support);
    await tester.tap(support);
    await tester.pumpAndSettle();
    final updates = find.text('Обновления');
    await reveal(updates);
    await tester.tap(updates);
    await tester.pumpAndSettle();
    final action = find.ancestor(
      of: find.text(actionLabel),
      matching: find.byWidgetPredicate((widget) => widget is FilledButton),
    );
    await reveal(action);
    return action;
  }

  Future<void> pumpUntilNativeCall(WidgetTester tester, String method) async {
    for (var i = 0; i < 16 && !nativeCalls.contains(method); i++) {
      await tester.pump(const Duration(milliseconds: 250));
    }
    expect(nativeCalls, contains(method));
  }

  Future<Map<String, dynamic>> soakCommand(
    String command, {
    String? token,
    String requestId = 'fixture.request',
    String method = 'execute',
  }) async {
    const codec = StandardMethodCodec();
    final reply = Completer<ByteData?>();
    await binding.defaultBinaryMessenger.handlePlatformMessage(
      soakChannel.name,
      codec.encodeMethodCall(
        MethodCall(method, {
          'command': command,
          'requestId': requestId,
          'profileToken': ?token,
        }),
      ),
      reply.complete,
    );
    final payload = codec.decodeEnvelope((await reply.future)!);
    return jsonDecode(payload as String) as Map<String, dynamic>;
  }

  Map<String, Object> physicalSnapshot(
    String type,
    String key, {
    bool confirmed = true,
  }) => {
    'type': type,
    'validated': true,
    'probePhysicalNetwork': key,
    'autoPhysicalRouteConfirmed': confirmed,
    'autoValidatedPhysicalKeys': [key],
  };

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

  for (final editApplications in [false, true]) {
    testWidgets(
      'Smart Route cannot restart an unsupported restored profile (apps=$editApplications)',
      (tester) async {
        final profile = autoFixture('legacy-grpc', 1443, 'PL').copyWith(
          kind: VpnProfileKind.vlessReality,
          outbound: {
            'type': 'vless',
            'transport': {'type': 'grpc'},
          },
        );
        killSwitch = {'known': true, 'runtimeKnown': true};
        await launchWithProfile(
          tester,
          connected: false,
          initialNativeStatus: 'Started',
          initialProfile: profile,
          viewport: const Size(380, 1200),
          preferences: {'smartRouteRuDirect': editApplications},
        );
        // Configuration reconciliation also refuses the unsupported engine.
        expect(nativeCalls, isNot(contains('getConfig')));
        expect(getVpnMutations(), isEmpty);
        expect(find.byKey(activeServerKey), findsOneWidget);
        if (editApplications) {
          await openSmartRouteAppSelection(tester);
          nativeCalls.clear();
          await tester.tap(find.text('Сохранить и переподключить'));
        } else {
          await tester.tap(find.byKey(settingsKey));
          await tester.pumpAndSettle();
          nativeCalls.clear();
          await tester.tap(find.byKey(smartRouteKey));
        }
        await tester.pumpAndSettle();
        expect(getVpnMutations(), isEmpty);
        expect(smartRouteSelections, isEmpty);
        expect(nativeStatus, 'Started');
        expect(await ProfileStore().loadSelectedProfileId(), profile.id);
        expect(
          (await ProfileStore().loadProfiles()).single.outbound,
          profile.outbound,
        );
        final drafts = interceptExternalLinks();
        await openSupportReport(tester);
        await tester.pumpAndSettle();
        expect(
          drafts.single.queryParameters['body'],
          contains('требует Xray/libXray'),
        );
        expect(getVpnMutations(), isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }

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

  testWidgets(
    'Smart Route app choices are saved without reconnecting if lockdown appears in the queued check',
    (tester) async {
      const open = {'known': true, 'runtimeKnown': true};
      killSwitch = {...open};
      await launchWithProfile(
        tester,
        initialProfile: autoFixture('smart-route-lockdown-race', 1443, 'PL'),
        preferences: const {'smartRouteRuDirect': true},
        waitForStopGuard: false,
      );
      await openSmartRouteAppSelection(tester);
      nativeCalls.clear();
      scriptedProtectionReads.add(open);
      killSwitch = {
        ...open,
        'alwaysOn': true,
        'lockdown': true,
        'strictRuntime': true,
      };
      await tester.tap(find.text('Сохранить и переподключить'));
      await tester.pumpAndSettle();
      expect(
        nativeCalls,
        containsAllInOrder([
          'getKillSwitchState',
          'getKillSwitchState',
          'saveSmartRouteApps',
        ]),
      );
      expect(scriptedProtectionReads, isEmpty);
      expect(getVpnMutations(), ['saveSmartRouteApps']);
      expect(smartRouteSelections, [
        ['test.example.fixture'],
      ]);
      expect(nativeConfigs, isEmpty);
      expect(nativeStatus, 'Started');
      expect(tester.takeException(), isNull);
    },
  );

  for (final changeApps in [false, true]) {
    testWidgets(
      'Smart Route keeps both settings and active profile after a stop timeout (apps=$changeApps)',
      (tester) async {
        killSwitch = {'known': true, 'runtimeKnown': true};
        final profile = autoFixture('smart-route-stop-timeout', 1443, 'PL');
        await launchWithProfile(
          tester,
          initialProfile: profile,
          preferences: const {'smartRouteRuDirect': true},
          waitForStopGuard: false,
          useTestStatusClock: true,
        );
        if (changeApps) {
          await openSmartRouteAppSelection(tester);
        } else {
          await tester.tap(find.byKey(settingsKey));
          await tester.pumpAndSettle();
        }
        final stop = pendingStopAck = Completer<bool>();
        final prefs = await SharedPreferences.getInstance();
        nativeCalls.clear();
        await tester.tap(
          changeApps
              ? find.text('Сохранить и переподключить')
              : find.byKey(smartRouteKey),
        );
        await pumpUntilNativeCall(tester, 'stopVPN');
        nativeStatus = 'Stopping';
        pendingStopAck = null;
        stop.complete(true);
        await tester.pump();
        await tester.pump(const Duration(seconds: 36));
        await tester.pumpAndSettle();
        expect(prefs.getBool('smartRouteRuDirect'), isTrue);
        expect(prefs.getString('selectedProfileId'), profile.id);
        expect(smartRouteSelections, isEmpty);
        expect(nativeConfigs, isEmpty);
        expect(nativeCalls, isNot(contains('clearSmartRouteAppBinding')));
        expect(getVpnMutations(), ['stopVPN']);

        nativeStatus = 'Stopped';
        platform.status.add({'status': 'Stopped'});
        await tester.pump(const Duration(seconds: 2));
        expect(getVpnMutations(), ['stopVPN']);
        expect(prefs.getBool('smartRouteRuDirect'), isTrue);
        expect(tester.takeException(), isNull);
      },
    );
  }

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

  testWidgets('Auto rotates after a start ACK followed by stable Stopped', (
    tester,
  ) async {
    scriptedStarts.addAll([false, true]);
    acknowledgeFailedStartup = true;
    await launchWithProfile(
      tester,
      connected: false,
      initialProfile: autoFixture('a', 1443, 'NL'),
      extraProfiles: [autoFixture('b', 2443, 'PL')],
      preferences: {
        'automaticProfileSelection': true,
        'directLatencyAllowed': false,
      },
    );
    nativeCalls.clear();
    nativeConfigs.clear();
    await pressAndConsent(tester);
    await pumpUntilNativeCall(tester, 'startVPN');
    await tester.pump(const Duration(milliseconds: 300));
    expect(getVpnMutations(), ['saveConfig', 'startVPN']);
    for (var i = 0; i < 16 && nativeConfigs.length < 2; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }
    await tester.pumpAndSettle();
    expect(getVpnMutations(), [
      'saveConfig',
      'startVPN',
      'stopVPN',
      'saveConfig',
      'startVPN',
    ]);
    expect(nativeConfigs.last, contains('"server_port":2443'));
    expect(find.byKey(activeServerKey), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 10));
  });

  testWidgets(
    'Auto exhausts unavailable candidates without retrying the list or selecting one',
    (tester) async {
      final first = autoFixture('a', 1443, 'PL');
      final second = autoFixture('b', 2443, 'SE');
      networkSnapshot = physicalSnapshot('cellular', '201');
      scriptedStarts.addAll([false, false]);
      await launchWithProfile(
        tester,
        connected: false,
        initialProfile: first,
        extraProfiles: [second],
        preferences: const {
          'automaticProfileSelection': true,
          'directLatencyAllowed': false,
        },
      );
      nativeCalls.clear();
      await pressAndConsent(tester);
      final failed = find.textContaining(
        'Не удалось подключиться автоматически',
      );
      for (var i = 0; i < 30 && failed.evaluate().isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 250));
      }
      expect(failed, findsWidgets);
      await tester.pump(const Duration(seconds: 5));
      expect(getVpnMutations(), [
        'saveConfig',
        'startVPN',
        'stopVPN',
        'saveConfig',
        'startVPN',
        'stopVPN',
      ]);
      expect(find.byKey(activeServerKey), findsNothing);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('selectedProfileId'), first.id);
      final stats =
          jsonDecode(prefs.getString('profileNetworkStabilityStats')!) as Map;
      for (final id in [first.id, second.id]) {
        expect(stats[id]['cellular']['healthFailures'], 1);
        expect(
          stats[id]['cellular']['lastFailureReason'],
          'auto-attempt-unavailable',
        );
        expect(stats[id]['wifi'], isNull);
      }
    },
  );

  testWidgets(
    'Auto does not conclude that a server failed on an ambiguous network',
    (tester) async {
      final first = autoFixture('a', 1443, 'PL');
      final second = autoFixture('b', 2443, 'SE');
      networkSnapshot = physicalSnapshot('wifi', '201', confirmed: false);
      scriptedStarts.addAll([false, true]);
      await launchWithProfile(
        tester,
        connected: false,
        initialProfile: first,
        extraProfiles: [second],
        preferences: const {
          'automaticProfileSelection': true,
          'directLatencyAllowed': false,
        },
      );
      nativeCalls.clear();
      await pressAndConsent(tester);
      for (
        var i = 0;
        i < 30 && find.byKey(activeServerKey).evaluate().isEmpty;
        i++
      ) {
        await tester.pump(const Duration(milliseconds: 250));
      }
      expect(find.byKey(activeServerKey), findsOneWidget);
      expect(getVpnMutations(), [
        'saveConfig',
        'startVPN',
        'stopVPN',
        'saveConfig',
        'startVPN',
      ]);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('selectedProfileId'), second.id);
      final stats =
          jsonDecode(prefs.getString('profileNetworkStabilityStats')!) as Map;
      expect(stats[first.id], isNull);
      expect(stats[second.id]['wifi']['successfulStarts'], 1);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 10));
    },
  );

  for (final errorCode in ['VPN_PERMISSION_DENIED', 'NATIVE_FIXTURE_FAILURE']) {
    testWidgets('Auto does not rotate on native command error $errorCode', (
      tester,
    ) async {
      final first = autoFixture('a', 1443, 'PL');
      startCommandError = PlatformException(code: errorCode);
      await launchWithProfile(
        tester,
        connected: false,
        initialProfile: first,
        extraProfiles: [autoFixture('b', 2443, 'SE')],
        preferences: const {
          'automaticProfileSelection': true,
          'directLatencyAllowed': false,
        },
      );
      nativeCalls.clear();
      await pressAndConsent(tester);
      await pumpUntilNativeCall(tester, 'startVPN');
      await tester.pump(const Duration(milliseconds: 750));
      await tester.pumpAndSettle();
      expect(getVpnMutations(), [
        'saveConfig',
        'startVPN',
        if (errorCode != 'VPN_PERMISSION_DENIED') 'stopVPN',
      ]);
      expect(find.byKey(activeServerKey), findsNothing);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('selectedProfileId'), first.id);
      expect(prefs.getString('profileNetworkStabilityStats'), isNull);
    });
  }

  for (final (code, cause, message) in [
    (
      'START_VPN_ERROR',
      'x509: certificate expired',
      'Server TLS verification failed.',
    ),
    (
      'START_VPN_ERROR',
      'name resolution failed',
      'The server address could not be resolved.',
    ),
    (
      'START_VPN_ERROR',
      'connection refused',
      'The server did not complete the connection.',
    ),
    (
      'VPN_PERMISSION_DENIED',
      'VPN permission denied',
      'Android did not grant VPN access.',
    ),
    (
      'START_VPN_ERROR',
      'invalid outbound config',
      'The VPN profile configuration was not accepted.',
    ),
  ]) {
    testWidgets('Auto shows a safe categorized error: $cause', (tester) async {
      const privateFixture = 'fixture-secret-for-test';
      final drafts = interceptExternalLinks();
      final selected = autoFixture('selected', 1443, 'PL');
      startCommandError = PlatformException(
        code: code,
        message: '$cause; Bearer $privateFixture',
      );
      await launchWithProfile(
        tester,
        connected: false,
        initialProfile: selected,
        extraProfiles: [autoFixture('alternate', 2443, 'SE')],
        preferences: const {
          'languageCode': 'en',
          'vpnDisclosureVersion': 1,
          'automaticProfileSelection': true,
          'directLatencyAllowed': false,
        },
      );
      nativeCalls.clear();
      await tester.tap(find.byKey(powerKey));
      await pumpUntilNativeCall(tester, 'startVPN');
      await tester.pump(const Duration(milliseconds: 750));
      await tester.pumpAndSettle();
      expect(find.text(message), findsWidgets);
      expect(find.textContaining(privateFixture), findsNothing);
      expect(find.byKey(activeServerKey), findsNothing);
      expect(drafts, isEmpty);
      expect(getVpnMutations(), [
        'saveConfig',
        'startVPN',
        if (code != 'VPN_PERMISSION_DENIED') 'stopVPN',
      ]);
      expect(nativeCalls, isNot(contains('getDirectProbeNetwork')));
      expect(await ProfileStore().loadSelectedProfileId(), selected.id);

      if (cause.startsWith('x509:')) {
        await tester.tap(find.byKey(settingsKey));
        await tester.pumpAndSettle();
        await tapSettingsItem(tester, find.byTooltip('Report'));
        final draft = drafts.single;
        expect(draft.scheme, 'mailto');
        expect(
          draft.queryParameters['body'],
          contains('category=tls_certificate'),
        );
        expect(draft.queryParameters['body'], isNot(contains(privateFixture)));
      }
      expect(tester.takeException(), isNull);
    });
  }

  for (final (from, to) in [('wifi', 'cellular'), ('cellular', 'wifi')]) {
    testWidgets(
      'Auto re-evaluates the same profile when $from → $to happens during failed startup cleanup',
      (tester) async {
        final first = autoFixture('a', 1443, 'PL');
        final second = autoFixture('b', 2443, 'SE');
        final stopAck = Completer<bool>();
        networkSnapshot = physicalSnapshot(from, '101');
        pendingStopAck = stopAck;
        scriptedStarts.addAll([false, true]);
        await launchWithProfile(
          tester,
          connected: false,
          initialProfile: first,
          extraProfiles: [second],
          preferences: const {
            'automaticProfileSelection': true,
            'directLatencyAllowed': false,
          },
        );
        nativeCalls.clear();
        await pressAndConsent(tester);
        await pumpUntilNativeCall(tester, 'stopVPN');
        expect(getVpnMutations(), ['saveConfig', 'startVPN', 'stopVPN']);
        networkSnapshot = physicalSnapshot(to, '202');
        nativeStatus = 'Stopped';
        stopAck.complete(true);
        pendingStopAck = null;
        for (
          var i = 0;
          i < 30 && find.byKey(activeServerKey).evaluate().isEmpty;
          i++
        ) {
          await tester.pump(const Duration(milliseconds: 250));
        }
        expect(find.byKey(activeServerKey), findsOneWidget);
        expect(getVpnMutations(), [
          'saveConfig',
          'startVPN',
          'stopVPN',
          'saveConfig',
          'startVPN',
        ]);
        expect(nativeConfigs, hasLength(2));
        expect(nativeConfigs, everyElement(contains('"server_port":1443')));
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getString('selectedProfileId'), first.id);
        final stats =
            jsonDecode(prefs.getString('profileNetworkStabilityStats')!) as Map;
        expect(stats[first.id][from], isNull);
        expect(stats[first.id][to]['successfulStarts'], 1);
        expect(stats[first.id][to]['healthFailures'], 0);
        expect(stats[second.id], isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(seconds: 10));
      },
    );

    testWidgets(
      'Auto handover $from → $to tries another profile under lockdown',
      (tester) async {
        final first = autoFixture('a', 1443, 'NL');
        final second = autoFixture('b', 2443, 'PL');
        killSwitch = {
          'known': true,
          'alwaysOn': true,
          'lockdown': true,
          'requested': true,
          'strictRuntime': true,
          'vpnActive': true,
        };
        await launchWithProfile(
          tester,
          initialProfile: first,
          extraProfiles: [second],
          preferences: {
            'automaticProfileSelection': true,
            'directLatencyAllowed': true,
          },
        );
        platform.status.add({
          'status': 'Started',
          'manualDisconnectRequested': false,
          'readyPhysicalPath': '$from:101',
        });
        await tester.pump();
        nativeStatus = 'Starting';
        // Android can return its Wi-Fi hint when the VPN masks the default.
        // Native has already confirmed the move to validated cellular in this case.
        final ambiguous = to == 'cellular';
        networkSnapshot = {
          'type': ambiguous ? from : to,
          'validated': true,
          'probePhysicalNetwork': ambiguous ? '101' : '202',
          'autoPhysicalRouteConfirmed': !ambiguous,
          if (ambiguous) 'autoValidatedPhysicalKeys': ['101', '202'],
        };
        nativeCalls.clear();
        nativeConfigs.clear();
        scriptedStarts.add(true);
        pendingStopAck = Completer<bool>();
        for (var i = 0; i < 2; i++) {
          platform.status.add({
            'status': 'Starting',
            'manualDisconnectRequested': false,
            'desiredRunning': true,
            'sessionReason': 'network-rebind',
            'failedReadinessPath': '$to:202',
          });
        }
        await pumpUntilNativeCall(tester, 'stopVPN');
        expect(getVpnMutations(), ['stopVPN']);
        nativeStatus = 'Stopped';
        pendingStopAck!.complete(true);
        for (var i = 0; i < 25 && !nativeCalls.contains('startVPN'); i++) {
          await tester.pump(const Duration(milliseconds: 250));
        }
        await tester.pumpAndSettle();
        expect(getVpnMutations(), ['stopVPN', 'saveConfig', 'startVPN']);
        expect(nativeConfigs.single, contains('"server_port":2443'));
        expect(nativeCalls, isNot(contains('getDirectProbeNetwork')));
        expect(nativeCalls, isNot(contains('setKillSwitchRequested')));
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(seconds: 10));
      },
    );
  }

  for (final stopTimesOut in [false, true]) {
    testWidgets(
      'Auto fences a second network drop during locked-down handover (stopTimeout=$stopTimesOut)',
      (tester) async {
        final original = autoFixture('original-handover', 1443, 'PL');
        final fallback = autoFixture('fallback-handover', 2443, 'SE');
        const lockdown = {
          'known': true,
          'runtimeKnown': true,
          'alwaysOn': true,
          'lockdown': true,
          'requested': true,
          'strictRuntime': true,
          'vpnActive': true,
        };
        killSwitch = {...lockdown};
        networkSnapshot = physicalSnapshot('wifi', '101');
        await launchWithProfile(
          tester,
          initialProfile: original,
          extraProfiles: [fallback],
          waitForStopGuard: false,
          useTestStatusClock: true,
          useTestReconnectClock: true,
          preferences: const {
            'automaticProfileSelection': true,
            'directLatencyAllowed': false,
            'vpnDisclosureVersion': 1,
          },
        );
        platform.status.add({
          'status': 'Started',
          'manualDisconnectRequested': false,
          'readyPhysicalPath': 'wifi:101',
        });
        await tester.pump();
        nativeCalls.clear();

        final firstStop = pendingStopAck = Completer<bool>();
        final fallbackStart = pendingStartAck = Completer<bool>();
        nativeStatus = 'Starting';
        networkSnapshot = physicalSnapshot('cellular', '202');
        platform.status.add({
          'status': 'Starting',
          'manualDisconnectRequested': false,
          'desiredRunning': true,
          'sessionReason': 'network-rebind',
          'failedReadinessPath': 'cellular:202',
        });
        await pumpUntilNativeCall(tester, 'stopVPN');
        expect(getVpnMutations(), ['stopVPN']);
        nativeStatus = 'Stopped';
        pendingStopAck = null;
        firstStop.complete(true);
        await pumpUntilNativeCall(tester, 'startVPN');
        expect(getVpnMutations(), ['stopVPN', 'saveConfig', 'startVPN']);
        expect(nativeConfigs.single, contains('"server_port":2443'));

        // Lose cellular while the fallback command is still awaiting its
        // native reply. Its late acceptance cannot commit that candidate.
        networkSnapshot = const {'type': 'none', 'validated': false};
        nativeStatus = 'Starting';
        final secondStop = pendingStopAck = Completer<bool>();
        pendingStartAck = null;
        fallbackStart.complete(true);
        for (
          var frame = 0;
          frame < 16 && getVpnMutations().length < 4;
          frame++
        ) {
          await tester.pump(const Duration(milliseconds: 250));
        }
        const cleanup = ['stopVPN', 'saveConfig', 'startVPN', 'stopVPN'];
        expect(getVpnMutations(), cleanup);
        expect(find.byKey(activeServerKey), findsNothing);
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getString('selectedProfileId'), original.id);

        nativeStatus = 'Stopping';
        pendingStopAck = null;
        secondStop.complete(true);
        networkSnapshot = physicalSnapshot('wifi', '303');
        scriptedStarts.add(true);
        platform.status.add({
          'status': 'Started',
          'manualDisconnectRequested': false,
          'readyPhysicalPath': 'cellular:202',
        });
        await tester.pump(const Duration(milliseconds: 750));
        expect(getVpnMutations(), cleanup);
        expect(find.byKey(activeServerKey), findsNothing);
        expect(nativeConfigs, hasLength(1));

        if (stopTimesOut) {
          await tester.pump(const Duration(seconds: 36));
          await tester.pump();
          expect(
            find.textContaining('VPN не успел полностью остановиться'),
            findsWidgets,
          );
          // Late cleanup must not restart an already failed handover.
          nativeStatus = 'Stopped';
          platform.status.add({'status': 'Stopped'});
          await tester.pump(const Duration(seconds: 2));
          expect(getVpnMutations(), cleanup);
          expect(nativeConfigs, hasLength(1));
          expect(scriptedStarts, [true]);
          expect(prefs.getString('selectedProfileId'), original.id);
          expect(find.byKey(activeServerKey), findsNothing);
          expect(
            await ProfileStore().loadProfileNetworkStabilityStats(),
            isEmpty,
          );
        } else {
          nativeStatus = 'Stopped';
          for (var frame = 0; frame < 12; frame++) {
            await tester.pump(const Duration(milliseconds: 250));
          }
          expect(getVpnMutations(), [...cleanup, 'saveConfig', 'startVPN']);
          expect(nativeConfigs, hasLength(2));
          expect(nativeConfigs, everyElement(contains('"server_port":2443')));
          expect(prefs.getString('selectedProfileId'), fallback.id);
          expect(find.byKey(activeServerKey), findsOneWidget);
          final stats = await ProfileStore().loadProfileNetworkStabilityStats();
          expect(stats[original.id], isNull);
          expect(stats[fallback.id]?['cellular'], isNull);
          expect(stats[fallback.id]?['wifi']?.successfulStarts, 1);
          expect(stats[fallback.id]?['wifi']?.healthFailures, 0);
        }
        expect(killSwitch, lockdown);
        expect(nativeCalls, isNot(contains('getDirectProbeNetwork')));
        expect(nativeCalls, isNot(contains('setKillSwitchRequested')));
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(seconds: 2));
      },
    );
  }

  for (final guard in [
    'unknown protection',
    'missing proof',
    'mismatched path',
    'recovered',
    'no usable alternative',
    'partial protection',
    'destination lost before stop',
    'snapshot read failed',
  ]) {
    testWidgets('Auto handover refuses to replace a profile: $guard', (
      tester,
    ) async {
      killSwitch = guard == 'unknown protection'
          ? {'known': false, 'requested': true}
          : guard == 'partial protection'
          ? {'known': true, 'alwaysOn': true, 'lockdown': false}
          : {'known': true};
      await launchWithProfile(
        tester,
        initialProfile: autoFixture('a', 1443, 'NL'),
        extraProfiles: [
          if (guard == 'no usable alternative')
            offlineProfile
          else
            autoFixture('b', 2443, 'PL'),
        ],
        preferences: {'automaticProfileSelection': true},
      );
      platform.status.add({
        'status': 'Started',
        'manualDisconnectRequested': false,
        'readyPhysicalPath': 'wifi:101',
      });
      await tester.pump();
      nativeCalls.clear();
      nativeStatus = guard == 'recovered' ? 'Started' : 'Starting';
      networkSnapshot = {
        'type': 'cellular',
        'validated': true,
        'probePhysicalNetwork': guard == 'mismatched path' ? '303' : '202',
        'autoPhysicalRouteConfirmed': true,
      };
      if (guard == 'destination lost before stop') {
        networkOnNextStatusRead = physicalSnapshot('wifi', '101');
      }
      if (guard == 'snapshot read failed') {
        networkSnapshotError = PlatformException(
          code: 'NETWORK_SNAPSHOT_FIXTURE_FAILURE',
        );
      }
      platform.status.add({
        'status': 'Starting',
        'manualDisconnectRequested': false,
        'desiredRunning': true,
        'sessionReason': 'network-rebind',
        if (guard != 'missing proof') 'failedReadinessPath': 'cellular:202',
      });
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
      expect(getVpnMutations(), isEmpty);
      if (guard == 'snapshot read failed') {
        expect(nativeCalls, contains('getNetworkSnapshot'));
        expect(nativeCalls, isNot(contains('stopVPN')));
        networkSnapshotError = null;
        // No decision was committed on the failed read. A new native proof can
        // be evaluated normally and only go ahead after the stop is confirmed.
        final stopAck = Completer<bool>();
        pendingStopAck = stopAck;
        scriptedStarts.add(true);
        nativeCalls.clear();
        platform.status.add({
          'status': 'Starting',
          'manualDisconnectRequested': false,
          'desiredRunning': true,
          'sessionReason': 'network-rebind',
          'failedReadinessPath': 'cellular:202',
        });
        await pumpUntilNativeCall(tester, 'stopVPN');
        expect(getVpnMutations(), ['stopVPN']);
        nativeStatus = 'Stopped';
        stopAck.complete(true);
        pendingStopAck = null;
        await pumpUntilNativeCall(tester, 'startVPN');
        await tester.pumpAndSettle();
        expect(getVpnMutations(), ['stopVPN', 'saveConfig', 'startVPN']);
        expect(nativeConfigs.single, contains('"server_port":2443'));
      }
      if (guard == 'destination lost before stop') {
        expect(networkOnNextStatusRead, isNull);
        expect(
          nativeCalls,
          containsAllInOrder([
            'getNetworkSnapshot',
            'getVPNStatus',
            'getNetworkSnapshot',
          ]),
        );
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 10));
    });
  }

  testWidgets('Auto cannot dispatch a start when every candidate is unusable', (
    tester,
  ) async {
    final expired = autoFixture(
      'expired',
      1443,
      'PL',
    ).copyWith(subscriptionExpiresAt: DateTime.utc(2000));
    await launchWithProfile(
      tester,
      connected: false,
      initialProfile: expired,
      extraProfiles: [offlineProfile],
      preferences: const {
        'automaticProfileSelection': true,
        'directLatencyAllowed': false,
      },
    );
    nativeCalls.clear();
    await pressAndConsent(tester);
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Для автовыбора нет подходящего сервера'),
      findsWidgets,
    );
    expect(find.byKey(activeServerKey), findsNothing);
    expect(getVpnMutations(), isEmpty);
    expect(nativeCalls, isNot(contains('getDirectProbeNetwork')));
  });

  for (final initiallyRunning in [false, true]) {
    testWidgets(
      'unsupported profile never dispatches a start or interrupts a tunnel (running=$initiallyRunning)',
      (tester) async {
        final original = autoFixture('reliable', 1443, 'PL');
        final unsupported = original.copyWith(
          id: 'unsupported',
          name: 'Reality gRPC fixture',
          kind: VpnProfileKind.vlessReality,
          outbound: {
            'type': 'vless',
            'transport': {'type': 'grpc'},
          },
        );
        await launchWithProfile(
          tester,
          connected: initiallyRunning,
          initialProfile: original,
          extraProfiles: [unsupported],
          waitForStopGuard: false,
        );
        nativeCalls.clear();
        await chooseServer(tester, unsupported);
        await tester.pumpAndSettle();
        final prefs = await SharedPreferences.getInstance();
        expect(find.textContaining('требует Xray/libXray'), findsWidgets);
        expect(
          prefs.getString('selectedProfileId'),
          initiallyRunning ? original.id : unsupported.id,
        );
        if (initiallyRunning) {
          expect(find.byKey(activeServerKey), findsOneWidget);
          expect(nativeStatus, 'Started');
        } else {
          await pressAndConsent(tester);
          await tester.pumpAndSettle();
          expect(find.byKey(activeServerKey), findsNothing);
          expect(powerSurface(tester), YurichMobileColors.powerError);
        }
        expect(getVpnMutations(), isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('legacy raw profile is not exposed as a connectable profile', (
    tester,
  ) async {
    const profile = VpnProfile(
      id: 'blocked-raw',
      name: 'Unsupported raw profile',
      kind: VpnProfileKind.singBoxConfig,
      originalInput: '{"outbounds":[]}',
      rawConfig: '{"outbounds":[]}',
    );
    await launchWithProfile(
      tester,
      connected: false,
      initialProfile: profile,
      preferences: const {'languageCode': 'en', 'vpnDisclosureVersion': 1},
    );
    nativeCalls.clear();
    expect(
      find.byKey(const ValueKey('mobile-empty-add-subscription')),
      findsOneWidget,
    );
    expect(find.text(profile.name), findsNothing);
    await tester.tap(find.byKey(powerKey));
    await tester.pumpAndSettle();
    expect(find.byKey(activeServerKey), findsNothing);
    expect(getVpnMutations(), isEmpty);
    expect(tester.takeException(), isNull);
  });

  for (final ackTimesOut in [false, true]) {
    testWidgets(
      'manual XHTTP fences a failed native start and records a safe error (timeout=$ackTimesOut)',
      (tester) async {
        final profile = await xhttpFixture();
        final startAck = Completer<bool>();
        if (ackTimesOut) {
          pendingStartAck = startAck;
        } else {
          startCommandError = PlatformException(
            code: 'START_VPN_ERROR',
            message: 'TLS handshake failed: Bearer fixture-private-value',
          );
        }
        await launchWithProfile(
          tester,
          connected: false,
          initialProfile: profile,
        );
        nativeCalls.clear();
        await pressAndConsent(tester);
        await pumpUntilNativeCall(tester, 'startVPN');
        if (ackTimesOut) {
          expect(getVpnMutations(), ['saveConfig', 'startVPN']);
          expect(find.byTooltip('Отменить подключение'), findsOneWidget);
          await tester.pump(const Duration(seconds: 9));
        }
        await pumpUntilNativeCall(tester, 'stopVPN');
        await tester.pump(const Duration(milliseconds: 450));
        await tester.pumpAndSettle();
        if (ackTimesOut) {
          startAck.complete(true);
          pendingStartAck = null;
          await tester.pump();
        }
        expect(getVpnMutations(), ['saveConfig', 'startVPN', 'stopVPN']);
        expect(find.byKey(activeServerKey), findsNothing);
        expect(powerSurface(tester), YurichMobileColors.powerError);
        expect(find.text('Нет стабильного соединения'), findsOneWidget);
        expect(find.textContaining('fixture-private-value'), findsNothing);
        final stats = (await ProfileStore()
            .loadProfileStabilityStats())[profile.id]!;
        expect(stats.failedStarts, 1);
        expect(stats.lastFailureReason, contains('VPN не стартовал'));
        expect(
          stats.lastFailureReason,
          isNot(contains('fixture-private-value')),
        );

        // A terminal failure must not leave a stuck startup command behind.
        startCommandError = null;
        scriptedStarts.add(true);
        nativeCalls.clear();
        await tester.tap(find.byKey(powerKey));
        await pumpUntilNativeCall(tester, 'startVPN');
        await tester.pump(const Duration(milliseconds: 450));
        await tester.pumpAndSettle();
        expect(getVpnMutations(), ['saveConfig', 'startVPN']);
        expect(find.byKey(activeServerKey), findsOneWidget);
        expect(find.text('Нет стабильного соединения'), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(seconds: 10));
      },
    );
  }

  for (final acknowledged in [true, false]) {
    testWidgets(
      'Auto startup timeout distinguishes readiness from dispatch (ack=$acknowledged)',
      (tester) async {
        final first = autoFixture('first-timeout', 1443, 'PL');
        final next = autoFixture('next-timeout', 2443, 'SE');
        await launchWithProfile(
          tester,
          connected: false,
          initialProfile: first,
          extraProfiles: [next],
          useTestStatusClock: true,
          preferences: const {
            'automaticProfileSelection': true,
            'directLatencyAllowed': false,
            'vpnDisclosureVersion': 1,
          },
        );
        nativeCalls.clear();
        final startAck = pendingStartAck = Completer<bool>();
        final stopAck = pendingStopAck = Completer<bool>();
        final prefs = await SharedPreferences.getInstance();
        await tester.tap(find.byKey(powerKey));
        await pumpUntilNativeCall(tester, 'startVPN');
        expect(nativeConfigs.single, contains('"server_port":1443'));

        if (acknowledged) {
          nativeStatus = 'Starting';
          pendingStartAck = null;
          startAck.complete(true);
          await tester.pump();
        }
        // The alternative allows a 14 s Naive readiness window; a missing
        // response to the start command is limited to 7 s instead.
        await tester.pump(Duration(seconds: acknowledged ? 13 : 6));
        expect(getVpnMutations(), ['saveConfig', 'startVPN']);
        expect(find.byTooltip('Отменить подключение'), findsOneWidget);
        await tester.pump(const Duration(seconds: 2));
        await pumpUntilNativeCall(tester, 'stopVPN');
        expect(getVpnMutations(), ['saveConfig', 'startVPN', 'stopVPN']);
        expect(nativeConfigs, hasLength(1));

        nativeStatus = 'Stopping';
        pendingStopAck = null;
        stopAck.complete(true);
        if (!acknowledged) {
          pendingStartAck = null;
          startAck.complete(true);
          platform.status.add({'status': 'Started'});
        }
        await tester.pump(const Duration(milliseconds: 600));
        expect(nativeConfigs, hasLength(1));
        expect(getVpnMutations(), ['saveConfig', 'startVPN', 'stopVPN']);
        expect(find.byKey(activeServerKey), findsNothing);
        expect(prefs.getString('selectedProfileId'), first.id);

        nativeStatus = 'Stopped';
        scriptedStarts.add(true);
        for (var frame = 0; frame < 12; frame++) {
          await tester.pump(const Duration(milliseconds: 250));
        }
        await tester.pumpAndSettle();
        final stats = await ProfileStore().loadProfileNetworkStabilityStats();
        if (acknowledged) {
          expect(getVpnMutations(), [
            'saveConfig',
            'startVPN',
            'stopVPN',
            'saveConfig',
            'startVPN',
          ]);
          expect(nativeConfigs, hasLength(2));
          expect(nativeConfigs.last, contains('"server_port":2443'));
          expect(prefs.getString('selectedProfileId'), next.id);
          expect(find.byKey(activeServerKey), findsOneWidget);
          expect(stats[first.id]?['wifi']?.healthFailures, 1);
          expect(
            stats[first.id]?['wifi']?.lastFailureReason,
            'auto-attempt-unavailable',
          );
          expect(stats[next.id]?['wifi']?.successfulStarts, 1);
        } else {
          expect(getVpnMutations(), ['saveConfig', 'startVPN', 'stopVPN']);
          expect(nativeConfigs, hasLength(1));
          expect(scriptedStarts, [true]);
          expect(stats, isEmpty);
          expect(prefs.getString('selectedProfileId'), first.id);
          expect(find.byKey(activeServerKey), findsNothing);
          expect(powerSurface(tester), YurichMobileColors.powerError);
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'a config acknowledgement timeout cannot start a core after a late reply',
    (tester) async {
      final first = await xhttpFixture();
      final next = autoFixture('after-config-timeout', 1443, 'PL');
      await launchWithProfile(
        tester,
        connected: false,
        initialProfile: first,
        extraProfiles: [next],
        preferences: const {'vpnDisclosureVersion': 1},
      );
      nativeCalls.clear();
      final ack = pendingConfigAck = Completer<bool>();
      await tester.tap(find.byKey(powerKey));
      await pumpUntilNativeCall(tester, 'saveConfig');
      await tester.pump(const Duration(seconds: 9));
      expect(getVpnMutations(), ['saveConfig']);
      expect(find.byTooltip('Отменить подключение'), findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();

      final stats = await ProfileStore().loadProfileStabilityStats();
      expect(stats[first.id]?.failedStarts, 1);
      expect(
        stats[first.id]?.lastFailureReason,
        contains('timeout [saveConfig]'),
      );
      expect(find.byKey(activeServerKey), findsNothing);
      expect(powerSurface(tester), YurichMobileColors.powerError);
      pendingConfigAck = null;
      ack.complete(true);
      await tester.pump();
      expect(getVpnMutations(), ['saveConfig']);

      await chooseServer(tester, next);
      await tester.pumpAndSettle();
      scriptedStarts.add(true);
      await tester.tap(find.byKey(powerKey));
      await pumpUntilNativeCall(tester, 'startVPN');
      await tester.pump(const Duration(milliseconds: 650));
      await tester.pumpAndSettle();
      expect(getVpnMutations(), ['saveConfig', 'saveConfig', 'startVPN']);
      expect(nativeConfigs.last, contains('"server_port":1443'));
      expect(
        (await SharedPreferences.getInstance()).getString('selectedProfileId'),
        next.id,
      );
      expect(find.byKey(activeServerKey), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 2));
    },
  );

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

  testWidgets('Auto starts on confirmed cellular before Android validates it', (
    tester,
  ) async {
    networkSnapshot = const {
      'type': 'cellular',
      'validated': false,
      'probePhysicalNetwork': '202',
      'autoPhysicalRouteConfirmed': true,
      'autoValidatedPhysicalKeys': <String>[],
    };
    await launchWithProfile(
      tester,
      connected: false,
      initialProfile: autoFixture('cellular-start', 2443, 'PL'),
      preferences: const {
        'automaticProfileSelection': true,
        'directLatencyAllowed': false,
        'vpnDisclosureVersion': 1,
      },
    );
    scriptedStarts.add(true);
    nativeCalls.clear();

    await tester.tap(find.byKey(powerKey));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(getVpnMutations(), isEmpty);

    await pumpUntilNativeCall(tester, 'startVPN');
    await tester.pump(const Duration(seconds: 2));
    expect(getVpnMutations(), ['saveConfig', 'startVPN']);
    expect(find.byKey(activeServerKey), findsOneWidget);
    expect(nativeCalls, isNot(contains('getDirectProbeNetwork')));
    expect(tester.takeException(), isNull);
  });

  testWidgets('Auto keeps the same LTE route when VPN hides its default', (
    tester,
  ) async {
    const cellular = {
      'type': 'cellular',
      'validated': false,
      'probePhysicalNetwork': '202',
      'autoPhysicalRouteConfirmed': true,
      'autoValidatedPhysicalKeys': <String>[],
    };
    networkSnapshot = cellular;
    final startAck = pendingStartAck = Completer<bool>();
    await launchWithProfile(
      tester,
      connected: false,
      initialProfile: autoFixture('cellular-tun-binding', 2443, 'PL'),
      preferences: const {
        'automaticProfileSelection': true,
        'directLatencyAllowed': false,
        'vpnDisclosureVersion': 1,
      },
    );
    nativeCalls.clear();
    await tester.tap(find.byKey(powerKey));
    await pumpUntilNativeCall(tester, 'startVPN');

    networkSnapshot = {...cellular, 'autoPhysicalRouteConfirmed': false};
    nativeStatus = 'Started';
    pendingStartAck = null;
    startAck.complete(true);
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));

    expect(getVpnMutations(), ['saveConfig', 'startVPN']);
    expect(find.byKey(activeServerKey), findsOneWidget);
    expect(nativeCalls, isNot(contains('getDirectProbeNetwork')));
    expect(tester.takeException(), isNull);
  });

  testWidgets('Auto does not start from an unconfirmed cellular hint', (
    tester,
  ) async {
    networkSnapshot = const {
      'type': 'cellular',
      'validated': false,
      'probePhysicalNetwork': '202',
      'autoPhysicalRouteConfirmed': false,
      'autoValidatedPhysicalKeys': <String>[],
    };
    await launchWithProfile(
      tester,
      connected: false,
      initialProfile: autoFixture('cellular-hint', 2443, 'PL'),
      preferences: const {
        'automaticProfileSelection': true,
        'directLatencyAllowed': false,
        'vpnDisclosureVersion': 1,
      },
    );
    nativeCalls.clear();

    await tester.tap(find.byKey(powerKey));
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('Жду интернет…'), findsWidgets);
    expect(getVpnMutations(), isEmpty);
    expect(nativeCalls, isNot(contains('getDirectProbeNetwork')));

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 2));
    expect(tester.takeException(), isNull);
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

  for (final mode in [
    'saved stop',
    'no saved stop',
    'late initial status',
    'native intent with a rejected stop request',
  ]) {
    testWidgets(
      'early Android Started is reconciled as soon as startup settings load ($mode)',
      (tester) async {
        final fromNative = mode == 'native intent with a rejected stop request';
        final shouldStop = mode != 'no saved stop';
        final settings = Completer<AppDistributionChannel>();
        final updater = _TestHomeUpdater()..distributionGate = settings.future;
        final staleStatus = mode == 'late initial status'
            ? Completer<String>()
            : null;
        pendingVpnStatusRead = staleStatus;
        final stop = pendingStopAck = Completer<bool>();
        manualDisconnectReadError = PlatformException(code: 'INTENT_FIXTURE');
        final profile = autoFixture('early-started', 1443, 'PL');
        await launchWithProfile(
          tester,
          connected: false,
          initialNativeStatus: 'Started',
          initialProfile: profile,
          updateService: updater,
          bootstrapFrames: 4,
          preferences: {'manualDisconnectRequested': shouldStop && !fromNative},
        );
        expect(nativeCalls, contains('getVPNStatus'));
        expect(getVpnMutations(), isEmpty);
        pendingVpnStatusRead = null;
        platform.status.add({'status': 'Started'});
        await tester.pump();
        expect(getVpnMutations(), isEmpty);
        if (fromNative) {
          manualDisconnectReadError = null;
          nativeManualStopRequested = true;
        }
        updater.distributionGate = null;
        settings.complete(AppDistributionChannel.github);
        await tester.pump();

        final store = ProfileStore();
        if (shouldStop) {
          // No second event, and do not wait for the boot status read to time out.
          for (
            var frame = 0;
            frame < 6 && !nativeCalls.contains('stopVPN');
            frame++
          ) {
            await tester.pump(const Duration(milliseconds: 50));
          }
          expect(getVpnMutations(), ['stopVPN']);
          expect(await store.loadManualDisconnectRequested(), isTrue);

          // A duplicate readiness event during the stop must not queue another.
          platform.status.add({'status': 'Started'});
          await tester.pump();
          expect(getVpnMutations(), ['stopVPN']);
          pendingStopAck = null;
          if (fromNative) {
            // A bridge failure isn't a successful stop, and must not erase
            // the authoritative Android intent or trigger an unhandled error.
            stop.completeError(PlatformException(code: 'DISPATCH_REJECTED'));
            await tester.pumpAndSettle();
            expect(await store.loadManualDisconnectRequested(), isTrue);
            expect(nativeStatus, 'Started');
          } else {
            nativeStatus = 'Stopped';
            stop.complete(true);
            await tester.pump(const Duration(milliseconds: 550));
            await tester.pumpAndSettle();
            expect(find.byKey(activeServerKey), findsNothing);
            expect(find.byTooltip('Подключить VPN'), findsOneWidget);
          }

          if (staleStatus != null) {
            final reads = nativeCalls
                .where((call) => call == 'getVPNStatus')
                .length;
            staleStatus.complete('Started');
            await tester.pump();
            await tester.pumpAndSettle();
            expect(
              nativeCalls.where((call) => call == 'getVPNStatus'),
              hasLength(reads),
            );
            expect(find.byKey(activeServerKey), findsNothing);
          }
          expect(getVpnMutations(), ['stopVPN']);
        } else {
          await tester.pumpAndSettle();
          expect(await store.loadManualDisconnectRequested(), isFalse);
          expect(find.byKey(activeServerKey), findsOneWidget);
          expect(getVpnMutations(), isEmpty);
          pendingStopAck = null;
        }
        expect((await store.loadProfiles()).single.id, profile.id);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(seconds: 2));
      },
    );
  }

  testWidgets(
    'native startup stop intent is enforced before the profile list finishes loading',
    (tester) async {
      final settings = Completer<AppDistributionChannel>();
      final updater = _TestHomeUpdater()..distributionGate = settings.future;
      final stop = pendingStopAck = Completer<bool>();
      nativeManualStopRequested = true;
      await launchWithProfile(
        tester,
        connected: false,
        initialNativeStatus: 'Started',
        updateService: updater,
        bootstrapFrames: 4,
        preferences: const {'manualDisconnectRequested': false},
      );
      expect(settings.isCompleted, isFalse);
      expect(getVpnMutations(), ['stopVPN']);
      final store = ProfileStore();
      expect(await store.loadManualDisconnectRequested(), isTrue);
      updater.distributionGate = null;
      settings.complete(AppDistributionChannel.github);
      await tester.pump();
      expect(getVpnMutations(), ['stopVPN']);
      nativeStatus = 'Stopped';
      pendingStopAck = null;
      stop.complete(true);
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      expect(find.byKey(activeServerKey), findsNothing);
      expect(getVpnMutations(), ['stopVPN']);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a newer Android start cannot be stopped by a stale startup intent reply',
    (tester) async {
      final intentRead = pendingManualDisconnectRead = Completer<bool>();
      await launchWithProfile(
        tester,
        connected: false,
        initialNativeStatus: 'Started',
        initialProfile: autoFixture('fresh-native-intent', 1443, 'PL'),
        bootstrapFrames: 4,
        preferences: const {'manualDisconnectRequested': true},
      );
      expect(
        nativeCalls.where((call) => call == 'getManualDisconnectRequested'),
        hasLength(2),
      );
      await emitConnected(tester);
      final store = ProfileStore();
      expect(await store.loadManualDisconnectRequested(), isFalse);
      pendingManualDisconnectRead = null;
      intentRead.complete(true);
      await tester.pumpAndSettle();
      expect(await store.loadManualDisconnectRequested(), isFalse);
      expect(find.byKey(activeServerKey), findsOneWidget);
      expect(getVpnMutations(), isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 2));
    },
  );

  testWidgets(
    'startup honors a stored manual stop when the Android intent read fails',
    (tester) async {
      final drafts = interceptExternalLinks();
      final stop = pendingStopAck = Completer<bool>();
      final logsRead = pendingBufferedLogs = Completer<List<String>>();
      manualDisconnectReadError = PlatformException(
        code: 'STATUS_READ_FIXTURE',
        message: 'Native read failed',
      );
      await launchWithProfile(
        tester,
        connected: false,
        initialNativeStatus: 'Started',
        viewport: const Size(380, 1200),
        preferences: const {'manualDisconnectRequested': true},
      );
      pendingBufferedLogs = null;
      logsRead.complete(const []);
      await pumpUntilNativeCall(tester, 'stopVPN');
      expect(getVpnMutations(), ['stopVPN']);
      expect(await ProfileStore().loadManualDisconnectRequested(), isTrue);

      nativeStatus = 'Stopped';
      pendingStopAck = null;
      stop.complete(true);
      await tester.pump(const Duration(milliseconds: 750));
      await tester.pumpAndSettle();
      expect(find.byKey(activeServerKey), findsNothing);
      expect(getVpnMutations(), ['stopVPN']);
      await openSupportReport(tester);
      await tester.pumpAndSettle();
      final report = drafts.single.queryParameters['body']!;
      expect(nativeCalls, contains('getManualDisconnectRequested'));
      expect(report, contains('status: Stopped'));
      expect(report, contains('manual_disconnect_requested: true'));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'late bootstrap replies cannot replace a newer VPN status or native log snapshot',
    (tester) async {
      final drafts = interceptExternalLinks();
      final statusRead = pendingVpnStatusRead = Completer<String>();
      final logsRead = pendingBufferedLogs = Completer<List<String>>();
      await launchWithProfile(
        tester,
        connected: false,
        viewport: const Size(380, 1200),
      );
      await pumpUntilNativeCall(tester, 'getLogs');
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(nativeCalls, containsAllInOrder(['getVPNStatus', 'getLogs']));
      pendingVpnStatusRead = null;
      pendingBufferedLogs = null;
      nativeStatus = 'Started';
      await emitConnected(tester);
      await tester.pumpAndSettle();
      expect(find.byKey(activeServerKey), findsOneWidget);

      statusRead.complete('Stopped');
      logsRead.complete(const ['fixture-late-bootstrap-log']);
      await tester.pump();
      expect(find.byKey(activeServerKey), findsOneWidget);
      bufferedNativeLogs.add('fixture-current-native-log');
      await openSupportReport(tester);
      await tester.pumpAndSettle();
      final report = drafts.single.queryParameters['body']!;
      expect(report, contains('status: Started'));
      expect(report, contains('fixture-current-native-log'));
      expect(report, isNot(contains('fixture-late-bootstrap-log')));
      expect(getVpnMutations(), isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'corrupt profile storage preserves the saved blob and leaves diagnostics available',
    (tester) async {
      const corrupt = '{"fixture":"not a profile list"}';
      const storage = FlutterSecureStorage();
      final drafts = interceptExternalLinks();
      FlutterSecureStorage.setMockInitialValues({'profiles.v1': corrupt});
      nativeStatus = 'Stopped';
      tester.view.physicalSize = const Size(1140, 3600);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(const YurichConnectApp());
      for (var frame = 0; frame < 12; frame++) {
        await tester.pump(const Duration(milliseconds: 250));
      }
      expect(await storage.read(key: 'profiles.v1'), corrupt);
      expect(getVpnMutations(), isEmpty);
      await openSupportReport(tester);
      await tester.pumpAndSettle();
      final report = drafts.single.queryParameters['body']!;
      expect(report, contains('boot-task-error:load:'));
      expect(report, contains('profiles:\nnone'));
      expect(await storage.read(key: 'profiles.v1'), corrupt);
      expect(getVpnMutations(), isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'startup removes stale stability histories and honors the native manual stop',
    (tester) async {
      final current = autoFixture('stored-live', 1443, 'PL');
      nativeManualStopRequested = true;
      await launchWithProfile(
        tester,
        connected: false,
        initialProfile: current,
        preferences: {
          'manualDisconnectRequested': false,
          'profileStabilityStats': jsonEncode({
            current.id: {'successfulStarts': 2},
            'removed-profile': {'successfulStarts': 40},
          }),
          'profileNetworkStabilityStats': jsonEncode({
            current.id: {
              'wifi': {'successfulStarts': 1, 'trafficBytes': 1024},
            },
            'removed-profile': {
              'cellular': {'successfulStarts': 20},
            },
          }),
        },
      );
      final store = ProfileStore();
      final stability = await store.loadProfileStabilityStats();
      final networks = await store.loadProfileNetworkStabilityStats();
      expect(stability.keys, [current.id]);
      expect(stability[current.id]?.successfulStarts, 2);
      expect(networks.keys, [current.id]);
      expect(networks[current.id]?['wifi']?.successfulStarts, 1);
      expect(networks[current.id]?['wifi']?.trafficBytes, 1024);
      expect(await store.loadManualDisconnectRequested(), isTrue);
      expect(nativeCalls, contains('getManualDisconnectRequested'));
      expect(getVpnMutations(), isEmpty);
      expect(find.byKey(activeServerKey), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

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

  testWidgets(
    'endpoint country lookup fills a missing flag without overriding an explicit location',
    (tester) async {
      final missing = VpnProfile.fromJson({
        ...autoFixture('geo-missing', 1443, 'PL').toJson(),
        'countryCode': null,
      });
      final declared = autoFixture(
        'geo-declared',
        2443,
        'SE',
      ).copyWith(name: '🇵🇱 Fixture declared');
      final geo = _ScriptedHomeGeo(
        endpointResult: const ProfileGeo(countryCode: 'KZ'),
      );
      await launchWithProfile(
        tester,
        connected: false,
        initialProfile: missing,
        extraProfiles: [declared],
        profileGeoService: geo,
      );
      expect(geo.endpointIds, [missing.id]);
      final saved = {
        for (final profile in await ProfileStore().loadProfiles())
          profile.id: profile,
      };
      expect(saved[missing.id]!.countryCode, 'KZ');
      expect(saved[missing.id]!.countryName, 'Казахстан');
      expect(saved[declared.id]!.countryCode, 'SE');
      expect(geo.exitLookups, isEmpty);
      await tester.tap(find.byKey(serverPickerKey));
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byKey(ValueKey('mobile-server-${missing.id}')),
          matching: find.text('🇰🇿'),
        ),
        findsOneWidget,
      );
      expect(getVpnMutations(), isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Auto keeps a pending candidate when a country update replaces only its display metadata',
    (tester) async {
      final profile = VpnProfile.fromJson({
        ...autoFixture('auto-pending-geo', 1443, 'PL').toJson(),
        'countryCode': null,
      });
      final fallback = autoFixture('auto-other-geo', 2443, 'SE');
      final country = Completer<ProfileGeo?>();
      final geo = _ScriptedHomeGeo(endpointGate: country.future);
      await launchWithProfile(
        tester,
        connected: false,
        initialProfile: profile,
        extraProfiles: [fallback],
        profileGeoService: geo,
        preferences: const {
          'automaticProfileSelection': true,
          'directLatencyAllowed': false,
          'vpnDisclosureVersion': 1,
        },
      );
      expect(geo.endpointIds, [profile.id]);
      nativeCalls.clear();
      final route = pendingNetworkRead = Completer<Map<String, Object>>();
      await tester.tap(find.byKey(powerKey));
      await pumpUntilNativeCall(tester, 'getNetworkSnapshot');
      expect(getVpnMutations(), isEmpty);

      country.complete(const ProfileGeo(countryCode: 'KZ'));
      await tester.pump(const Duration(milliseconds: 250));
      final saved = (await ProfileStore().loadProfiles()).first;
      expect(saved.id, profile.id);
      expect(saved.countryCode, 'KZ');
      expect(saved.outbound, profile.outbound);

      pendingNetworkRead = null;
      route.complete(networkSnapshot);
      scriptedStarts.add(true);
      await pumpUntilNativeCall(tester, 'startVPN');
      await tester.pump(const Duration(seconds: 2));
      expect(getVpnMutations(), ['saveConfig', 'startVPN']);
      expect(nativeConfigs.single, contains('"server_port":1443'));
      expect(find.byKey(activeServerKey), findsOneWidget);
      expect(
        (await SharedPreferences.getInstance()).getString('selectedProfileId'),
        profile.id,
      );
      expect(tester.takeException(), isNull);
    },
  );

  for (final sameCountry in [false, true]) {
    testWidgets(
      'exit country metadata cannot disturb a working tunnel (unchanged=$sameCountry)',
      (tester) async {
        final profile = autoFixture(
          'geo-persist-fixture',
          1443,
          'PL',
        ).copyWith(countryName: 'Польша');
        final geo = _ScriptedHomeGeo();
        await launchWithProfile(
          tester,
          connected: false,
          initialProfile: profile,
          profileGeoService: geo,
          preferences: const {'vpnDisclosureVersion': 1},
        );
        final previous = FlutterSecureStoragePlatform.instance;
        final storage = _ProfileWriteFailureStore(
          Map.of(await previous.readAll(options: const {})),
        );
        FlutterSecureStoragePlatform.instance = storage;
        addTearDown(() => FlutterSecureStoragePlatform.instance = previous);
        nativeCalls.clear();
        scriptedStarts.add(true);
        await tester.tap(find.byKey(powerKey));
        await pumpUntilNativeCall(tester, 'startVPN');
        await tester.pump(const Duration(seconds: 2));
        expect(geo.exitLookups, hasLength(1));
        expect(find.byKey(activeServerKey), findsOneWidget);
        geo.exitLookups.single.response.complete(
          ProfileGeo(countryCode: sameCountry ? 'PL' : 'KZ'),
        );
        await tester.pumpAndSettle();

        expect(storage.writeAttempts, sameCountry ? 0 : 1);
        expect(getVpnMutations(), ['saveConfig', 'startVPN']);
        expect(find.byKey(activeServerKey), findsOneWidget);
        expect(find.text('Нет стабильного соединения'), findsNothing);
        final persisted = (await ProfileStore().loadProfiles()).single;
        expect(persisted.countryCode, 'PL');
        expect(persisted.countryName, 'Польша');
        expect(persisted.outbound, profile.outbound);
        expect(await ProfileStore().loadSelectedProfileId(), profile.id);
        expect(
          (await ProfileStore().loadProfileStabilityStats())[profile.id]
              ?.successfulStarts,
          1,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'late exit-country response is cancelled for the previous tunnel',
    (tester) async {
      final first = autoFixture('geo-first', 1443, 'PL');
      final second = autoFixture('geo-second', 2443, 'SE');
      final geo = _ScriptedHomeGeo();
      await launchWithProfile(
        tester,
        connected: false,
        initialProfile: first,
        extraProfiles: [second],
        profileGeoService: geo,
        preferences: const {'vpnDisclosureVersion': 1},
      );
      nativeCalls.clear();
      scriptedStarts.add(true);
      await tester.tap(find.byKey(powerKey));
      await pumpUntilNativeCall(tester, 'startVPN');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(seconds: 2));
      expect(geo.exitLookups, hasLength(1));
      final original = geo.exitLookups.single;
      expect(original.cancellation.isCancelled, isFalse);

      await chooseServer(tester, second);
      await pumpUntilNativeCall(tester, 'reloadVPN');
      await tester.pump(const Duration(seconds: 2));
      expect(original.cancellation.isCancelled, isTrue);
      expect(geo.exitLookups, hasLength(2));
      original.response.complete(const ProfileGeo(countryCode: 'FI'));
      geo.exitLookups.last.response.complete(
        const ProfileGeo(countryCode: 'NL'),
      );
      await tester.pumpAndSettle();
      final saved = {
        for (final profile in await ProfileStore().loadProfiles())
          profile.id: profile,
      };
      expect(saved[first.id]!.countryCode, 'PL');
      expect(saved[second.id]!.countryCode, 'NL');
      expect(saved[second.id]!.countryName, 'Нидерланды');
      expect(
        (await SharedPreferences.getInstance()).getString('selectedProfileId'),
        second.id,
      );
      expect(geo.exitLookups.last.cancellation.isCancelled, isTrue);
      expect(getVpnMutations(), [
        'saveConfig',
        'startVPN',
        'saveConfig',
        'reloadVPN',
      ]);
      expect(find.byKey(activeServerKey), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'server list checks multiple batches strictly through the active VPN',
    (tester) async {
      final active = autoFixture('batch-active', 1443, 'PL');
      final tcpPeers = [
        autoFixture('batch-a', 2443, 'DE'),
        autoFixture('batch-b', 3443, 'SE'),
        autoFixture('batch-c', 4443, 'FI'),
      ];
      final routes = <String?>[];
      final dials = <(Object?, int)>[];
      Future<void> checkServerList() async {
        await launchWithProfile(
          tester,
          initialProfile: active,
          extraProfiles: [...tcpPeers, offlineProfile, udpProfile],
          waitForStopGuard: false,
        );
        await tester.tap(find.byKey(serverPickerKey));
        await tester.pumpAndSettle();
        routes.clear();
        dials.clear();
        nativeCalls.clear();
        final action = find.byKey(checkServersKey);
        expect(tester.widget<IconButton>(action).onPressed, isNotNull);
        await tester.tap(action);
        for (var frame = 0; frame < 8; frame++) {
          await tester.pump(const Duration(milliseconds: 250));
        }
        expect(
          dials,
          List.filled(tcpPeers.length, (
            InternetAddress.loopbackIPv4,
            SingBoxConfigBuilder.localMixedProxyPort,
          )),
        );
        expect(routes, isNotEmpty);
        expect(
          routes,
          everyElement(
            'PROXY 127.0.0.1:${SingBoxConfigBuilder.localMixedProxyPort}',
          ),
        );
        final activeRow = find.byKey(ValueKey('mobile-server-${active.id}'));
        expect(
          find.descendant(
            of: activeRow,
            matching: find.textContaining(RegExp(r'\d+ мс')),
          ),
          findsWidgets,
        );
        expect(
          (await SharedPreferences.getInstance()).getString(
            'selectedProfileId',
          ),
          active.id,
        );
        expect(nativeCalls, isNot(contains('getDirectProbeNetwork')));
        expect(getVpnMutations(), isEmpty);
        expect(tester.takeException(), isNull);
      }

      await HttpOverrides.runZoned(
        () => IOOverrides.runZoned(
          checkServerList,
          socketStartConnect:
              (host, port, {sourceAddress, sourcePort = 0}) async {
                dials.add((host, port));
                throw const SocketException(
                  'Fixture: local proxy rejected this check',
                );
              },
        ),
        createHttpClient: (_) => _IdleHealthClient(true, routes.add),
      );
    },
  );

  for (final (language, menuLabel, refusal) in [
    ('ru', 'Проверить сервер', 'Для проверки нужен работающий VPN.'),
    ('en', 'Check server', 'Connect to a working VPN first.'),
  ]) {
    testWidgets(
      'stale VPN latency actions never become direct checks ($language)',
      (tester) async {
        final fixture = autoFixture('stale-action', 1443, 'PL');
        final profile = fixture.copyWith(
          server: 'fixture.example',
          outbound: {...fixture.outbound!, 'server': 'fixture.example'},
        );
        killSwitch = {'known': true, 'supported': true, 'vpnActive': true};
        pendingDirectGate = Completer<String?>()..complete('test-wifi');
        final proxyRequests = <String?>[];
        final socketDials = <int>[];
        await HttpOverrides.runZoned(
          () => IOOverrides.runZoned(
            () async {
              await launchWithProfile(
                tester,
                initialProfile: profile,
                extraProfiles: [autoFixture('stale-action-peer', 2443, 'SE')],
                waitForStopGuard: false,
                preferences: {
                  'languageCode': language,
                  'directLatencyAllowed': true,
                },
              );
              await tester.tap(find.byKey(serverPickerKey));
              await tester.pumpAndSettle();
              final action = find.byKey(checkServersKey);
              final checkWithVpn = tester.widget<IconButton>(action).onPressed!;
              final row = find.byKey(ValueKey('mobile-server-${profile.id}'));
              await tester.tap(
                find.descendant(
                  of: row,
                  matching: find.byWidgetPredicate(
                    (widget) => widget is PopupMenuButton,
                  ),
                ),
              );
              await tester.pumpAndSettle();
              expect(find.text(menuLabel), findsOneWidget);

              nativeStatus = 'Stopped';
              nativeManualStopRequested = true;
              killSwitch['vpnActive'] = false;
              platform.status.add({
                'status': nativeStatus,
                'manualDisconnectRequested': true,
                'type': 'wifi',
                'generation': 0,
              });
              await tester.pumpAndSettle();
              final checkDirect = tester.widget<IconButton>(action).onPressed;
              expect(checkDirect, isNotNull); // Direct checks are now allowed.
              nativeCalls.clear();
              proxyRequests.clear();
              socketDials.clear();

              // The open menu and the old toolbar callback both meant VPN.
              await tester.tap(find.text(menuLabel));
              await tester.pumpAndSettle();
              checkWithVpn();
              await tester.pumpAndSettle();
              expect(find.text(refusal), findsOneWidget);
              expect(nativeCalls, isNot(contains('getDirectProbeNetwork')));
              expect(getVpnMutations(), isEmpty);
              expect(proxyRequests, isEmpty);
              expect(socketDials, isEmpty);

              // A direct tap captured while stopped must also fail closed
              // when a VPN starts. The new VPN probe itself is not a tap.
              nativeStatus = 'Started';
              nativeManualStopRequested = false;
              killSwitch['vpnActive'] = true;
              await emitConnected(tester);
              await tester.pumpAndSettle();
              nativeCalls.clear();
              proxyRequests.clear();
              socketDials.clear();
              checkDirect!();
              await tester.pumpAndSettle();
              expect(nativeCalls, isNot(contains('getDirectProbeNetwork')));
              expect(getVpnMutations(), isEmpty);
              expect(proxyRequests, isEmpty);
              expect(socketDials, isEmpty);

              await tester.pumpWidget(const SizedBox.shrink());
              checkWithVpn();
              await tester.pump();
              expect(tester.takeException(), isNull);
            },
            socketStartConnect:
                (host, port, {sourceAddress, sourcePort = 0}) async {
                  socketDials.add(port);
                  throw const SocketException('Fixture: no socket access');
                },
          ),
          createHttpClient: (_) => _IdleHealthClient(true, proxyRequests.add),
        );
      },
    );
  }

  testWidgets('single server check stays tunneled when location is unknown', (
    tester,
  ) async {
    final profile = autoFixture('unlocated', 1443, '');
    final routes = <String?>[];
    await HttpOverrides.runZoned(() async {
      await launchWithProfile(
        tester,
        initialProfile: profile,
        waitForStopGuard: false,
        preferences: const {'directLatencyAllowed': true},
      );
      final badge = find.byKey(activeServerKey);
      expect(
        find.descendant(of: badge, matching: find.text('Локация неизвестна')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: badge, matching: find.text('🌐')),
        findsOneWidget,
      );

      await tester.tap(badge);
      await tester.pumpAndSettle();
      nativeCalls.clear();
      routes.clear();
      await pickProfileAction(tester, profile, 'Проверить сервер');
      await tester.pumpAndSettle();
      expect(routes, isNotEmpty);
      expect(
        routes,
        everyElement(
          'PROXY 127.0.0.1:${SingBoxConfigBuilder.localMixedProxyPort}',
        ),
      );
      expect(nativeCalls, isNot(contains('getDirectProbeNetwork')));
      expect(getVpnMutations(), isEmpty);
      expect(await ProfileStore().loadSelectedProfileId(), profile.id);
      expect(tester.takeException(), isNull);
    }, createHttpClient: (_) => _IdleHealthClient(true, routes.add));
  });

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

  for (final scenario in ['before deadline', 'past deadline', 'local pilot']) {
    final pilot = scenario == 'local pilot';
    final tooLate = scenario == 'past deadline';
    testWidgets(
      'Auto waits for a confirmed network return near its deadline ($scenario)',
      (tester) async {
        final wifi = autoFixture('preferred-wifi', 1443, 'PL');
        final cellular = autoFixture('preferred-cellular', 2443, 'SE');
        final diagnosticCalls = <String>[];
        if (pilot) {
          binding.defaultBinaryMessenger.setMockMethodCallHandler(
            incidentChannel,
            (call) async {
              diagnosticCalls.add(call.method);
              return {
                'enabled': true,
                'epoch': 'fixture-network-return-consent',
                'queued': 0,
              };
            },
          );
        }
        networkSnapshot = physicalSnapshot('wifi', '101');
        await launchWithProfile(
          tester,
          connected: false,
          initialProfile: wifi,
          extraProfiles: [cellular],
          useTestStatusClock: true,
          useTestReconnectClock: true,
          preferences: {
            'automaticProfileSelection': true,
            'directLatencyAllowed': false,
            'vpnDisclosureVersion': 1,
            'profileNetworkStabilityStats': jsonEncode({
              wifi.id: {
                'wifi': {'successfulStarts': 4},
              },
              cellular.id: {
                'cellular': {'successfulStarts': 3},
              },
            }),
          },
        );
        networkSnapshot = const {'type': 'none', 'validated': false};
        await tester.tap(find.byKey(powerKey));
        await tester.pump();
        await tester.pump(const Duration(seconds: 178));
        expect(find.text('Жду интернет…'), findsWidgets);
        expect(getVpnMutations(), isEmpty);

        // Release the first validated snapshot at 179 s (or 179.75 s). Auto
        // must wait another 350 ms for the same physical route to confirm it.
        final reply = pendingNetworkRead = Completer<Map<String, Object>>();
        nativeCalls.clear();
        await tester.pump(const Duration(seconds: 1));
        expect(nativeCalls, ['getNetworkSnapshot']);
        if (tooLate) await tester.pump(const Duration(milliseconds: 750));
        networkSnapshot = physicalSnapshot('cellular', '202');
        pendingNetworkRead = null;
        reply.complete(networkSnapshot);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(getVpnMutations(), isEmpty);
        scriptedStarts.add(true);
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pumpAndSettle();

        final prefs = await SharedPreferences.getInstance();
        final stats = await ProfileStore().loadProfileNetworkStabilityStats();
        if (tooLate) {
          expect(getVpnMutations(), isEmpty);
          expect(nativeConfigs, isEmpty);
          expect(scriptedStarts, [true]);
          expect(prefs.getString('selectedProfileId'), wifi.id);
          expect(stats[cellular.id]?['cellular']?.successfulStarts, 3);
          expect(find.byKey(activeServerKey), findsNothing);
          expect(
            find.textContaining('Не удалось подключиться автоматически'),
            findsWidgets,
          );
        } else {
          expect(getVpnMutations(), ['saveConfig', 'startVPN']);
          expect(nativeConfigs.single, contains('"server_port":2443'));
          expect(prefs.getString('selectedProfileId'), cellular.id);
          expect(stats[cellular.id]?['cellular']?.successfulStarts, 4);
          expect(stats[cellular.id]?['cellular']?.healthFailures, 0);
          expect(find.byKey(activeServerKey), findsOneWidget);
        }
        expect(stats[wifi.id]?['wifi']?.successfulStarts, 4);
        expect(nativeCalls, isNot(contains('getDirectProbeNetwork')));
        if (pilot) {
          expect(diagnosticCalls, contains('state'));
          expect(diagnosticCalls, isNot(contains('record')));
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(seconds: 2));
      },
      skip: pilot && !LocalConnectionIncidentsService.pilotBuild,
    );
  }

  testWidgets(
    'Auto closes its overall waiting budget without trying a late network',
    (tester) async {
      final profile = autoFixture('auto-budget', 1443, 'PL');
      await launchWithProfile(
        tester,
        connected: false,
        initialProfile: profile,
        useTestStatusClock: true,
        useTestReconnectClock: true,
        preferences: const {
          'automaticProfileSelection': true,
          'directLatencyAllowed': false,
          'vpnDisclosureVersion': 1,
        },
      );
      final readyNetwork = networkSnapshot;
      networkSnapshot = const {'type': 'none', 'validated': false};
      nativeCalls.clear();

      await tester.tap(find.byKey(powerKey));
      await tester.pump();
      await tester.pump(const Duration(seconds: 179));
      expect(find.text('Жду интернет…'), findsWidgets);
      expect(find.byTooltip('Отменить подключение'), findsOneWidget);
      expect(getVpnMutations(), isEmpty);

      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      expect(
        find.text(
          'Нет интернета. Проверьте сеть и попробуйте подключиться снова.',
        ),
        findsWidgets,
      );
      expect(find.byTooltip('Подключить VPN'), findsOneWidget);
      expect(
        (await ProfileStore().loadProfileNetworkStabilityStats()),
        isEmpty,
      );
      expect(getVpnMutations(), isEmpty);

      networkSnapshot = readyNetwork;
      await tester.pump(const Duration(seconds: 2));
      expect(getVpnMutations(), isEmpty);
      expect(find.byKey(activeServerKey), findsNothing);

      scriptedStarts.add(true);
      await tester.tap(find.byKey(powerKey));
      await pumpUntilNativeCall(tester, 'startVPN');
      await tester.pump(const Duration(seconds: 2));
      expect(getVpnMutations(), ['saveConfig', 'startVPN']);
      expect(find.byKey(activeServerKey), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Stop cancels a hung Auto start and ignores a late Started event during cleanup',
    (tester) async {
      final first = autoFixture('a', 1443, 'PL');
      final second = autoFixture('b', 2443, 'SE');
      final startAck = Completer<bool>();
      final stopAck = Completer<bool>();
      pendingStartAck = startAck;
      pendingStopAck = stopAck;
      await launchWithProfile(
        tester,
        connected: false,
        initialProfile: first,
        extraProfiles: [second],
        preferences: const {
          'automaticProfileSelection': true,
          'directLatencyAllowed': false,
        },
      );
      nativeCalls.clear();
      await pressAndConsent(tester);
      await pumpUntilNativeCall(tester, 'startVPN');
      expect(find.byTooltip('Отменить подключение'), findsOneWidget);
      await tester.tap(find.byKey(powerKey));
      await tester.pump();
      expect(find.byTooltip('Отменить подключение'), findsNothing);
      expect(find.byKey(activeServerKey), findsNothing);
      // Native mutations stay serialized even though the generation is cancelled.
      expect(getVpnMutations(), ['saveConfig', 'startVPN']);

      nativeStatus = 'Stopping';
      await tester.pump(const Duration(seconds: 8));
      await tester.pump();
      expect(getVpnMutations(), ['saveConfig', 'startVPN', 'stopVPN']);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('manualDisconnectRequested'), isTrue);
      startAck.complete(true);
      pendingStartAck = null;
      platform.status.add({
        'status': 'Started',
        'manualDisconnectRequested': false,
        'readyPhysicalPath': 'wifi:101',
      });
      await tester.pump();
      expect(find.byKey(activeServerKey), findsNothing);

      // The stop call also has a timeout. A fresh Stopped read can confirm cleanup
      // even when the acknowledgement never arrived.
      nativeStatus = 'Stopped';
      await tester.pump(const Duration(seconds: 6));
      await tester.pump(const Duration(milliseconds: 450));
      await tester.pumpAndSettle();
      stopAck.complete(true);
      pendingStopAck = null;
      await tester.pump();
      expect(getVpnMutations(), ['saveConfig', 'startVPN', 'stopVPN']);
      expect(prefs.getBool('manualDisconnectRequested'), isTrue);
      expect(prefs.getString('selectedProfileId'), first.id);
      expect(find.byTooltip('Подключить VPN'), findsOneWidget);
      expect(find.byKey(activeServerKey), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Auto waits after a network snapshot timeout and starts on the confirmed route',
    (tester) async {
      final wifi = autoFixture('snapshot-wifi', 1443, 'PL');
      final cellular = autoFixture('snapshot-cellular', 2443, 'SE');
      await launchWithProfile(
        tester,
        connected: false,
        initialProfile: wifi,
        extraProfiles: [cellular],
        useTestStatusClock: true,
        useTestReconnectClock: true,
        preferences: {
          'automaticProfileSelection': true,
          'directLatencyAllowed': false,
          'vpnDisclosureVersion': 1,
          'profileNetworkStabilityStats': jsonEncode({
            cellular.id: {
              'cellular': {'successfulStarts': 4},
            },
          }),
        },
      );
      final stale = pendingNetworkRead = Completer<Map<String, Object>>();
      nativeCalls.clear();
      await tester.tap(find.byKey(powerKey));
      await pumpUntilNativeCall(tester, 'getNetworkSnapshot');

      await tester.pump(const Duration(seconds: 3));
      expect(find.text('Жду интернет…'), findsWidgets);
      expect(getVpnMutations(), isEmpty);
      expect(nativeConfigs, isEmpty);

      pendingNetworkRead = null;
      networkSnapshot = physicalSnapshot('cellular', '202');
      scriptedStarts.add(true);
      await pumpUntilNativeCall(tester, 'startVPN');
      stale.complete(physicalSnapshot('wifi', '101'));
      await tester.pumpAndSettle();

      expect(getVpnMutations(), ['saveConfig', 'startVPN']);
      expect(nativeConfigs.single, contains('"server_port":2443'));
      expect(find.byKey(activeServerKey), findsOneWidget);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('selectedProfileId'), cellular.id);
      expect(nativeCalls, isNot(contains('getDirectProbeNetwork')));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 2));
    },
  );

  testWidgets(
    'cancelling Auto during a network snapshot never starts a late connection',
    (tester) async {
      final selected = autoFixture('cancel-snapshot', 1443, 'PL');
      await launchWithProfile(
        tester,
        connected: false,
        initialProfile: selected,
        preferences: const {
          'automaticProfileSelection': true,
          'directLatencyAllowed': false,
          'vpnDisclosureVersion': 1,
        },
      );
      final read = pendingNetworkRead = Completer<Map<String, Object>>();
      nativeCalls.clear();
      await tester.tap(find.byKey(powerKey));
      await pumpUntilNativeCall(tester, 'getNetworkSnapshot');
      expect(find.byTooltip('Отменить подключение'), findsOneWidget);
      expect(getVpnMutations(), isEmpty);

      await tester.tap(find.byKey(powerKey));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Подключить VPN'), findsOneWidget);
      expect(getVpnMutations(), ['stopVPN']);
      pendingNetworkRead = null;
      read.complete(physicalSnapshot('cellular', '202'));
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();

      expect(getVpnMutations(), ['stopVPN']);
      expect(nativeConfigs, isEmpty);
      expect(find.byTooltip('Подключить VPN'), findsOneWidget);
      expect(find.byKey(activeServerKey), findsNothing);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('selectedProfileId'), selected.id);
      expect(nativeCalls, isNot(contains('getDirectProbeNetwork')));
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
    'Auto explains when its only server is explicitly marked offline',
    (tester) async {
      await launchWithProfile(
        tester,
        connected: false,
        initialProfile: offlineProfile,
        preferences: const {
          'automaticProfileSelection': true,
          'directLatencyAllowed': false,
          'vpnDisclosureVersion': 1,
        },
      );
      nativeCalls.clear();
      await tester.tap(find.byKey(powerKey));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('Для автовыбора нет подходящего сервера.'),
        findsWidgets,
      );
      expect(getVpnMutations(), isEmpty);
      expect(nativeCalls, isNot(contains('getDirectProbeNetwork')));
      expect(find.byKey(activeServerKey), findsNothing);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('selectedProfileId'), offlineProfile.id);
      expect(tester.takeException(), isNull);
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

  for (final scenario in [
    'cross-engine switch',
    'Auto fallback',
    'manual stop',
  ]) {
    testWidgets(
      'hanging Stopping never allows a new profile to start ($scenario)',
      (tester) async {
        final current = autoFixture('original', 1443, 'PL');
        final next = await xhttpFixture();
        final automatic = scenario == 'Auto fallback';
        final manualStop = scenario == 'manual stop';
        await launchWithProfile(
          tester,
          initialProfile: current,
          extraProfiles: [next],
          connected: !automatic,
          waitForStopGuard: false,
          useTestStatusClock: true,
          preferences: {
            'automaticProfileSelection': automatic,
            'directLatencyAllowed': false,
            'vpnDisclosureVersion': 1,
          },
        );
        final stopAck = Completer<bool>();
        pendingStopAck = stopAck;
        if (automatic) scriptedStarts.add(false);
        nativeCalls.clear();
        if (automatic || manualStop) {
          await tester.tap(find.byKey(powerKey));
          await tester.pump();
        } else {
          await chooseServer(tester, next);
        }
        await pumpUntilNativeCall(tester, 'stopVPN');
        final expectedMutations = [
          if (automatic) ...['saveConfig', 'startVPN'],
          'stopVPN',
        ];
        expect(getVpnMutations(), expectedMutations);
        final expectedConfigs = automatic ? 1 : 0;
        expect(nativeConfigs, hasLength(expectedConfigs));

        // The command succeeded, but the service never said it released the TUN.
        nativeStatus = 'Stopping';
        stopAck.complete(true);
        pendingStopAck = null;
        await tester.pump();
        await tester.pump(const Duration(seconds: 34));
        const timeoutNotice = 'VPN не успел полностью остановиться';
        expect(find.textContaining(timeoutNotice), findsNothing);
        expect(getVpnMutations(), expectedMutations);
        expect(find.byKey(activeServerKey), findsNothing);

        await tester.pump(const Duration(seconds: 2));
        await tester.pump();
        expect(find.textContaining(timeoutNotice), findsWidgets);
        expect(nativeConfigs, hasLength(expectedConfigs));
        expect(getVpnMutations(), expectedMutations);
        expect(find.byKey(activeServerKey), findsNothing);
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getString('selectedProfileId'), current.id);
        if (manualStop) {
          // Changing the selection while disconnected is allowed, but it does
          // not turn a completed stop command into a new connect command.
          await chooseServer(tester, next);
          await tester.pumpAndSettle();
          expect(prefs.getString('selectedProfileId'), next.id);
          expect(getVpnMutations(), expectedMutations);
        }

        nativeStatus = 'Stopped';
        platform.status.add({
          'status': 'Stopped',
          'manualDisconnectRequested': manualStop,
        });
        await tester.pump();
        await tester.pump(const Duration(seconds: 2));
        await tester.pumpAndSettle();
        expect(getVpnMutations(), expectedMutations);
        expect(nativeConfigs, hasLength(expectedConfigs));
        expect(find.byKey(activeServerKey), findsNothing);

        if (scenario == 'cross-engine switch') {
          scriptedStarts.add(true);
          await tester.tap(find.byKey(powerKey));
          await pumpUntilNativeCall(tester, 'startVPN');
          await tester.pump(const Duration(milliseconds: 600));
          await tester.pumpAndSettle();
          expect(getVpnMutations(), ['stopVPN', 'saveConfig', 'startVPN']);
          expect(nativeConfigs.single, contains('"port":2443'));
          expect(prefs.getString('selectedProfileId'), next.id);
          expect(find.byKey(activeServerKey), findsOneWidget);
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(seconds: 10));
      },
    );
  }

  testWidgets(
    'a manual choice overrides Auto and only the last queued profile can start',
    (tester) async {
      final original = autoFixture('running-in-auto', 1443, 'PL');
      final firstChoice = await xhttpFixture();
      final skipped = autoFixture('queued-intermediate', 3443, 'FI');
      final finalChoice = autoFixture('queued-final', 4443, 'SE');
      await launchWithProfile(
        tester,
        initialProfile: original,
        extraProfiles: [firstChoice, skipped, finalChoice],
        waitForStopGuard: false,
        viewport: const Size(380, 1000),
        preferences: const {
          'automaticProfileSelection': true,
          'vpnDisclosureVersion': 1,
        },
      );
      final prefs = await SharedPreferences.getInstance();
      final firstStop = pendingStopAck = Completer<bool>();
      nativeCalls.clear();
      await chooseServer(tester, firstChoice);
      await pumpUntilNativeCall(tester, 'stopVPN');
      expect(prefs.getBool('automaticProfileSelection'), isFalse);
      expect(prefs.getString('selectedProfileId'), original.id);
      expect(find.byKey(activeServerKey), findsNothing);

      await chooseServer(tester, skipped);
      await chooseServer(tester, finalChoice);
      expect(getVpnMutations(), ['stopVPN']);
      expect(nativeConfigs, isEmpty);
      expect(prefs.getString('selectedProfileId'), original.id);

      nativeStatus = 'Stopped';
      pendingStopAck = null;
      firstStop.complete(true);
      scriptedStarts.add(true);
      await pumpUntilNativeCall(tester, 'startVPN');
      await tester.pumpAndSettle();
      expect(getVpnMutations(), [
        'stopVPN',
        'stopVPN',
        'saveConfig',
        'startVPN',
      ]);
      expect(nativeConfigs.single, contains('"server_port":4443'));
      expect(prefs.getString('selectedProfileId'), finalChoice.id);
      expect(prefs.getBool('automaticProfileSelection'), isFalse);
      expect(find.byKey(activeServerKey), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 2));
    },
  );

  testWidgets('a late config write error cannot undo a manual Stop', (
    tester,
  ) async {
    final profile = autoFixture('late-config-rejection', 1443, 'PL');
    await launchWithProfile(
      tester,
      connected: false,
      initialProfile: profile,
      preferences: const {'vpnDisclosureVersion': 1},
    );
    nativeCalls.clear();
    final config = pendingConfigAck = Completer<bool>();
    await tester.tap(find.byKey(powerKey));
    await pumpUntilNativeCall(tester, 'saveConfig');
    expect(getVpnMutations(), ['saveConfig']);
    expect(find.byTooltip('Отменить подключение'), findsOneWidget);

    await tester.tap(find.byKey(powerKey));
    await tester.pump();
    expect(getVpnMutations(), ['saveConfig']);
    pendingConfigAck = null;
    config.completeError(PlatformException(code: 'LATE_FIXTURE_WRITE_ERROR'));
    await pumpUntilNativeCall(tester, 'stopVPN');
    await tester.pumpAndSettle();

    expect(getVpnMutations(), ['saveConfig', 'stopVPN']);
    expect(find.byTooltip('Подключить VPN'), findsOneWidget);
    expect(find.byKey(activeServerKey), findsNothing);
    expect(find.byType(SnackBar), findsNothing);
    expect(await ProfileStore().loadManualDisconnectRequested(), isTrue);
    expect(await ProfileStore().loadSelectedProfileId(), profile.id);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'repeated Started while saving manual Stop cannot queue duplicate stop commands',
    (tester) async {
      await launchWithProfile(tester, waitForStopGuard: false);
      final previous = SharedPreferencesStorePlatform.instance;
      final store = _DelayedManualStopStore(await previous.getAll());
      SharedPreferencesStorePlatform.instance = store;
      addTearDown(() => SharedPreferencesStorePlatform.instance = previous);
      nativeCalls.clear();
      await tester.tap(find.byKey(powerKey));
      await tester.pump();
      expect(store.writes, 1);
      expect(getVpnMutations(), isEmpty);
      for (var i = 0; i < 2; i++) {
        platform.status.add({...networkSnapshot, 'status': 'Started'});
        await tester.pump();
      }
      expect(getVpnMutations(), isEmpty);
      expect(store.writes, 1);
      final stop = pendingStopAck = Completer<bool>();
      store.gate.complete();
      await pumpUntilNativeCall(tester, 'stopVPN');
      expect(getVpnMutations(), ['stopVPN']);
      nativeStatus = 'Stopped';
      pendingStopAck = null;
      stop.complete(true);
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
      expect(getVpnMutations(), ['stopVPN']);
      expect(await ProfileStore().loadManualDisconnectRequested(), isTrue);
      expect(find.byTooltip('Подключить VPN'), findsOneWidget);
      expect(find.byKey(activeServerKey), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  for (final stopError in ['STOP_VPN_ERROR', 'DISPATCH_REJECTED']) {
    testWidgets(
      'cross-engine switch does not install a config before confirmed stop ($stopError)',
      (tester) async {
        final current = autoFixture('original', 1443, 'PL');
        final next = await xhttpFixture();
        await launchWithProfile(
          tester,
          initialProfile: current,
          extraProfiles: [next],
          waitForStopGuard: false,
        );
        final stopAck = Completer<bool>();
        pendingStopAck = stopAck;
        scriptedStarts.add(true);
        nativeCalls.clear();
        await chooseServer(tester, next);
        await pumpUntilNativeCall(tester, 'stopVPN');
        expect(getVpnMutations(), ['stopVPN']);

        final canConfirmLater = stopError == 'STOP_VPN_ERROR';
        if (canConfirmLater) nativeStatus = 'Stopping';
        stopAck.completeError(
          PlatformException(code: stopError, message: 'fixture'),
        );
        pendingStopAck = null;
        await tester.pump(const Duration(milliseconds: 600));
        expect(nativeConfigs, isEmpty);
        expect(getVpnMutations(), ['stopVPN']);
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getString('selectedProfileId'), current.id);
        expect(find.byKey(activeServerKey), findsNothing);

        if (canConfirmLater) {
          nativeStatus = 'Stopped';
          await pumpUntilNativeCall(tester, 'startVPN');
          await tester.pump(const Duration(milliseconds: 450));
          await tester.pumpAndSettle();
          expect(getVpnMutations(), ['stopVPN', 'saveConfig', 'startVPN']);
          expect(prefs.getString('selectedProfileId'), next.id);
          expect(find.byKey(activeServerKey), findsOneWidget);
        } else {
          await tester.pumpAndSettle();
          expect(getVpnMutations(), ['stopVPN']);
          expect(nativeStatus, 'Started');
          expect(prefs.getString('selectedProfileId'), current.id);
          expect(find.byKey(activeServerKey), findsNothing);
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(seconds: 10));
      },
    );
  }

  for (final expired in [false, true]) {
    testWidgets(
      'Hysteria retries only after native cleanup and within its reconnect budget (expired=$expired)',
      (tester) async {
        final current = autoFixture('reconnect-original', 1443, 'PL');
        final target = udpProfile.copyWith(
          id: 'reconnect-target',
          port: 2443,
          outbound: {
            'type': 'hysteria2',
            'server': '127.0.0.1',
            'server_port': 2443,
            'password': 'fixture',
            'tls': {'enabled': true, 'server_name': 'fixture.invalid'},
          },
        );
        final drafts = interceptExternalLinks();
        await launchWithProfile(
          tester,
          initialProfile: current,
          extraProfiles: [target],
          waitForStopGuard: false,
          useTestStatusClock: true,
          useTestReconnectClock: true,
          viewport: const Size(380, 1200),
        );
        final reloadAck = pendingReloadAck = Completer<bool>();
        final stopAck = pendingStopAck = Completer<bool>();
        final prefs = await SharedPreferences.getInstance();
        nativeCalls.clear();
        await chooseServer(tester, target);
        await pumpUntilNativeCall(tester, 'reloadVPN');
        expect(getVpnMutations(), ['saveConfig', 'reloadVPN']);
        expect(nativeConfigs.single, contains('"server_port":2443'));
        expect(prefs.getString('selectedProfileId'), current.id);

        nativeStatus = 'Starting';
        pendingReloadAck = null;
        reloadAck.complete(true);
        await tester.pump();
        await tester.pump(const Duration(seconds: 39));
        expect(getVpnMutations(), ['saveConfig', 'reloadVPN']);
        await tester.pump(const Duration(seconds: 2));
        await pumpUntilNativeCall(tester, 'stopVPN');

        nativeStatus = 'Stopping';
        pendingStopAck = null;
        stopAck.complete(true);
        await tester.pump();
        // Both stop confirmations are within the native 35 s grace. Only the
        // longer one exhausts the Hysteria plan's shared 65 s budget.
        await tester.pump(Duration(seconds: expired ? 26 : 20));
        expect(getVpnMutations(), ['saveConfig', 'reloadVPN', 'stopVPN']);
        expect(find.byTooltip('Отменить подключение'), findsOneWidget);
        expect(prefs.getString('selectedProfileId'), current.id);
        expect(nativeConfigs, hasLength(1));

        nativeStatus = 'Stopped';
        scriptedStarts.add(true);
        for (var frame = 0; frame < 8; frame++) {
          await tester.pump(const Duration(milliseconds: 250));
        }
        await tester.pumpAndSettle();
        if (expired) {
          expect(getVpnMutations(), ['saveConfig', 'reloadVPN', 'stopVPN']);
          expect(nativeConfigs, hasLength(1));
          expect(prefs.getString('selectedProfileId'), current.id);
          expect(find.byKey(activeServerKey), findsNothing);
          expect(powerSurface(tester), YurichMobileColors.powerError);
          await openSupportReport(tester);
          await tester.pumpAndSettle();
          expect(
            drafts.single.queryParameters['body'],
            contains('VPN reconnect attempt budget expired.'),
          );
        } else {
          expect(getVpnMutations(), [
            'saveConfig',
            'reloadVPN',
            'stopVPN',
            'saveConfig',
            'startVPN',
          ]);
          expect(nativeConfigs, hasLength(2));
          expect(nativeConfigs.last, nativeConfigs.first);
          expect(prefs.getString('selectedProfileId'), target.id);
          expect(find.byKey(activeServerKey), findsOneWidget);
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'same-engine Naive reload failure cleans up before using the native fallback',
    (tester) async {
      final current = autoFixture('original', 1443, 'PL');
      final next = autoFixture('naive-fallback', 2443, 'SE');
      await launchWithProfile(
        tester,
        initialProfile: current,
        extraProfiles: [next],
        waitForStopGuard: false,
      );
      final stopAck = Completer<bool>();
      pendingStopAck = stopAck;
      scriptedStarts.add(true);
      reloadCommandError = PlatformException(code: 'RELOAD_FIXTURE_FAILURE');
      nativeCalls.clear();
      await chooseServer(tester, next);
      await pumpUntilNativeCall(tester, 'stopVPN');
      expect(getVpnMutations(), ['saveConfig', 'reloadVPN', 'stopVPN']);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('selectedProfileId'), current.id);
      expect(find.byKey(activeServerKey), findsNothing);

      nativeStatus = 'Stopping';
      stopAck.complete(true);
      pendingStopAck = null;
      await tester.pump(const Duration(milliseconds: 750));
      expect(getVpnMutations(), ['saveConfig', 'reloadVPN', 'stopVPN']);
      expect(nativeConfigs, hasLength(1));
      nativeStatus = 'Stopped';
      await pumpUntilNativeCall(tester, 'startVPN');
      await tester.pumpAndSettle();
      expect(getVpnMutations(), [
        'saveConfig',
        'reloadVPN',
        'stopVPN',
        'saveConfig',
        'startVPN',
      ]);
      expect(
        nativeConfigs.map((source) {
          final conf = jsonDecode(source) as Map;
          final proxy =
              (conf['outbounds'] as List).singleWhere(
                    (p) => p['tag'] == 'proxy',
                  )
                  as Map;
          return (proxy['type'], proxy['server_port']);
        }),
        [('http', 2443), ('naive', 2443)],
      );
      expect(prefs.getString('selectedProfileId'), next.id);
      expect(find.byKey(activeServerKey), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 10));
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

  testWidgets(
    'disabling Smart Route waits for the old TUN before clearing its binding',
    (tester) async {
      killSwitch = {'known': true, 'runtimeKnown': true};
      await launchWithProfile(
        tester,
        initialProfile: autoFixture('qa-disable-route', 1443, 'PL'),
        preferences: const {'smartRouteRuDirect': true},
        waitForStopGuard: false,
      );
      await tester.tap(find.byKey(settingsKey));
      await tester.pumpAndSettle();
      final route = find.byKey(smartRouteKey);
      expect(tester.widget<SwitchListTile>(route).value, isTrue);
      final settings = await SharedPreferences.getInstance();
      nativeCalls.clear();
      pendingStopAck = Completer<bool>();
      scriptedStarts.add(true);
      await tester.tap(route);
      await pumpUntilNativeCall(tester, 'stopVPN');
      expect(settings.getBool('smartRouteRuDirect'), isTrue);
      expect(nativeCalls, isNot(contains('clearSmartRouteAppBinding')));
      expect(getVpnMutations(), ['stopVPN']);

      nativeStatus = 'Stopped';
      pendingStopAck!.complete(true);
      pendingStopAck = null;
      await pumpUntilNativeCall(tester, 'startVPN');
      await tester.pumpAndSettle();
      expect(settings.getBool('smartRouteRuDirect'), isFalse);
      expect(
        nativeCalls,
        containsAllInOrder([
          'stopVPN',
          'clearSmartRouteAppBinding',
          'saveConfig',
          'startVPN',
        ]),
      );
      expect(managedConfigSaves.single, isFalse);
      expect(tester.widget<SwitchListTile>(route).value, isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 10));
    },
  );

  testWidgets(
    'Always-on stop offers Android settings without closing the VPN',
    (tester) async {
      killSwitch = {
        'known': true,
        'runtimeKnown': true,
        'alwaysOn': true,
        'lockdown': true,
        'strictRuntime': true,
        'vpnActive': true,
      };
      await launchWithProfile(tester, waitForStopGuard: false);
      await tester.tap(find.byKey(powerKey));
      await tester.pumpAndSettle();
      expect(find.text('Kill switch Android'), findsOneWidget);
      await tester.tap(find.text('Отмена'));
      await tester.pumpAndSettle();
      expect(getVpnMutations(), isEmpty);
      expect(nativeCalls, isNot(contains('openVpnSettings')));
      expect(find.byKey(activeServerKey), findsOneWidget);

      await tester.tap(find.byKey(powerKey));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Открыть настройки'));
      await tester.pumpAndSettle();
      expect(
        nativeCalls,
        containsAllInOrder(['setKillSwitchRequested', 'openVpnSettings']),
      );
      expect(getVpnMutations(), ['setKillSwitchRequested']);
      expect(killSwitch['requested'], true);
      expect(nativeStatus, 'Started');
    },
  );

  testWidgets(
    'unavailable Android VPN settings show manual guidance without stopping VPN',
    (tester) async {
      killSwitch = {
        'known': true,
        'runtimeKnown': true,
        'alwaysOn': true,
        'lockdown': true,
        'strictRuntime': true,
        'vpnActive': true,
      };
      killSwitchSettingsError = PlatformException(code: 'FIXTURE_NO_SETTINGS');
      await launchWithProfile(tester, waitForStopGuard: false);
      nativeCalls.clear();

      await tester.tap(find.byKey(powerKey));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Открыть настройки'));
      await tester.pumpAndSettle();

      expect(
        find.text('Открой настройки Android → VPN → Yurich Connect.'),
        findsOneWidget,
      );
      expect(
        nativeCalls,
        containsAllInOrder(['setKillSwitchRequested', 'openVpnSettings']),
      );
      expect(getVpnMutations(), ['setKillSwitchRequested']);
      expect(killSwitch['requested'], isTrue);
      expect(killSwitch['lockdown'], isTrue);
      expect(find.byKey(activeServerKey), findsOneWidget);
    },
  );

  testWidgets('the English privacy link cannot substitute for VPN consent', (
    tester,
  ) async {
    final opened = interceptExternalLinks(opened: false);
    await launchWithProfile(
      tester,
      connected: false,
      preferences: const {'languageCode': 'en', 'smartRouteRuDirect': true},
    );
    nativeCalls.clear();
    await tester.tap(find.byKey(powerKey));
    await tester.pumpAndSettle();

    expect(find.text('VPN traffic protection'), findsOneWidget);
    expect(find.textContaining('your regular network IP'), findsOneWidget);
    expect(
      find.textContaining(
        'The VPN will not connect without your explicit consent.',
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('Privacy'));
    await tester.pumpAndSettle();
    expect(opened.single.scheme, 'https');
    expect(opened.single.pathSegments.last, 'PRIVACY.md');
    expect(find.text('VPN traffic protection'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Could not open the link.'), findsOneWidget);
    expect(getVpnMutations(), isEmpty);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt('vpnDisclosureVersion'), isNull);
    expect(find.byTooltip('Connect VPN'), findsOneWidget);
  });

  testWidgets('direct latency has explicit consent and opt-out never probes', (
    tester,
  ) async {
    killSwitch = {'known': true, 'runtimeKnown': true};
    await launchWithProfile(tester, connected: false);
    await tester.tap(find.byKey(settingsKey));
    await tester.pumpAndSettle();
    final tile = find.byKey(const ValueKey('mobile-direct-latency'));
    final prefs = await SharedPreferences.getInstance();
    nativeCalls.clear();
    await tester.tap(tile);
    await tester.pumpAndSettle();
    expect(find.textContaining('обычный IP'), findsWidgets);
    await tester.tap(find.text('Без прямого замера'));
    await tester.pumpAndSettle();
    expect(prefs.getBool('directLatencyAllowed'), isFalse);
    expect(tester.widget<SwitchListTile>(tile).value, isFalse);

    await tester.tap(tile);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Разрешить замер'));
    await tester.pumpAndSettle();
    expect(prefs.getBool('directLatencyAllowed'), isTrue);
    expect(tester.widget<SwitchListTile>(tile).value, isTrue);

    await tester.tap(tile);
    await tester.pumpAndSettle();
    expect(prefs.getBool('directLatencyAllowed'), isFalse);
    expect(tester.widget<SwitchListTile>(tile).value, isFalse);
    expect(nativeCalls, isNot(contains('getDirectProbeNetwork')));
    expect(getVpnMutations(), isEmpty);
  });

  for (final throws in [false, true]) {
    testWidgets(
      'failed consent storage keeps direct latency off (throws=$throws)',
      (tester) async {
        killSwitch = {'known': true, 'runtimeKnown': true};
        final profile = autoFixture('consent-save-failure', 1443, 'PL');
        await launchWithProfile(
          tester,
          connected: false,
          initialProfile: profile,
          preferences: const {
            'automaticProfileSelection': true,
            'directLatencyAllowed': false,
            'vpnDisclosureVersion': 1,
          },
        );
        final previous = SharedPreferencesStorePlatform.instance;
        final unavailable = _RejectDirectLatencyOptIn(
          await previous.getAll(),
          throws: throws,
        );
        SharedPreferencesStorePlatform.instance = unavailable;
        addTearDown(() => SharedPreferencesStorePlatform.instance = previous);
        nativeCalls.clear();

        await tester.tap(find.byKey(settingsKey));
        await tester.pumpAndSettle();
        final tile = find.byKey(const ValueKey('mobile-direct-latency'));
        await tester.tap(tile);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Разрешить замер'));
        await tester.pumpAndSettle();
        expect(unavailable.rejectedWrites, 1);
        expect(
          (await unavailable.getAll())['flutter.directLatencyAllowed'],
          isFalse,
        );
        expect(tester.widget<SwitchListTile>(tile).value, isFalse);
        expect(
          find.text(
            'Настройка не сохранилась. Прямые замеры выключены в этом сеансе.',
          ),
          findsOneWidget,
        );
        expect(getVpnMutations(), isEmpty);

        await tester.tap(find.byKey(const ValueKey('mobile-home-tab')));
        await tester.pumpAndSettle();
        scriptedStarts.add(true);
        await tester.tap(find.byKey(powerKey));
        await pumpUntilNativeCall(tester, 'startVPN');
        await tester.pump(const Duration(seconds: 2));
        expect(getVpnMutations(), ['saveConfig', 'startVPN']);
        expect(nativeCalls, isNot(contains('getDirectProbeNetwork')));
        expect(nativeCalls, isNot(contains('resolveDirectProbeHost')));
        expect(find.byKey(activeServerKey), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(seconds: 2));
      },
    );
  }

  for (final connected in [false, true]) {
    testWidgets(
      'DNS preference is saved and only restarts an active VPN (connected=$connected)',
      (tester) async {
        await launchWithProfile(
          tester,
          initialProfile: autoFixture('dns-fixture', 1443, 'PL'),
          connected: connected,
          waitForStopGuard: false,
        );
        await tester.tap(find.byKey(settingsKey));
        await tester.pumpAndSettle();
        final dns = find.widgetWithText(SwitchListTile, 'DNS');
        expect(tester.widget<SwitchListTile>(dns).value, isFalse);
        nativeCalls.clear();
        if (connected) {
          scriptedStarts.add(true);
          pendingStopAck = Completer<bool>();
        }
        await tester.tap(dns);
        if (connected) {
          await pumpUntilNativeCall(tester, 'stopVPN');
          expect(getVpnMutations(), ['stopVPN']);
          nativeStatus = 'Stopped';
          pendingStopAck!.complete(true);
          pendingStopAck = null;
          await pumpUntilNativeCall(tester, 'startVPN');
        }
        await tester.pumpAndSettle();
        expect(tester.widget<SwitchListTile>(dns).value, isTrue);
        expect(
          (await SharedPreferences.getInstance()).getString(
            'dnsProtectionMode',
          ),
          'leak_guard',
        );
        expect(
          getVpnMutations(),
          connected ? ['stopVPN', 'saveConfig', 'startVPN'] : [],
        );
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(seconds: 10));
      },
    );
  }

  for (final writeFails in [false, true]) {
    testWidgets(
      'automatic Kill Switch apply saves strict intent before touching the VPN (error=$writeFails)',
      (tester) async {
        final profile = autoFixture('strict-apply-fixture', 1443, 'PL');
        await launchWithProfile(
          tester,
          initialProfile: profile,
          waitForStopGuard: false,
          preferences: const {'smartRouteRuDirect': true},
        );
        nativeCalls.clear();
        if (writeFails) {
          killSwitchWriteError = PlatformException(
            code: 'STRICT_FIXTURE_FAILURE',
          );
        } else {
          pendingStopAck = Completer<bool>();
          scriptedStarts.add(true);
        }
        killSwitch = {
          'known': true,
          'runtimeKnown': true,
          'alwaysOn': true,
          'lockdown': true,
          'strictRuntime': false,
          'vpnActive': true,
          'requested': false,
        };
        binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        await tester.pump();
        await pumpUntilNativeCall(tester, 'setKillSwitchRequested');
        if (writeFails) {
          await tester.pumpAndSettle();
          expect(getVpnMutations(), ['setKillSwitchRequested']);
          expect(killSwitch['requested'], isFalse);
          expect(nativeStatus, 'Started');
          expect(
            find.textContaining('Защиту Android не отключали'),
            findsOneWidget,
          );
          expect(find.byKey(activeServerKey), findsOneWidget);
        } else {
          await pumpUntilNativeCall(tester, 'stopVPN');
          expect(getVpnMutations(), ['setKillSwitchRequested', 'stopVPN']);
          expect(killSwitch['requested'], isTrue);
          expect(nativeConfigs, isEmpty);
          nativeStatus = 'Stopping';
          pendingStopAck!.complete(true);
          pendingStopAck = null;
          await tester.pump(const Duration(milliseconds: 600));
          expect(getVpnMutations(), ['setKillSwitchRequested', 'stopVPN']);
          nativeStatus = 'Stopped';
          killSwitch = {...killSwitch, 'strictRuntime': true};
          await pumpUntilNativeCall(tester, 'startVPN');
          await tester.pumpAndSettle();
          expect(getVpnMutations(), [
            'setKillSwitchRequested',
            'stopVPN',
            'saveConfig',
            'startVPN',
          ]);
          expect(nativeConfigs.single, contains('"server_port":1443'));
          expect(find.byKey(activeServerKey), findsOneWidget);
        }
        expect(killSwitch['alwaysOn'], isTrue);
        expect(killSwitch['lockdown'], isTrue);
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getBool('smartRouteRuDirect'), isTrue);
        expect(prefs.getString('selectedProfileId'), profile.id);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(seconds: 10));
      },
    );
  }

  testWidgets(
    'gear Kill Switch confirms Android settings and reads back protection',
    (tester) async {
      killSwitch = {'known': true, 'supported': true};
      await launchWithProfile(tester, connected: false);
      await tester.tap(find.byKey(settingsKey));
      await tester.pumpAndSettle();
      final setup = find.text('Настроить в Android');
      nativeCalls.clear();
      await tapSettingsItem(tester, setup);
      expect(find.text('Kill switch Android'), findsOneWidget);
      await tester.tap(find.text('Отмена'));
      await tester.pumpAndSettle();
      expect(nativeCalls, isNot(contains('openVpnSettings')));
      expect(getVpnMutations(), isEmpty);

      await tapSettingsItem(tester, setup);
      await tester.tap(find.text('Открыть настройки'));
      await tester.pumpAndSettle();
      expect(
        nativeCalls,
        containsAllInOrder(['setKillSwitchRequested', 'openVpnSettings']),
      );
      expect(getVpnMutations(), ['setKillSwitchRequested']);
      expect(killSwitch['requested'], isTrue);

      // Opening Android settings does not itself confirm any protection.
      killSwitch = {...killSwitch, 'alwaysOn': true, 'lockdown': true};
      nativeCalls.clear();
      await tapSettingsItem(tester, find.text('Проверить защиту'));
      expect(nativeCalls, contains('getKillSwitchState'));
      expect(
        find.text('Android блокирует обход; состояние TUN уточняется'),
        findsOneWidget,
      );
      expect(find.text('Включён: Android + строгий TUN'), findsNothing);
      expect(getVpnMutations(), isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('manual strict routes do not stop VPN when intent write fails', (
    tester,
  ) async {
    killSwitch = {
      'known': true,
      'runtimeKnown': true,
      'requested': false,
      'alwaysOn': true,
      'lockdown': true,
      'strictRuntime': false,
      'vpnActive': true,
    };
    killSwitchWriteError = PlatformException(code: 'FIXTURE_WRITE_FAILED');
    await launchWithProfile(
      tester,
      waitForStopGuard: false,
      preferences: const {'smartRouteRuDirect': true},
    );
    await tester.tap(find.byKey(settingsKey));
    await tester.pumpAndSettle();
    nativeCalls.clear();

    await tapSettingsItem(tester, find.text('Применить строгие маршруты'));
    expect(find.textContaining('Защиту Android не отключали'), findsOneWidget);
    expect(getVpnMutations(), ['setKillSwitchRequested']);
    expect(killSwitch['requested'], isFalse);
    expect(killSwitch['lockdown'], isTrue);
    expect(nativeStatus, 'Started');
    expect(
      (await SharedPreferences.getInstance()).getBool('smartRouteRuDirect'),
      isTrue,
    );
    expect(tester.takeException(), isNull);
  });

  for (final relock in [false, true]) {
    testWidgets(
      'normal routes recheck Android protection after confirmation (relock=$relock)',
      (tester) async {
        killSwitch = {'known': true, 'supported': true, 'requested': true};
        await launchWithProfile(
          tester,
          connected: false,
          preferences: const {'smartRouteRuDirect': true},
        );
        await tester.tap(find.byKey(settingsKey));
        await tester.pumpAndSettle();
        nativeCalls.clear();
        await tapSettingsItem(tester, find.text('Обычные маршруты'));
        expect(find.text('Обычные маршруты?'), findsOneWidget);
        expect(getVpnMutations(), isEmpty);

        if (relock) {
          killSwitch = {...killSwitch, 'alwaysOn': true, 'lockdown': true};
        }
        final dialog = find.byType(AlertDialog);
        await tester.tap(
          find.descendant(of: dialog, matching: find.text('Обычные маршруты')),
        );
        await tester.pumpAndSettle();
        expect(nativeCalls, contains('getKillSwitchState'));
        expect(getVpnMutations(), [if (!relock) 'setKillSwitchRequested']);
        expect(killSwitch['requested'], relock);
        expect(nativeStatus, 'Stopped');
        expect(
          (await SharedPreferences.getInstance()).getBool('smartRouteRuDirect'),
          isTrue,
        );
        expect(find.text('Обычные маршруты'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

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
    expect(
      find.byKey(const ValueKey('mobile-smart-route-normal')),
      findsNothing,
    );
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

  testWidgets(
    'TV Smart Route respects strict Kill Switch without losing preferences',
    (tester) async {
      killSwitch = {
        'known': true,
        'runtimeKnown': true,
        'requested': true,
        'alwaysOn': true,
        'lockdown': true,
        'strictRuntime': true,
        'vpnActive': true,
      };
      await launchWithProfile(
        tester,
        tvMode: true,
        viewport: const Size(1280, 720),
        waitForStopGuard: false,
        preferences: const {'smartRouteRuDirect': true},
      );
      await tester.tap(find.byKey(const ValueKey('tv-settings-tab')));
      await tester.pumpAndSettle();
      nativeCalls.clear();
      await tester.tap(find.byKey(const ValueKey('tv-smart-route')));
      await tester.pumpAndSettle();
      expect(
        find.text(
          'Smart Route приостановлен строгим kill switch. Настройка сохранена.',
        ),
        findsOneWidget,
      );
      expect(
        (await SharedPreferences.getInstance()).getBool('smartRouteRuDirect'),
        isTrue,
      );
      expect(
        tester.widget<TvHomeScreen>(find.byType(TvHomeScreen)).smartRoute,
        isTrue,
      );
      expect(getVpnMutations(), isEmpty);
      expect(nativeCalls, isNot(contains('clearSmartRouteBinding')));
      expect(killSwitch['lockdown'], isTrue);
      expect(nativeStatus, 'Started');
      expect(tester.takeException(), isNull);
    },
  );

  for (final protectionReenabled in [false, true]) {
    testWidgets(
      'Restore Smart Route rechecks Android; lockdown=$protectionReenabled',
      (tester) async {
        killSwitch = {
          'known': true,
          'runtimeKnown': true,
          'requested': true,
          'strictRuntime': true,
          'vpnActive': true,
        };
        await launchWithProfile(
          tester,
          initialProfile: autoFixture('qa-restore', 1443, 'PL'),
          preferences: const {
            'smartRouteRuDirect': true,
            'automaticProfileSelection': true,
          },
          waitForStopGuard: false,
        );
        await tester.tap(find.byKey(settingsKey));
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey('mobile-smart-route-normal')),
        );
        await tester.pumpAndSettle();
        nativeCalls.clear();
        if (protectionReenabled) {
          killSwitch = {...killSwitch, 'alwaysOn': true, 'lockdown': true};
        }
        pendingStopAck = Completer<bool>();
        scriptedStarts.add(true);
        await tester.tap(
          find.widgetWithText(TextButton, 'Обычные маршруты').last,
        );
        if (protectionReenabled) {
          await tester.pumpAndSettle();
          expect(nativeCalls, isNot(contains('setKillSwitchRequested')));
          expect(getVpnMutations(), isEmpty);
        } else {
          await pumpUntilNativeCall(tester, 'stopVPN');
          expect(killSwitch['requested'], false);
          expect(getVpnMutations(), ['setKillSwitchRequested', 'stopVPN']);
          nativeStatus = 'Stopped';
          killSwitch = {
            ...killSwitch,
            'strictRuntime': false,
            'vpnActive': false,
          };
          pendingStopAck!.complete(true);
          pendingStopAck = null;
          await pumpUntilNativeCall(tester, 'startVPN');
          await tester.pumpAndSettle();
          expect(getVpnMutations(), [
            'setKillSwitchRequested',
            'stopVPN',
            'saveConfig',
            'startVPN',
          ]);
          expect(nativeConfigs.single, contains('"server_port":1443'));
          expect(managedConfigSaves.single, true);
          expect(
            tester.widget<SwitchListTile>(find.byKey(smartRouteKey)).onChanged,
            isNotNull,
          );
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(seconds: 10));
      },
    );
  }

  testWidgets(
    'offline Smart Route restoration changes intent only after confirmation',
    (tester) async {
      killSwitch = {
        'known': true,
        'runtimeKnown': true,
        'requested': true,
        'vpnActive': false,
      };
      await launchWithProfile(
        tester,
        connected: false,
        preferences: const {'smartRouteRuDirect': true},
      );
      await tester.tap(find.byKey(settingsKey));
      await tester.pumpAndSettle();
      final restore = find.byKey(const ValueKey('mobile-smart-route-normal'));
      nativeCalls.clear();

      await tester.tap(restore);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Отмена'));
      await tester.pumpAndSettle();
      expect(getVpnMutations(), isEmpty);
      expect(killSwitch['requested'], isTrue);

      await tester.tap(restore);
      await tester.pumpAndSettle();
      await tester.tap(
        find.widgetWithText(TextButton, 'Обычные маршруты').last,
      );
      await tester.pumpAndSettle();
      expect(getVpnMutations(), ['setKillSwitchRequested']);
      expect(killSwitch['requested'], isFalse);
      expect(restore, findsNothing);
      expect(
        tester.widget<SwitchListTile>(find.byKey(smartRouteKey)).value,
        isTrue,
      );
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('smartRouteRuDirect'), isTrue);
    },
  );

  testWidgets(
    'unavailable Smart Route apps cannot overwrite existing exclusions',
    (tester) async {
      smartRouteAppsUnavailable = true;
      await launchWithProfile(
        tester,
        waitForStopGuard: false,
        preferences: const {'smartRouteRuDirect': true},
      );
      await tester.tap(find.byKey(settingsKey));
      await tester.pumpAndSettle();
      nativeCalls.clear();
      await tester.tap(find.text('Приложения напрямую'));
      await tester.pumpAndSettle();

      expect(find.text('Список приложений недоступен.'), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);
      expect(nativeCalls, contains('getSmartRouteApps'));
      expect(getVpnMutations(), isEmpty);
      expect(smartRouteSelections, isEmpty);
      expect(
        tester.widget<SwitchListTile>(find.byKey(smartRouteKey)).value,
        isTrue,
      );
      expect(nativeStatus, 'Started');
    },
  );

  testWidgets(
    'support report strips fixture credentials and falls back to the clipboard',
    (tester) async {
      final drafts = interceptExternalLinks(opened: false);
      final clipboard = interceptClipboardWrites();
      await launchWithProfile(
        tester,
        connected: false,
        viewport: const Size(380, 1200),
        preferences: const {'smartRouteRuDirect': true},
      );
      bufferedNativeLogs.addAll([
        'WARN request failed: https://fixture.invalid/sub/fixture-sub-secret?token=fixture-query-secret',
        'WARN Authorization: Bearer fixture-bearer-secret',
      ]);
      nativeCalls.clear();
      await openSupportReport(tester);
      await tester.pumpAndSettle();
      expect(drafts.single.scheme, 'mailto');
      final report = clipboard.single;
      expect(drafts.single.queryParameters['body'], report);
      expect(report, contains('smart_route_enabled: true'));
      expect(report, contains('core_engine:'));
      expect(report, contains('profile_network_stats:'));
      expect(report, contains('WARN request failed:'));
      expect(report, contains('Bearer ***'));
      expect(report, isNot(contains('fixture-sub-secret')));
      expect(report, isNot(contains('fixture-query-secret')));
      expect(report, isNot(contains('fixture-bearer-secret')));
      expect(
        find.text('Почта не открылась. Отчёт скопирован в буфер.'),
        findsOneWidget,
      );
      expect(nativeCalls, contains('getLogs'));
      expect(getVpnMutations(), isEmpty);
    },
  );

  testWidgets(
    'support report without profiles opens a draft even if native logs time out',
    (tester) async {
      final drafts = interceptExternalLinks();
      final clipboard = interceptClipboardWrites();
      networkSnapshot = {};
      PackageInfo.setMockInitialValues(
        appName: 'Yurich Connect',
        packageName: 'online.dnsai.ivanvpn',
        version: '1.0.126',
        buildNumber: '',
        buildSignature: '',
      );
      await launchWithProfile(
        tester,
        seedProfile: false,
        connected: false,
        viewport: const Size(380, 1200),
        preferences: const {'smartRouteRuDirect': false},
      );

      nativeCalls.clear();
      final logs = pendingBufferedLogs = Completer<List<String>>();
      await openSupportReport(tester);
      expect(nativeCalls.where((method) => method == 'getLogs'), hasLength(1));
      await tester.pump(const Duration(milliseconds: 1600));
      expect(drafts, isEmpty);
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
      final draft = drafts.single;
      final report = draft.queryParameters['body']!;
      expect(draft.scheme, 'mailto');
      expect(draft.queryParameters['subject'], isNotEmpty);
      expect(report, contains('profiles:\nnone'));
      expect(report, contains('stability_events:\nnone'));
      expect(report, contains('smart_route_enabled: false'));
      for (final field in ['core_engine:', 'app_build:', 'smart_route_mode:']) {
        expect(report, isNot(contains(field)));
      }
      logs.complete(const ['fixture late log']);
      pendingBufferedLogs = null;
      await tester.pump();
      expect(drafts, hasLength(1));
      expect(report, isNot(contains('fixture late log')));
      expect(clipboard, isEmpty);
      expect(find.textContaining('Почта не открылась'), findsNothing);
      expect((await ProfileStore().loadProfiles()), isEmpty);
      expect(getVpnMutations(), isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'support report includes Hysteria network history, expiry and filtered recent logs',
    (tester) async {
      final drafts = interceptExternalLinks();
      final clipboard = interceptClipboardWrites();
      final expires = DateTime.utc(2099, 5, 23, 15);
      final profile = udpProfile.copyWith(
        port: 1443,
        name: 'QA Hysteria fixture',
        subscriptionExpiresAt: expires,
        subscriptionSource:
            'https://fixture.invalid/sub?token=fixture-subscription-only',
        outbound: {
          'type': 'hysteria2',
          'server': '127.0.0.1',
          'server_port': 1443,
          'password': 'fixture-runtime-only',
          'tls': {'enabled': true, 'server_name': 'fixture.invalid'},
        },
      );
      await launchWithProfile(
        tester,
        connected: false,
        initialProfile: profile,
        profileGeoService: _ScriptedHomeGeo(),
        viewport: const Size(380, 1200),
        preferences: {
          'vpnDisclosureVersion': 1,
          'profileStabilityStats': jsonEncode({
            profile.id: {
              'failedStarts': 1,
              'lastFailureReason': 'Authorization: Bearer fixture-history-only',
            },
          }),
          'profileNetworkStabilityStats': jsonEncode({
            profile.id: {
              'wifi': {'successfulStarts': 2},
              'cellular': {'recoveries': 1, 'trafficBytes': 100},
            },
          }),
        },
      );
      scriptedStarts.add(true);
      await tester.tap(find.byKey(powerKey));
      await pumpUntilNativeCall(tester, 'startVPN');
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.byKey(activeServerKey), findsOneWidget);

      const lastGeneration = 70;
      for (var generation = 1; generation <= lastGeneration; generation++) {
        networkSnapshot = {
          ...networkSnapshot,
          'generation': generation,
          'fingerprint': 'synthetic-network-$generation',
        };
        platform.status.add({'status': 'Started', ...networkSnapshot});
        await tester.pump();
      }
      await emitTraffic(tester, generation: lastGeneration);
      await tester.pump(const Duration(seconds: 1));
      bufferedNativeLogs.addAll([
        for (var i = 0; i < 72; i++) 'fixture-native-log-$i;',
        'router: found package name: fixture.noise.only',
        'WARN Authorization: Bearer fixture-log-only',
      ]);

      nativeCalls.clear();
      await openSupportReport(tester);
      await tester.pumpAndSettle();
      final draft = drafts.single;
      expect(draft.scheme, 'mailto');
      final report = draft.queryParameters['body']!;
      for (final field in [
        'transport_mode: warp',
        'transport=udp',
        'expires=${expires.toIso8601String()}',
        'network_fingerprint: synthetic-network-$lastGeneration',
        'network_changing_until_local:',
        'next_health_check_local:',
        'last_native_activity_local:',
        'last_traffic_local:',
        'last_healthy_local:',
        'profile_last_failure: Authorization: Bearer ***',
        'profile_network_stats: cellular:starts=0,recovery=1,fail=0,traffic=100; '
            'wifi:starts=3,recovery=0,fail=0,traffic=1048576',
        'WARN Authorization: Bearer ***',
      ]) {
        expect(report, contains(field));
      }
      final history = report
          .split('\nstability_events:\n')
          .last
          .split('\n\nprofiles:\n')
          .first
          .split('\n');
      expect(history, hasLength(30));
      expect(history, isNot(contains(endsWith('g=1'))));
      expect(history, contains(endsWith('g=$lastGeneration')));
      for (final excluded in [
        'fixture-native-log-0;',
        'fixture.noise.only',
        'fixture-log-only',
        'fixture-history-only',
        'fixture-runtime-only',
        'fixture-subscription-only',
      ]) {
        expect(report, isNot(contains(excluded)));
      }
      expect(report.indexOf('fixture-native-log-70;'), isNonNegative);
      expect(
        report.indexOf('fixture-native-log-71;'),
        greaterThan(report.indexOf('fixture-native-log-70;')),
      );
      expect(clipboard, isEmpty);
      expect(getVpnMutations(), isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'support report describes Xray Reality and a native exit during resume',
    (tester) async {
      final drafts = interceptExternalLinks(opened: false);
      final clipboard = interceptClipboardWrites();
      const fixtureId = '11111111-1111-4111-8111-111111111111';
      const realityKey = 'fixture-reality-key';
      final profile = (await ProfileImporter().importFromText(
        'vless://$fixtureId@127.0.0.1:2443'
        '?security=reality&type=xhttp&sni=fixture.invalid&path=%2Fqa'
        '&mode=auto&pbk=$realityKey&sid=01#QA%20Reality',
      )).single.copyWith(countryCode: 'SE');
      await launchWithProfile(
        tester,
        connected: false,
        initialProfile: profile,
        profileGeoService: _ScriptedHomeGeo(),
        viewport: const Size(380, 1200),
        preferences: const {'vpnDisclosureVersion': 1},
      );
      scriptedStarts.add(true);
      await tester.tap(find.byKey(powerKey));
      await pumpUntilNativeCall(tester, 'startVPN');
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.byKey(activeServerKey), findsOneWidget);

      binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      nativeStatus = 'Stopped';
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump(const Duration(milliseconds: 2100));
      await tester.pump();
      expect(find.byKey(activeServerKey), findsNothing);
      nativeCalls.clear();
      await openSupportReport(tester);
      await tester.pumpAndSettle();
      final report = clipboard.single;
      expect(drafts.single.queryParameters['body'], report);
      expect(report, contains('core_engine: xray'));
      expect(report, contains('last_recovery_source: app-resume'));
      expect(report, contains('last_resume_recovery_local:'));
      expect(
        report,
        contains('profile_last_failure: unexpected-stop:app-resume'),
      );
      final config = report
          .split('\n')
          .singleWhere((line) => line.startsWith('config:'));
      expect(config, contains('transport=xhttp'));
      expect(config, contains('security=reality'));
      expect(config, contains('reality=true'));
      expect(report, isNot(contains(fixtureId)));
      expect(report, isNot(contains(realityKey)));
      expect(getVpnMutations(), isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Reality TCP uses sing-box and reports its mode without exposing keys',
    (tester) async {
      const id = '11111111-1111-4111-8111-111111111111';
      const key = 'fixture-reality-public-key';
      final profile = (await ProfileImporter().importFromText(
        'vless://$id@127.0.0.1:1443?security=reality&type=tcp'
        '&sni=fixture.invalid&pbk=$key&sid=01&flow=xtls-rprx-vision#QA%20Reality',
      )).single.copyWith(countryCode: 'PL');
      final drafts = interceptExternalLinks();
      await launchWithProfile(
        tester,
        connected: false,
        initialProfile: profile,
        viewport: const Size(380, 1200),
        preferences: const {'vpnDisclosureVersion': 1},
      );
      scriptedStarts.add(true);
      nativeCalls.clear();
      await tester.tap(find.byKey(powerKey));
      await pumpUntilNativeCall(tester, 'startVPN');
      await tester.pump(const Duration(seconds: 2));
      expect(getVpnMutations(), ['saveConfig', 'startVPN']);
      final config = jsonDecode(nativeConfigs.single) as Map;
      final proxy = (config['outbounds'] as List).cast<Map>().singleWhere(
        (entry) => entry['tag'] == 'proxy',
      );
      expect(proxy['type'], 'vless');
      expect((proxy['tls'] as Map)['reality'], containsPair('enabled', true));
      expect(find.byKey(activeServerKey), findsOneWidget);

      await openSupportReport(tester);
      await tester.pumpAndSettle();
      final report = drafts.single.queryParameters['body']!;
      expect(report, contains('core_engine: singBox'));
      expect(report, contains('mode=reality-tcp'));
      expect(report, contains('flow=xtls-rprx-vision'));
      expect(report, isNot(contains(id)));
      expect(report, isNot(contains(key)));
      expect(getVpnMutations(), ['saveConfig', 'startVPN']);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'TV connection failure opens a draft with cooling-down and weak profiles',
    (tester) async {
      final drafts = interceptExternalLinks();
      final cooling = autoFixture('fixture-cooling', 1443, 'PL');
      final weak = autoFixture('fixture-weak', 2443, 'SE');
      final now = DateTime.now().toUtc();
      networkSnapshot = const {'type': 'other', 'validated': true};
      await launchWithProfile(
        tester,
        tvMode: true,
        viewport: const Size(1280, 720),
        connected: false,
        initialProfile: cooling,
        extraProfiles: [weak],
        preferences: {
          'vpnDisclosureVersion': 1,
          'profileStabilityStats': jsonEncode({
            cooling.id: {
              'failedStarts': 3,
              'lastFailureAt': now
                  .subtract(const Duration(minutes: 5))
                  .toIso8601String(),
            },
            weak.id: {
              'failedStarts': 5,
              'lastFailureAt': now
                  .subtract(const Duration(days: 1))
                  .toIso8601String(),
            },
          }),
        },
      );
      nativeCalls.clear();
      configSaved = false;
      await tester.tap(find.byKey(const ValueKey('tv-connect')));
      await pumpUntilNativeCall(tester, 'saveConfig');
      await tester.pumpAndSettle();
      expect(getVpnMutations(), ['saveConfig']);
      expect(drafts, isEmpty);

      final reportAction = find.widgetWithText(SnackBarAction, 'Отчёт');
      expect(reportAction, findsOneWidget);
      await tester.tap(reportAction);
      await tester.pumpAndSettle();
      final draft = drafts.single;
      expect(draft.scheme, 'mailto');
      final report = draft.queryParameters['body']!;
      expect(report, contains('network_label: other'));
      expect(report, contains('profile_stability: Остывает'));
      expect(
        report,
        matches(
          RegExp(r'^- QA fixture-weak.*stability=Слабый', multiLine: true),
        ),
      );
      expect(
        tester.widget<TvHomeScreen>(find.byType(TvHomeScreen)).connected,
        isFalse,
      );
      expect(getVpnMutations(), ['saveConfig']);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'mobile export copies and shows QR only for the selected profile',
    (tester) async {
      const source = 'hy2://fixture@127.0.0.1:1443#Fixture';
      final selected = autoFixture(
        'qr-source',
        1443,
        'PL',
      ).copyWith(originalInput: source);
      final copied = <String>[];
      final messenger = binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add(call.arguments['text'] as String);
        }
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
      );
      await launchWithProfile(
        tester,
        connected: false,
        initialProfile: selected,
      );
      nativeCalls.clear();
      expect(copied, isEmpty);
      await tester.tap(find.byKey(serverPickerKey));
      await tester.pumpAndSettle();
      await pickMobileServerAction(tester, 'Скопировать');
      expect(copied, [source]);
      expect(find.text('Ссылка скопирована'), findsOneWidget);

      await pickMobileServerAction(tester, 'Показать QR');
      final qr = find.byType(QrImageView);
      expect(qr, findsOneWidget);
      expect(find.widgetWithText(AlertDialog, selected.name), findsOneWidget);
      await tester.tap(find.text('Закрыть'));
      await tester.pumpAndSettle();
      expect(qr, findsNothing);
      expect(copied, [source]);
      expect(getVpnMutations(), isEmpty);
    },
  );

  for (final supported in [true, false]) {
    testWidgets(
      'clipboard subscription import updates only its source (supported=$supported)',
      (tester) async {
        const source = 'https://subscription.example.invalid/sub/fixture';
        final old = autoFixture(
          'clipboard-old',
          1443,
          'PL',
        ).copyWith(subscriptionSource: source);
        final restored = autoFixture(
          'clipboard-restored',
          2443,
          'SE',
        ).copyWith(subscriptionSource: source);
        final manual = autoFixture('clipboard-manual', 3443, 'FI');
        final imported = supported
            ? restored
            : restored.copyWith(kind: VpnProfileKind.vlessMkcp);
        final importer = _ScriptedSubscriptionImporter({
          source: () async => [imported],
        });
        final messenger = binding.defaultBinaryMessenger;
        var reads = 0;
        messenger.setMockMethodCallHandler(SystemChannels.platform, (
          call,
        ) async {
          if (call.method == 'Clipboard.getData') {
            reads++;
            return {'text': source};
          }
          return null;
        });
        addTearDown(
          () =>
              messenger.setMockMethodCallHandler(SystemChannels.platform, null),
        );
        await launchWithProfile(
          tester,
          connected: false,
          initialProfile: old,
          extraProfiles: [manual],
          profileImporter: importer,
        );
        final store = ProfileStore();
        await store.rememberDeletedSubscriptionProfile(restored);
        nativeCalls.clear();
        await tester.tap(find.byKey(const ValueKey('mobile-import')));
        await tester.pumpAndSettle();
        expect(reads, 0);
        await tester.tap(
          find.byKey(const ValueKey('mobile-subscription-clipboard')),
        );
        await tester.pumpAndSettle();
        expect(reads, 1);
        expect(importer.sources, [source]);
        final saved = await store.loadProfiles();
        expect(
          saved.map((profile) => profile.id),
          unorderedEquals([supported ? restored.id : old.id, manual.id]),
        );
        expect(
          (await SharedPreferences.getInstance()).getString(
            'selectedProfileId',
          ),
          supported ? restored.id : old.id,
        );
        final tombstones = await store
            .loadDeletedProfileIdsBySubscriptionSource();
        if (supported) {
          expect(tombstones, isEmpty);
        } else {
          expect(tombstones[source], {restored.id});
          expect(find.byType(SnackBar), findsOneWidget);
        }
        expect(getVpnMutations(), isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'mobile QR import makes no changes on cancel and saves the next valid scan',
    (tester) async {
      final scanner = _HomeQrScanner();
      final previous = MobileScannerPlatform.instance;
      MobileScannerPlatform.instance = scanner;
      addTearDown(() async {
        MobileScannerPlatform.instance = previous;
        await scanner.frames.close();
      });
      await launchWithProfile(tester, connected: false);
      final store = ProfileStore();
      final original = (await store.loadProfiles()).single;
      nativeCalls.clear();
      Future<void> openScan() async {
        await tester.tap(find.byKey(const ValueKey('mobile-import')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('mobile-subscription-qr')));
        await tester.pumpAndSettle();
        expect(find.text('Сканировать QR'), findsOneWidget);
      }

      await openScan();
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect((await store.loadProfiles()).single.id, original.id);
      await openScan();
      const source = 'hy2://fixture@127.0.0.1:4443#QRFixture';
      scanner.frames.add(
        const BarcodeCapture(barcodes: [Barcode(rawValue: source)]),
      );
      await tester.pumpAndSettle();
      final saved = await store.loadProfiles();
      expect(saved, hasLength(2));
      final imported = saved.singleWhere(
        (profile) => profile.id != original.id,
      );
      expect(imported.port, 4443);
      expect(imported.originalInput, source);
      expect(
        (await SharedPreferences.getInstance()).getString('selectedProfileId'),
        imported.id,
      );
      expect(find.text('Сканировать QR'), findsNothing);
      expect(getVpnMutations(), isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  for (final connected in [false, true]) {
    testWidgets(
      'deleting an inactive saved profile preserves the selection without touching VPN (connected=$connected)',
      (tester) async {
        final first = autoFixture('keep', 1443, 'PL');
        final second = autoFixture('delete', 2443, 'SE');
        await launchWithProfile(
          tester,
          connected: connected,
          initialProfile: first,
          extraProfiles: [second],
          waitForStopGuard: false,
        );
        await tester.tap(find.byKey(serverPickerKey));
        await tester.pumpAndSettle();
        nativeCalls.clear();
        await pickProfileAction(tester, second, 'Удалить');
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('mobile-server-delete')),
          findsNothing,
        );
        expect(
          find.byKey(const ValueKey('mobile-server-keep')),
          findsOneWidget,
        );
        expect(
          (await SharedPreferences.getInstance()).getString(
            'selectedProfileId',
          ),
          first.id,
        );
        expect((await ProfileStore().loadProfiles()).map((p) => p.id), [
          first.id,
        ]);
        expect(nativeStatus, connected ? 'Started' : 'Stopped');
        expect(getVpnMutations(), isEmpty);
      },
    );
  }

  for (final hasFallback in [false, true]) {
    testWidgets(
      'deleting the active profile waits for native stop before updating selection (fallback=$hasFallback)',
      (tester) async {
        final active = autoFixture(
          'delete-active',
          1443,
          'PL',
        ).copyWith(subscriptionSource: 'https://profiles.example.invalid/sub');
        final fallback = autoFixture('delete-fallback', 2443, 'SE');
        await launchWithProfile(
          tester,
          initialProfile: active,
          extraProfiles: [if (hasFallback) fallback],
          waitForStopGuard: false,
          useTestStatusClock: true,
        );
        final store = ProfileStore();
        final prefs = await SharedPreferences.getInstance();
        final stop = pendingStopAck = Completer<bool>();
        await tester.tap(find.byKey(serverPickerKey));
        await tester.pumpAndSettle();
        nativeCalls.clear();
        await pickProfileAction(tester, active, 'Удалить');
        await pumpUntilNativeCall(tester, 'stopVPN');
        expect(getVpnMutations(), ['stopVPN']);
        expect((await store.loadProfiles()).first.id, active.id);
        expect(prefs.getString('selectedProfileId'), active.id);

        nativeStatus = 'Stopping';
        pendingStopAck = null;
        stop.complete(true);
        await tester.pump(const Duration(milliseconds: 650));
        expect((await store.loadProfiles()).first.id, active.id);
        expect(prefs.getString('selectedProfileId'), active.id);

        nativeStatus = 'Stopped';
        await tester.pump(const Duration(milliseconds: 750));
        await tester.pumpAndSettle();
        expect((await store.loadProfiles()).map((profile) => profile.id), [
          if (hasFallback) fallback.id,
        ]);
        expect(
          prefs.getString('selectedProfileId'),
          hasFallback ? fallback.id : null,
        );
        final deleted = await store.loadDeletedProfileIdsBySubscriptionSource();
        expect(deleted[ProfileStore.subscriptionSourceKeyFor(active)], {
          active.id,
        });
        expect(
          find.byKey(ValueKey('mobile-server-${active.id}')),
          findsNothing,
        );
        expect(getVpnMutations(), ['stopVPN']);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final failure in [
    'stop timed out',
    'already stopping',
    'missing status',
    'stale stopped UI',
    'previous active profile',
  ]) {
    testWidgets(
      'active deletion preserves the profile and selection without a confirmed stop ($failure)',
      (tester) async {
        final active = autoFixture(
          'delete-without-stop',
          1443,
          'PL',
        ).copyWith(subscriptionSource: 'https://profiles.example.invalid/stop');
        final next = await xhttpFixture();
        final initiallyRunning =
            failure != 'already stopping' && failure != 'stale stopped UI';
        await launchWithProfile(
          tester,
          connected: initiallyRunning,
          initialNativeStatus: failure == 'already stopping'
              ? 'Stopping'
              : null,
          initialProfile: active,
          extraProfiles: [next],
          waitForStopGuard: false,
          useTestStatusClock: true,
        );
        final store = ProfileStore();
        final prefs = await SharedPreferences.getInstance();
        Future<void> expectPreserved() async {
          expect((await store.loadProfiles()).map((p) => p.id), [
            active.id,
            next.id,
          ]);
          expect(prefs.getString('selectedProfileId'), active.id);
          expect(
            await store.loadDeletedProfileIdsBySubscriptionSource(),
            isEmpty,
          );
          expect(
            find.byKey(ValueKey('mobile-server-${active.id}')),
            findsOneWidget,
          );
        }

        if (failure == 'stale stopped UI') nativeStatus = 'Started';
        if (failure == 'previous active profile') {
          // The UI selected the next profile, but this failed switch didn't
          // install its config or replace the previously committed selection.
          final switchStop = pendingStopAck = Completer<bool>();
          nativeCalls.clear();
          await chooseServer(tester, next);
          await pumpUntilNativeCall(tester, 'stopVPN');
          pendingStopAck = null;
          switchStop.completeError(
            PlatformException(code: 'DISPATCH_REJECTED'),
          );
          await tester.pumpAndSettle();
          expect(getVpnMutations(), ['stopVPN']);
          expect(nativeStatus, 'Started');
          expect(prefs.getString('selectedProfileId'), active.id);
        }

        await tester.tap(find.byKey(serverPickerKey));
        await tester.pumpAndSettle();
        nativeCalls.clear();
        final stop = pendingStopAck = Completer<bool>();
        await pickProfileAction(tester, active, 'Удалить');
        await pumpUntilNativeCall(tester, 'stopVPN');
        expect(getVpnMutations(), ['stopVPN']);
        await expectPreserved();

        // The method reply acknowledges the request, not the service exit.
        nativeStatus = 'Stopping';
        nativeStatusMissing = failure == 'missing status';
        pendingStopAck = null;
        stop.complete(true);
        await tester.pump(const Duration(milliseconds: 750));
        await expectPreserved();
        await tester.pump(const Duration(seconds: 36));
        await tester.pumpAndSettle();
        await expectPreserved();
        expect(
          find.textContaining('VPN не успел полностью остановиться'),
          findsOneWidget,
        );
        expect(getVpnMutations(), ['stopVPN']);

        nativeStatusMissing = false;
        nativeStatus = 'Stopped';
        platform.status.add({'status': 'Stopped'});
        await tester.pump();
        await expectPreserved();
        await pickProfileAction(tester, active, 'Удалить');
        await tester.pumpAndSettle();
        expect((await store.loadProfiles()).map((p) => p.id), [next.id]);
        expect(prefs.getString('selectedProfileId'), next.id);
        expect(
          (await store.loadDeletedProfileIdsBySubscriptionSource())
              .values
              .single,
          {active.id},
        );
        expect(getVpnMutations(), ['stopVPN']);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final connected in [false, true]) {
    testWidgets(
      'raw JSON import cannot replace a supported profile or disturb VPN (connected=$connected)',
      (tester) async {
        final profile = autoFixture('keep-supported-profile', 1443, 'PL');
        await launchWithProfile(
          tester,
          connected: connected,
          initialProfile: profile,
          waitForStopGuard: false,
        );
        final store = ProfileStore();
        final before = (await store.loadProfiles())
            .map((p) => p.toJson())
            .toList();
        final prefs = await SharedPreferences.getInstance();
        nativeCalls.clear();
        await tester.tap(find.byKey(const ValueKey('mobile-import')));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const ValueKey('mobile-subscription-input')),
          '{"inbounds":[],"outbounds":[]}',
        );
        await tester.pump();
        await tester.tap(
          find.byKey(const ValueKey('mobile-subscription-submit')),
        );
        await tester.pumpAndSettle();

        expect(
          find.textContaining('В этой сборке запускаются Reality, NaiveProxy'),
          findsWidgets,
        );
        expect(
          (await store.loadProfiles()).map((p) => p.toJson()).toList(),
          before,
        );
        expect(prefs.getString('selectedProfileId'), profile.id);
        expect(nativeStatus, connected ? 'Started' : 'Stopped');
        expect(
          find.byKey(activeServerKey),
          connected ? findsOneWidget : findsNothing,
        );
        expect(nativeConfigs, isEmpty);
        expect(getVpnMutations(), isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final hasReplacement in [false, true]) {
    testWidgets(
      'manual consent uses the refreshed subscription snapshot (replacement=$hasReplacement)',
      (tester) async {
        const source = 'https://profiles.example.invalid/consent-refresh';
        final old = autoFixture(
          'consent-retired',
          1443,
          'PL',
        ).copyWith(subscriptionSource: source);
        final replacement = autoFixture(
          'consent-replacement',
          3443,
          'FI',
        ).copyWith(subscriptionSource: source);
        final batch = Completer<List<VpnProfile>>();
        final importer = _ScriptedSubscriptionImporter({
          source: () => batch.future,
        });
        await launchWithProfile(
          tester,
          connected: false,
          initialProfile: old,
          profileImporter: importer,
          preferences: const {'automaticProfileSelection': false},
        );
        final store = ProfileStore();
        if (!hasReplacement) {
          // A previously deleted server must not reappear on refresh.
          // Once the subscription also retires the last visible server,
          // the reconciled list is genuinely empty.
          await store.rememberDeletedSubscriptionProfile(replacement);
        }
        nativeCalls.clear();
        await refreshSubscriptionsFromServerList(tester);
        expect(importer.sources, [source]);
        await tester.tap(find.byKey(const ValueKey('mobile-home-tab')));
        await tester.pump(const Duration(milliseconds: 450));
        await tester.tap(find.byKey(powerKey));
        // The subscription spinner intentionally keeps animating while its
        // response is held; wait only for the disclosure dialog transition.
        await tester.pump(const Duration(milliseconds: 350));
        expect(find.text('Защита трафика через VPN'), findsOneWidget);
        expect(getVpnMutations(), isEmpty);

        batch.complete([replacement]);
        await tester.pumpAndSettle();
        expect((await store.loadProfiles()).map((profile) => profile.id), [
          if (hasReplacement) replacement.id,
        ]);
        expect(getVpnMutations(), isEmpty);
        if (hasReplacement) scriptedStarts.add(true);
        await tester.tap(find.widgetWithText(FilledButton, 'Принимаю'));
        await tester.pumpAndSettle();
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getInt('vpnDisclosureVersion'), 1);

        if (hasReplacement) {
          await pumpUntilNativeCall(tester, 'startVPN');
          await tester.pump(const Duration(seconds: 2));
          expect(getVpnMutations(), ['saveConfig', 'startVPN']);
          expect(nativeConfigs, hasLength(1));
          expect(nativeConfigs.single, contains('"server_port":3443'));
          expect(nativeConfigs.single, isNot(contains('"server_port":1443')));
          expect(prefs.getString('selectedProfileId'), replacement.id);
          expect(find.byKey(activeServerKey), findsOneWidget);
        } else {
          expect(find.text('Сначала импортируй профиль.'), findsOneWidget);
          expect(prefs.getString('selectedProfileId'), isNull);
          expect(find.byKey(activeServerKey), findsNothing);
          expect(getVpnMutations(), isEmpty);
          expect(nativeStatus, 'Stopped');
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final replacementOffline in [true, false]) {
    testWidgets(
      'retry after a failed refreshed profile respects replacement offline marking (offline=$replacementOffline)',
      (tester) async {
        const source = 'https://profiles.example.invalid/start-refresh';
        final old = (await xhttpFixture()).copyWith(subscriptionSource: source);
        final replacement = autoFixture('retry-replacement', 3443, 'FI')
            .copyWith(
              name: replacementOffline
                  ? 'Fixture offline'
                  : 'Fixture available',
              subscriptionSource: source,
            );
        final batch = Completer<List<VpnProfile>>();
        final importer = _ScriptedSubscriptionImporter({
          source: () => batch.future,
        });
        await launchWithProfile(
          tester,
          connected: false,
          initialProfile: old,
          profileImporter: importer,
          preferences: const {
            'automaticProfileSelection': false,
            'vpnDisclosureVersion': 1,
          },
        );
        nativeCalls.clear();
        await refreshSubscriptionsFromServerList(tester);
        expect(importer.sources, [source]);
        await tester.tap(find.byKey(const ValueKey('mobile-home-tab')));
        await tester.pump(const Duration(milliseconds: 450));
        final configAck = pendingConfigAck = Completer<bool>();
        rejectNativeStart = true;
        await tester.tap(find.byKey(powerKey));
        await pumpUntilNativeCall(tester, 'saveConfig');
        expect(getVpnMutations(), ['saveConfig']);

        // Refresh completes after the old configuration was dispatched,
        // but before Android acknowledges it. No State fields are injected.
        batch.complete([replacement]);
        await tester.pump(const Duration(milliseconds: 350));
        expect((await ProfileStore().loadProfiles()).map((p) => p.id), [
          replacement.id,
        ]);
        pendingConfigAck = null;
        configAck.complete(true);
        for (var frame = 0; frame < 14; frame++) {
          await tester.pump(const Duration(milliseconds: 500));
        }
        await tester.pumpAndSettle();
        expect(nativeStatus, 'Stopped');
        expect(find.byKey(activeServerKey), findsNothing);
        expect(find.byTooltip('Подключить VPN'), findsOneWidget);
        expect(
          getVpnMutations(),
          containsAllInOrder(['saveConfig', 'startVPN', 'stopVPN']),
        );
        expect(getVpnMutations().last, 'stopVPN');
        expect(nativeConfigs, isNotEmpty);
        for (final config in nativeConfigs) {
          final runtime = jsonDecode(config) as Map<String, dynamic>;
          expect(runtime['_yurich']['core'], 'xray');
          final proxy = (runtime['xray']['outbounds'] as List)
              .cast<Map<String, dynamic>>()
              .singleWhere((outbound) => outbound['tag'] == 'proxy');
          expect((proxy['settings']['vnext'] as List).single['port'], 2443);
        }
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getString('selectedProfileId'), replacement.id);

        nativeCalls.clear();
        nativeConfigs.clear();
        rejectNativeStart = false;
        if (!replacementOffline) scriptedStarts.add(true);
        await tester.tap(find.byKey(powerKey));
        await tester.pumpAndSettle();
        if (replacementOffline) {
          expect(
            find.textContaining('Для авто-подключения нужен рабочий'),
            findsOneWidget,
          );
          expect(getVpnMutations(), isEmpty);
          expect(nativeConfigs, isEmpty);
          expect(nativeStatus, 'Stopped');
          expect(find.byKey(activeServerKey), findsNothing);
        } else {
          await pumpUntilNativeCall(tester, 'startVPN');
          await tester.pump(const Duration(seconds: 2));
          expect(getVpnMutations(), ['saveConfig', 'startVPN']);
          expect(nativeConfigs, hasLength(1));
          expect(nativeConfigs.single, contains('"server_port":3443'));
          expect(nativeConfigs.single, isNot(contains('"server_port":2443')));
          expect(nativeStatus, 'Started');
          expect(find.byKey(activeServerKey), findsOneWidget);
        }
        expect(prefs.getString('selectedProfileId'), replacement.id);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'Auto cannot start a stale profile while its subscription update is pending',
    (tester) async {
      const source = 'https://profiles.example.invalid/pending-refresh';
      final old = autoFixture(
        'changing-subscription',
        1443,
        'PL',
      ).copyWith(subscriptionSource: source);
      final replacement = autoFixture(
        old.id,
        2443,
        'PL',
      ).copyWith(subscriptionSource: source);
      final batch = Completer<List<VpnProfile>>();
      final importer = _ScriptedSubscriptionImporter({
        source: () => batch.future,
      });
      await launchWithProfile(
        tester,
        connected: false,
        initialProfile: old,
        profileImporter: importer,
        preferences: const {
          'automaticProfileSelection': true,
          'directLatencyAllowed': false,
          'vpnDisclosureVersion': 1,
        },
      );
      final store = ProfileStore();
      nativeCalls.clear();
      await refreshSubscriptionsFromServerList(tester);
      expect(importer.sources, [source]);
      await tester.tap(find.byKey(const ValueKey('mobile-home-tab')));
      await tester.pump(const Duration(milliseconds: 450));
      await tester.tap(find.byKey(powerKey));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Обновляю подписки...'), findsWidgets);
      expect((await store.loadProfiles()).single.port, 1443);
      expect(getVpnMutations(), isEmpty);

      batch.complete([replacement]);
      await tester.pumpAndSettle();
      expect((await store.loadProfiles()).single.port, 2443);
      expect(getVpnMutations(), isEmpty);
      scriptedStarts.add(true);
      await tester.tap(find.byKey(powerKey));
      await pumpUntilNativeCall(tester, 'startVPN');
      await tester.pump(const Duration(seconds: 2));
      expect(nativeConfigs.single, contains('"server_port":2443'));
      expect(getVpnMutations(), ['saveConfig', 'startVPN']);
      expect(find.byKey(activeServerKey), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  for (final english in [false, true]) {
    testWidgets(
      'subscription reminders group sources and server details explain valid checks (english=$english)',
      (tester) async {
        const sameSource = 'https://profiles.example.invalid/renew-shared';
        const otherSource = 'https://profiles.example.invalid/renew-other';
        final now = DateTime.now().toUtc();
        final expired = autoFixture('expired-plan', 1443, 'PL').copyWith(
          subscriptionSource: sameSource,
          subscriptionExpiresAt: now.subtract(const Duration(hours: 1)),
        );
        final hours = autoFixture('hours-left', 2443, 'SE').copyWith(
          subscriptionSource: otherSource,
          subscriptionExpiresAt: now.add(const Duration(hours: 6, minutes: 30)),
        );
        final days = autoFixture('days-left', 3443, 'FI').copyWith(
          subscriptionSource: sameSource,
          subscriptionExpiresAt: now.add(const Duration(hours: 54)),
        );
        appNotificationAllowed = english;
        await launchWithProfile(
          tester,
          connected: false,
          initialProfile: expired,
          extraProfiles: [hours, days],
          viewport: const Size(380, 1100),
          preferences: {'languageCode': english ? 'en' : 'ru'},
        );
        final notice = appNotifications.singleWhere(
          (item) => item['id'] == 7039,
        );
        expect(
          notice['body'],
          contains(
            english
                ? '2 subscriptions need attention'
                : '2 подписки требуют внимания',
          ),
        );
        expect(notice['body'], contains(english ? 'Expired' : 'Истекла'));
        final store = ProfileStore();
        expect(
          await store.loadSubscriptionReminderStamp(),
          endsWith(expired.subscriptionExpiresAt!.toIso8601String()),
        );

        await tester.tap(find.byKey(serverPickerKey));
        await tester.pumpAndSettle();
        final close = english ? 'Close' : 'Закрыть';
        for (final (profile, status) in [
          (expired, english ? 'Expired' : 'Истекла'),
          (hours, english ? '6 h left' : 'Осталось 6 ч'),
          (days, english ? '3 d left' : 'Осталось 3 дн.'),
        ]) {
          await pickProfileAction(
            tester,
            profile,
            english ? 'Details' : 'Подробнее',
          );
          await tester.pumpAndSettle();
          final dialog = find.byType(AlertDialog);
          expect(dialog, findsOneWidget);
          expect(
            find.descendant(
              of: dialog,
              matching: find.text(
                '${english ? 'Subscription' : 'Подписка'}: $status',
              ),
            ),
            findsOneWidget,
          );
          expect(
            find.descendant(
              of: dialog,
              matching: find.textContaining('NaiveProxy'),
            ),
            findsOneWidget,
          );
          await tester.tap(find.text(close));
          await tester.pumpAndSettle();
        }
        await pickMobileServerAction(
          tester,
          english ? 'About latency' : 'О проверке пинга',
        );
        expect(
          find.textContaining(
            english
                ? 'This is not a VPN login test'
                : 'Это не проверка входа в VPN',
          ),
          findsOneWidget,
        );
        expect(
          find.textContaining(
            english
                ? 'through the current VPN, not directly'
                : 'через текущий VPN, не напрямую',
          ),
          findsOneWidget,
        );
        await tester.tap(find.text(close));
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsNothing);
        expect(nativeCalls, isNot(contains('getDirectProbeNetwork')));
        expect(getVpnMutations(), isEmpty);

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        appNotifications.clear();
        await tester.pumpWidget(const YurichConnectApp());
        for (var frame = 0; frame < 12; frame++) {
          await tester.pump(const Duration(milliseconds: 250));
        }
        expect(appNotifications.where((item) => item['id'] == 7039), isEmpty);
        expect(getVpnMutations(), isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'subscription renewal stays visible when the Android notification fails',
    (tester) async {
      final expiresAt = DateTime.now().toUtc().subtract(
        const Duration(hours: 1),
      );
      final expired = autoFixture('expired-reminder', 1443, 'PL').copyWith(
        subscriptionSource: 'https://profiles.example.invalid/reminder',
        subscriptionExpiresAt: expiresAt,
      );
      appNotificationError = PlatformException(
        code: 'FIXTURE_NOTIFICATION_FAILURE',
      );
      await launchWithProfile(
        tester,
        connected: false,
        initialProfile: expired,
        bootstrapFrames: 5,
      );

      final notice = appNotifications.singleWhere((item) => item['id'] == 7039);
      final body = notice['body']! as String;
      expect(body, contains('Истекла'));
      expect(find.text(body), findsOneWidget);
      expect(
        await ProfileStore().loadSubscriptionReminderStamp(),
        endsWith(expiresAt.toIso8601String()),
      );
      expect(getVpnMutations(), isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 2));
    },
  );

  testWidgets(
    'six-hour reminder does not repeat the same subscription notification',
    (tester) async {
      final profile = autoFixture('renewal-periodic', 1443, 'PL').copyWith(
        subscriptionSource: 'https://profiles.example.invalid/periodic',
        subscriptionExpiresAt: DateTime.now().toUtc().add(
          const Duration(hours: 5),
        ),
      );
      await launchWithProfile(
        tester,
        connected: false,
        initialProfile: profile,
      );
      expect(appNotifications, hasLength(1));
      expect(appNotifications.single['id'], 7039);
      final stamp = await ProfileStore().loadSubscriptionReminderStamp();
      expect(stamp, isNotNull);
      nativeCalls.clear();
      binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      // Advancing the scheduler invokes the six-hour timer; the persisted
      // stamp still belongs to the same real calendar day and subscription.
      await tester.pump(const Duration(hours: 6));
      await tester.pump();
      expect(appNotifications, hasLength(1));
      expect(await ProfileStore().loadSubscriptionReminderStamp(), stamp);
      expect(nativeCalls, isNot(contains('requestNotificationPermission')));
      expect(getVpnMutations(), isEmpty);
      expect((await ProfileStore().loadProfiles()).single.id, profile.id);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'refreshing without subscriptions opens import and does not alter VPN',
    (tester) async {
      final importer = _ScriptedSubscriptionImporter({});
      await launchWithProfile(
        tester,
        connected: false,
        profileImporter: importer,
      );
      nativeCalls.clear();
      await refreshSubscriptionsFromServerList(tester);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('mobile-subscription-dialog')),
        findsOneWidget,
      );
      expect(importer.sources, isEmpty);
      expect(getVpnMutations(), isEmpty);
    },
  );

  for (final partial in [true, false]) {
    testWidgets(
      'subscription refresh preserves failed sources and local choices (partial=$partial)',
      (tester) async {
        const failedSource =
            'https://bad.example.invalid/sub/fixture-private-path';
        const goodSource = 'https://good.example.invalid/sub/public-fixture';
        final failedProfile = autoFixture(
          'unchanged',
          1443,
          'PL',
        ).copyWith(subscriptionSource: failedSource);
        final oldGood = autoFixture(
          'old-good',
          2443,
          'FI',
        ).copyWith(subscriptionSource: goodSource, countryName: 'Finland');
        final newGood = autoFixture(
          'new-good',
          2443,
          'FI',
        ).copyWith(subscriptionSource: goodSource);
        final deleted = autoFixture(
          'removed',
          3443,
          'DE',
        ).copyWith(subscriptionSource: goodSource);
        final manual = autoFixture('manual', 4443, 'SE');
        final goodResult = Completer<List<VpnProfile>>();
        final importer = _ScriptedSubscriptionImporter({
          failedSource: () async => throw const ProfileImportException(
            'network error Bearer fixture-private-bearer',
          ),
          goodSource: () => goodResult.future,
        });
        await launchWithProfile(
          tester,
          initialProfile: failedProfile,
          extraProfiles: [oldGood, manual],
          profileImporter: importer,
          waitForStopGuard: false,
        );
        final store = ProfileStore();
        await store.rememberDeletedSubscriptionProfile(deleted);
        nativeCalls.clear();
        if (partial) {
          await tester.tap(find.byTooltip('Обновить подписки'));
          await tester.pump();
        } else {
          await refreshSubscriptionsFromServerList(tester);
        }
        expect(importer.sources, [failedSource, goodSource]);
        expect((await store.loadProfiles()).map((p) => p.id), [
          failedProfile.id,
          oldGood.id,
          manual.id,
        ]);
        if (partial) {
          goodResult.complete([newGood, deleted]);
        } else {
          goodResult.completeError(
            const ProfileImportException(
              'cannot load repository Bearer fixture-private-bearer',
            ),
          );
        }
        await tester.pumpAndSettle();
        final profiles = await store.loadProfiles();
        final byId = {for (final profile in profiles) profile.id: profile};
        expect(
          byId.keys,
          unorderedEquals([
            failedProfile.id,
            (partial ? newGood : oldGood).id,
            manual.id,
          ]),
        );
        expect(byId[failedProfile.id]!.toJson(), failedProfile.toJson());
        expect(byId[manual.id]!.toJson(), manual.toJson());
        expect(byId[(partial ? newGood : oldGood).id]!.countryName, 'Finland');
        expect(
          (await SharedPreferences.getInstance()).getString(
            'selectedProfileId',
          ),
          failedProfile.id,
        );
        expect(nativeStatus, 'Started');
        expect(getVpnMutations(), isEmpty);
        if (partial) {
          expect(find.text('Подписки обновлены: 1 профилей'), findsWidgets);
        } else {
          expect(
            find.textContaining('Обновление подписок не удалось:'),
            findsWidgets,
          );
          expect(find.textContaining('Bearer ***'), findsWidgets);
        }
        expect(find.textContaining('fixture-private-bearer'), findsNothing);
        expect(find.textContaining('fixture-private-path'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final rotateActive in [false, true]) {
    testWidgets(
      'automatic subscription refresh after two hours in background preserves the live runtime (rotated=$rotateActive)',
      (tester) async {
        const source = 'https://profiles.example.invalid/automatic';
        final active = (await ProfileImporter().importFromText(
          'vless://11111111-1111-4111-8111-111111111111@127.0.0.1:1443'
          '?security=tls&type=tcp&sni=fixture.invalid#Fixture',
        )).single.copyWith(countryCode: 'PL', subscriptionSource: source);
        final oldServer = autoFixture(
          'old-peer',
          2443,
          'SE',
        ).copyWith(subscriptionSource: source);
        final newServer = autoFixture(
          'new-peer',
          3443,
          'FI',
        ).copyWith(subscriptionSource: source);
        final changed = active.copyWith(
          port: 4443,
          outbound: {...active.outbound!, 'server_port': 4443},
        );
        final importer = _ScriptedSubscriptionImporter({
          source: () async => [newServer, if (rotateActive) changed],
        });
        restoredNativeConfig = SingBoxConfigBuilder().build(active);
        final now = tester.binding.clock.now;
        await launchWithProfile(
          tester,
          initialProfile: active,
          extraProfiles: [oldServer],
          profileImporter: importer,
          subscriptionRefreshNow: now,
          preferences: const {'smartRouteRuDirect': false},
          waitForStopGuard: false,
        );
        expect(importer.sources, isEmpty);
        expect(getVpnMutations(), isEmpty);
        final store = ProfileStore();
        final due = (await store.loadNextSubscriptionRefreshAt())!;
        expect(
          due.difference(now()),
          greaterThan(const Duration(minutes: 119)),
        );
        expect(
          due.difference(now()),
          lessThanOrEqualTo(const Duration(hours: 2)),
        );
        nativeCalls.clear();

        // Simulate an Android process that is still executing while the UI is
        // in the background. Only virtual time advances.
        binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        await tester.pump(
          due.difference(now()) - const Duration(milliseconds: 1),
        );
        expect(importer.sources, isEmpty);
        await tester.pump(const Duration(milliseconds: 1));
        await tester.pump();
        expect(importer.sources, [source]);
        expect(importer.tunnelOnly, [true]);
        expect(
          await store.loadNextSubscriptionRefreshAt(),
          due.add(const Duration(hours: 2)),
        );
        final byId = {
          for (final profile in await store.loadProfiles()) profile.id: profile,
        };
        expect(byId.keys, unorderedEquals([active.id, newServer.id]));
        expect(byId[active.id]!.toJson(), active.toJson());
        expect(await store.loadSelectedProfileId(), active.id);
        expect(getVpnMutations(), isEmpty);
        expect(nativeCalls, isNot(contains('getDirectProbeNetwork')));

        binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        await tester.pumpAndSettle();
        expect(importer.sources, [source]);
        expect(find.byKey(activeServerKey), findsOneWidget);
        expect(find.byType(SnackBar), findsNothing);
        if (rotateActive) {
          // Re-open over the same storage and still-running native tunnel.
          // The restored config must match the saved profile, not trigger a
          // reload with the rotated credentials or endpoint.
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump(const Duration(seconds: 10));
          nativeCalls.clear();
          await tester.pumpWidget(
            MaterialApp(
              theme: YurichTheme.dark(),
              home: HomeScreen(
                profileImporter: importer,
                subscriptionRefreshNow: now,
              ),
            ),
          );
          for (var frame = 0; frame < 12; frame++) {
            await tester.pump(const Duration(milliseconds: 250));
          }
          expect(nativeCalls, contains('getConfig'));
          expect(getVpnMutations(), isEmpty);
          expect(find.byKey(activeServerKey), findsOneWidget);
          expect(await store.loadSelectedProfileId(), active.id);
          expect(importer.sources, [source]);
        } else {
          final stopped = pendingStopAck = Completer<bool>();
          await tester.tap(find.byKey(powerKey));
          await pumpUntilNativeCall(tester, 'stopVPN');
          nativeStatus = 'Stopped';
          pendingStopAck = null;
          stopped.complete(true);
          await tester.pump(const Duration(milliseconds: 400));
          await tester.pumpAndSettle();
          binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
          await tester.pump(
            due.add(const Duration(hours: 2)).difference(now()),
          );
          await tester.pump();
          expect(importer.sources, [source, source]);
          expect(importer.tunnelOnly, [true, false]);
          expect((await store.loadProfiles()).single.id, newServer.id);
          expect(await store.loadSelectedProfileId(), newServer.id);
          expect(getVpnMutations(), ['stopVPN']);
          binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(seconds: 10));
      },
    );
  }

  testWidgets(
    'automatic subscription refresh migrates a legacy six-hour deadline',
    (tester) async {
      const source = 'https://profiles.example.invalid/legacy-deadline';
      final profile = autoFixture(
        'legacy-schedule',
        1443,
        'PL',
      ).copyWith(subscriptionSource: source);
      final importer = _ScriptedSubscriptionImporter({
        source: () async => [profile],
      });
      var now = DateTime.utc(2026, 11, 17, 10);
      final previousDeadline = now.add(const Duration(hours: 6));

      await launchWithProfile(
        tester,
        connected: false,
        initialProfile: profile,
        profileImporter: importer,
        subscriptionRefreshNow: () => now,
        preferences: {
          'nextSubscriptionRefreshAt': previousDeadline.toIso8601String(),
        },
      );
      final store = ProfileStore();
      final due = now.add(const Duration(hours: 2));
      expect(await store.loadNextSubscriptionRefreshAt(), due);
      expect(importer.sources, isEmpty);
      nativeCalls.clear();

      binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      now = due;
      await tester.pump(const Duration(hours: 2));
      await tester.pump();
      expect(importer.sources, [source]);
      expect(importer.tunnelOnly, [false]);
      expect(
        await store.loadNextSubscriptionRefreshAt(),
        due.add(const Duration(hours: 2)),
      );
      expect(getVpnMutations(), isEmpty);

      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 2));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'automatic subscription refresh catches up once after resume using the saved deadline',
    (tester) async {
      const source = 'https://profiles.example.invalid/resume';
      final oldProfile = autoFixture(
        'old',
        1443,
        'PL',
      ).copyWith(subscriptionSource: source);
      final newProfile = autoFixture(
        'new',
        2443,
        'SE',
      ).copyWith(subscriptionSource: source);
      final response = Completer<List<VpnProfile>>();
      final importer = _ScriptedSubscriptionImporter({
        source: () => response.future,
      });
      var now = DateTime.utc(2026, 1, 1, 12);
      final due = now.add(const Duration(hours: 1));
      await launchWithProfile(
        tester,
        connected: false,
        initialProfile: oldProfile,
        profileImporter: importer,
        subscriptionRefreshNow: () => now,
        preferences: {'nextSubscriptionRefreshAt': due.toIso8601String()},
      );
      final store = ProfileStore();
      expect(await store.loadNextSubscriptionRefreshAt(), due);
      nativeCalls.clear();
      binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      // The wall clock passed several intervals without Dart timer delivery.
      now = now.add(const Duration(hours: 23));
      await tester.pump(const Duration(milliseconds: 100));
      expect(importer.sources, isEmpty);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump(const Duration(milliseconds: 1));
      await tester.pump();
      expect(importer.sources, [source]);
      expect(importer.tunnelOnly, [false]);

      await refreshSubscriptionsFromServerList(tester);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(importer.sources, [source]);
      response.complete([newProfile]);
      await tester.pumpAndSettle();
      expect((await store.loadProfiles()).single.id, newProfile.id);
      expect(await store.loadSelectedProfileId(), newProfile.id);
      expect(
        await store.loadNextSubscriptionRefreshAt(),
        now.add(const Duration(hours: 2)),
      );
      expect(getVpnMutations(), isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 10));
    },
  );

  for (final partial in [false, true]) {
    testWidgets(
      'automatic subscription refresh contains failed sources and honors deletions (partial=$partial)',
      (tester) async {
        const bad = 'https://profiles.example.invalid/fixture-private-source';
        const good = 'https://profiles.example.invalid/good';
        final active = autoFixture(
          'active',
          1443,
          'PL',
        ).copyWith(subscriptionSource: bad);
        final old = autoFixture(
          'old',
          2443,
          'FI',
        ).copyWith(subscriptionSource: good);
        final replacement = autoFixture(
          'updated',
          3443,
          'SE',
        ).copyWith(subscriptionSource: good);
        final deleted = autoFixture(
          'deleted',
          4443,
          'DE',
        ).copyWith(subscriptionSource: good);
        final response = Completer<List<VpnProfile>>();
        final importer = _ScriptedSubscriptionImporter({
          bad: () async => throw const ProfileImportException(
            'response contained fixture-private-token',
          ),
          good: () => response.future,
        });
        const raw = VpnProfile(
          id: 'saved-raw',
          name: 'Stored raw fixture',
          kind: VpnProfileKind.singBoxConfig,
          originalInput: '',
        );
        final now = tester.binding.clock.now;
        final due = now().add(const Duration(seconds: 5));
        await launchWithProfile(
          tester,
          initialProfile: active,
          extraProfiles: [old, raw],
          profileImporter: importer,
          subscriptionRefreshNow: now,
          viewport: const Size(380, 1200),
          preferences: {'nextSubscriptionRefreshAt': due.toIso8601String()},
          waitForStopGuard: false,
        );
        final store = ProfileStore();
        await store.rememberDeletedSubscriptionProfile(deleted);
        nativeCalls.clear();
        final drafts = interceptExternalLinks();
        await tester.pump(due.difference(now()));
        await tester.pump();
        expect(importer.sources, [bad, good]);
        if (partial) {
          response.complete([replacement, deleted]);
        } else {
          response.completeError(
            const ProfileImportException('fixture offline'),
          );
        }
        await tester.pumpAndSettle();
        expect(
          (await store.loadProfiles()).map((profile) => profile.id),
          unorderedEquals([
            active.id,
            partial ? replacement.id : old.id,
            raw.id,
          ]),
        );
        expect(await store.loadSelectedProfileId(), active.id);
        expect(find.byType(SnackBar), findsNothing);
        expect(find.byKey(activeServerKey), findsOneWidget);
        expect(getVpnMutations(), isEmpty);
        await openSupportReport(tester);
        await tester.pumpAndSettle();
        final report = drafts.single.queryParameters['body']!;
        expect(report, contains('Automatic subscription refresh:'));
        expect(report, isNot(contains('fixture-private-source')));
        expect(report, isNot(contains('fixture-private-token')));
        binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        await tester.pump(const Duration(seconds: 1));
        expect(importer.sources, [bad, good]);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(seconds: 10));
      },
    );
  }

  for (final disposeDuringFetch in [false, true]) {
    testWidgets(
      'automatic subscription refresh discards a superseded fetch (dispose=$disposeDuringFetch)',
      (tester) async {
        const source = 'https://profiles.example.invalid/pending';
        const otherSource = 'https://profiles.example.invalid/never-requested';
        final old = autoFixture(
          'active',
          1443,
          'PL',
        ).copyWith(subscriptionSource: source);
        final other = autoFixture(
          'other',
          2443,
          'SE',
        ).copyWith(subscriptionSource: otherSource);
        final fresh = old.copyWith(port: 3443);
        final response = Completer<List<VpnProfile>>();
        final importer = _ScriptedSubscriptionImporter({
          source: () => response.future,
        });
        final now = tester.binding.clock.now;
        await launchWithProfile(
          tester,
          initialProfile: old,
          extraProfiles: [other],
          profileImporter: importer,
          subscriptionRefreshNow: now,
          preferences: {'nextSubscriptionRefreshAt': now().toIso8601String()},
          waitForStopGuard: false,
        );
        expect(importer.sources, [source]);
        nativeCalls.clear();
        if (disposeDuringFetch) {
          await tester.pumpWidget(const SizedBox.shrink());
        } else {
          final stopAck = pendingStopAck = Completer<bool>();
          await tester.tap(find.byKey(powerKey));
          await pumpUntilNativeCall(tester, 'stopVPN');
          nativeStatus = 'Stopped';
          pendingStopAck = null;
          stopAck.complete(true);
          await tester.pump(const Duration(milliseconds: 400));
          await chooseServer(tester, other);
          await tester.pumpAndSettle();
        }
        response.complete([fresh]);
        await tester.pumpAndSettle();
        final store = ProfileStore();
        expect(
          (await store.loadProfiles()).map((profile) => profile.toJson()),
          [old.toJson(), other.toJson()],
        );
        expect(
          await store.loadSelectedProfileId(),
          disposeDuringFetch ? old.id : other.id,
        );
        expect(importer.sources, [source]);
        expect(getVpnMutations(), [if (!disposeDuringFetch) 'stopVPN']);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'automatic subscription refresh does not queue Stop behind a catalog write',
    (tester) async {
      const source = 'https://profiles.example.invalid/saving';
      final active = autoFixture(
        'active',
        1443,
        'PL',
      ).copyWith(subscriptionSource: source);
      final next = autoFixture('next', 2443, 'SE');
      final fresh = autoFixture(
        'fresh',
        3443,
        'FI',
      ).copyWith(subscriptionSource: source);
      final importer = _ScriptedSubscriptionImporter({
        source: () async => [fresh],
      });
      final now = tester.binding.clock.now;
      final due = now().add(const Duration(seconds: 5));
      await launchWithProfile(
        tester,
        initialProfile: active,
        extraProfiles: [next],
        profileImporter: importer,
        subscriptionRefreshNow: now,
        preferences: {'nextSubscriptionRefreshAt': due.toIso8601String()},
        waitForStopGuard: false,
      );
      final previous = FlutterSecureStoragePlatform.instance;
      final storage = _GatedSubscriptionProfileStore(
        Map.of(await previous.readAll(options: const {})),
      );
      FlutterSecureStoragePlatform.instance = storage;
      addTearDown(() => FlutterSecureStoragePlatform.instance = previous);
      nativeCalls.clear();
      await tester.pump(due.difference(now()));
      await tester.pump();
      expect(storage.writes, 1);
      expect(storage.commit.isCompleted, isFalse);
      final ack = pendingStopAck = Completer<bool>();
      await tester.tap(find.byKey(powerKey));
      await pumpUntilNativeCall(tester, 'stopVPN');
      expect(storage.commit.isCompleted, isFalse);
      nativeStatus = 'Stopped';
      pendingStopAck = null;
      ack.complete(true);
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(find.byKey(activeServerKey), findsNothing);
      await chooseServer(tester, next);
      final store = ProfileStore();
      expect(await store.loadSelectedProfileId(), active.id);

      storage.commit.complete();
      await tester.pumpAndSettle();
      expect(await store.loadSelectedProfileId(), next.id);
      expect(
        (await store.loadProfiles()).map((profile) => profile.id),
        unorderedEquals([active.id, next.id, fresh.id]),
      );
      expect(getVpnMutations(), ['stopVPN']);
      expect(find.byKey(activeServerKey), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  for (final scenario in [
    (name: 'commit completes', stop: false, dispose: false),
    (name: 'newer Stop', stop: true, dispose: false),
    (name: 'screen disposed', stop: false, dispose: true),
  ]) {
    testWidgets(
      'profile deletion during automatic subscription save: ${scenario.name}',
      (tester) async {
        const source = 'https://profiles.example.invalid/deferred-deletion';
        final active = autoFixture(
          'active',
          1443,
          'PL',
        ).copyWith(subscriptionSource: source);
        final peer = autoFixture(
          'delete-peer',
          2443,
          'SE',
        ).copyWith(subscriptionSource: source);
        final refreshedPeer = autoFixture(
          peer.id,
          3443,
          'SE',
        ).copyWith(subscriptionSource: source);
        final fresh = autoFixture(
          'fresh',
          4443,
          'FI',
        ).copyWith(subscriptionSource: source);
        final importer = _ScriptedSubscriptionImporter({
          source: () async => [refreshedPeer, fresh],
        });
        final now = tester.binding.clock.now;
        final due = now().add(const Duration(seconds: 5));
        await launchWithProfile(
          tester,
          initialProfile: active,
          extraProfiles: [peer],
          profileImporter: importer,
          subscriptionRefreshNow: now,
          preferences: {'nextSubscriptionRefreshAt': due.toIso8601String()},
          useTestStatusClock: true,
          waitForStopGuard: false,
        );
        final previous = FlutterSecureStoragePlatform.instance;
        final storage = _GatedSubscriptionProfileStore(
          Map.of(await previous.readAll(options: const {})),
        );
        FlutterSecureStoragePlatform.instance = storage;
        addTearDown(() => FlutterSecureStoragePlatform.instance = previous);
        final store = ProfileStore();
        final prefs = await SharedPreferences.getInstance();
        nativeCalls.clear();
        await tester.pump(due.difference(now()));
        await tester.pump();
        expect(importer.sources, [source]);
        expect(storage.writes, 1);
        expect(storage.commit.isCompleted, isFalse);

        final cancelled = scenario.stop || scenario.dispose;
        final target = cancelled ? active : peer;
        await tester.tap(find.byKey(serverPickerKey));
        await tester.pumpAndSettle();
        await pickProfileAction(tester, target, 'Удалить');
        await tester.pumpAndSettle();
        expect(storage.writes, 1);
        expect(
          (await store.loadProfiles()).map((profile) => profile.toJson()),
          unorderedEquals([active.toJson(), peer.toJson()]),
        );
        expect(
          await store.loadDeletedProfileIdsBySubscriptionSource(),
          isEmpty,
        );
        expect(await store.loadSelectedProfileId(), active.id);
        expect(getVpnMutations(), isEmpty);

        if (scenario.stop) {
          await tester.tap(find.byKey(const ValueKey('mobile-home-tab')));
          await tester.pumpAndSettle();
          final ack = pendingStopAck = Completer<bool>();
          await tester.tap(find.byKey(powerKey));
          await pumpUntilNativeCall(tester, 'stopVPN');
          expect(storage.commit.isCompleted, isFalse);
          expect(getVpnMutations(), ['stopVPN']);
          nativeStatus = 'Stopped';
          pendingStopAck = null;
          ack.complete(true);
          await tester.pump(const Duration(milliseconds: 400));
          await tester.pumpAndSettle();
          expect(prefs.getBool('manualDisconnectRequested'), isTrue);
          expect(find.byTooltip('Подключить VPN'), findsOneWidget);
        } else if (scenario.dispose) {
          await tester.pumpWidget(const SizedBox.shrink());
        }

        storage.commit.complete();
        await tester.pumpAndSettle();
        expect(storage.writes, cancelled ? 1 : 2);
        expect(
          (await store.loadProfiles()).map((profile) => profile.toJson()),
          unorderedEquals([
            active.toJson(),
            fresh.toJson(),
            if (cancelled) refreshedPeer.toJson(),
          ]),
        );
        expect(await store.loadDeletedProfileIdsBySubscriptionSource(), {
          if (!cancelled) source: {peer.id},
        });
        expect(await store.loadSelectedProfileId(), active.id);
        expect(nativeStatus, scenario.stop ? 'Stopped' : 'Started');
        expect(getVpnMutations(), [if (scenario.stop) 'stopVPN']);
        if (scenario.stop) {
          expect(prefs.getBool('manualDisconnectRequested'), isTrue);
          expect(find.byTooltip('Подключить VPN'), findsOneWidget);
          expect(find.byKey(activeServerKey), findsNothing);
        } else if (!scenario.dispose) {
          expect(
            find.byKey(ValueKey('mobile-server-${peer.id}')),
            findsNothing,
          );
          expect(
            find.byKey(ValueKey('mobile-server-${fresh.id}')),
            findsOneWidget,
          );
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'automatic subscription refresh releases Auto handover onto the updated catalog',
    (tester) async {
      const source = 'https://profiles.example.invalid/handover';
      final active = autoFixture(
        'active',
        1443,
        'PL',
      ).copyWith(subscriptionSource: source);
      final old = autoFixture(
        'old',
        2443,
        'SE',
      ).copyWith(subscriptionSource: source);
      final fresh = autoFixture(
        'fresh',
        3443,
        'FI',
      ).copyWith(subscriptionSource: source);
      final importer = _ScriptedSubscriptionImporter({
        source: () async => [fresh],
      });
      killSwitch = {
        'known': true,
        'alwaysOn': true,
        'lockdown': true,
        'requested': true,
        'strictRuntime': true,
        'vpnActive': true,
      };
      final now = tester.binding.clock.now;
      final due = now().add(const Duration(seconds: 5));
      await launchWithProfile(
        tester,
        initialProfile: active,
        extraProfiles: [old],
        profileImporter: importer,
        subscriptionRefreshNow: now,
        preferences: {
          'automaticProfileSelection': true,
          'nextSubscriptionRefreshAt': due.toIso8601String(),
        },
        waitForStopGuard: false,
      );
      platform.status.add({
        'status': 'Started',
        'manualDisconnectRequested': false,
        'readyPhysicalPath': 'wifi:101',
      });
      await tester.pump();
      final previous = FlutterSecureStoragePlatform.instance;
      final storage = _GatedSubscriptionProfileStore(
        Map.of(await previous.readAll(options: const {})),
      );
      FlutterSecureStoragePlatform.instance = storage;
      addTearDown(() => FlutterSecureStoragePlatform.instance = previous);
      nativeCalls.clear();
      await tester.pump(due.difference(now()));
      await tester.pump();
      expect(storage.writes, 1);

      final stop = pendingStopAck = Completer<bool>();
      nativeStatus = 'Starting';
      networkSnapshot = physicalSnapshot('cellular', '202');
      platform.status.add({
        'status': 'Starting',
        'manualDisconnectRequested': false,
        'desiredRunning': true,
        'sessionReason': 'network-rebind',
        'failedReadinessPath': 'cellular:202',
      });
      await tester.pump(const Duration(milliseconds: 350));
      expect(getVpnMutations(), isEmpty);
      storage.commit.complete();
      await pumpUntilNativeCall(tester, 'stopVPN');
      expect(getVpnMutations(), ['stopVPN']);
      nativeStatus = 'Stopped';
      pendingStopAck = null;
      scriptedStarts.add(true);
      stop.complete(true);
      await pumpUntilNativeCall(tester, 'startVPN');
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      expect(getVpnMutations(), ['stopVPN', 'saveConfig', 'startVPN']);
      expect(nativeConfigs.single, contains('"server_port":3443'));
      final store = ProfileStore();
      expect(await store.loadSelectedProfileId(), fresh.id);
      expect(
        (await store.loadProfiles()).map((p) => p.id),
        unorderedEquals([active.id, fresh.id]),
      );
      expect(nativeCalls, isNot(contains('setKillSwitchRequested')));
      expect(nativeCalls, isNot(contains('getDirectProbeNetwork')));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 10));
    },
  );

  for (final chooseAuto in [false, true]) {
    testWidgets(
      'automatic subscription refresh preserves the newest choice during a write (Auto=$chooseAuto)',
      (tester) async {
        const source = 'https://profiles.example.invalid/selection';
        final active = autoFixture(
          'active',
          1443,
          'PL',
        ).copyWith(subscriptionSource: source);
        final first = autoFixture('first-choice', 2443, 'SE');
        final last = autoFixture('last-choice', 3443, 'FI');
        final fresh = autoFixture(
          'fresh',
          4443,
          'DE',
        ).copyWith(subscriptionSource: source);
        final importer = _ScriptedSubscriptionImporter({
          source: () async => [fresh],
        });
        final now = tester.binding.clock.now;
        final due = now().add(const Duration(seconds: 5));
        await launchWithProfile(
          tester,
          initialProfile: active,
          extraProfiles: [first, last],
          profileImporter: importer,
          subscriptionRefreshNow: now,
          preferences: {
            'automaticProfileSelection': false,
            'nextSubscriptionRefreshAt': due.toIso8601String(),
          },
          waitForStopGuard: false,
        );
        final previous = FlutterSecureStoragePlatform.instance;
        final storage = _GatedSubscriptionProfileStore(
          Map.of(await previous.readAll(options: const {})),
        );
        FlutterSecureStoragePlatform.instance = storage;
        addTearDown(() => FlutterSecureStoragePlatform.instance = previous);
        nativeCalls.clear();
        await tester.pump(due.difference(now()));
        await tester.pump();
        expect(storage.writes, 1);
        await chooseServer(tester, first);
        await tester.pumpAndSettle();
        if (chooseAuto) {
          await tester.tap(find.byKey(serverPickerKey));
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(const ValueKey('mobile-auto-server')));
        } else {
          await chooseServer(tester, last);
        }
        await tester.pumpAndSettle();
        expect(getVpnMutations(), isEmpty);

        storage.commit.complete();
        if (chooseAuto) {
          await tester.pumpAndSettle();
          expect(getVpnMutations(), isEmpty);
          expect(await ProfileStore().loadSelectedProfileId(), active.id);
          expect(await ProfileStore().loadAutomaticProfileSelection(), isTrue);
        } else {
          await pumpUntilNativeCall(tester, 'reloadVPN');
          await tester.pump(const Duration(seconds: 2));
          await tester.pumpAndSettle();
          expect(getVpnMutations(), ['saveConfig', 'reloadVPN']);
          expect(nativeConfigs.single, contains('"server_port":3443'));
          expect(await ProfileStore().loadSelectedProfileId(), last.id);
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(seconds: 10));
      },
    );
  }

  for (final statusMismatch in [false, true]) {
    testWidgets(
      'automatic subscription refresh defers a VPN transition (native mismatch=$statusMismatch)',
      (tester) async {
        const source = 'https://profiles.example.invalid/transition';
        final active = autoFixture(
          'active',
          1443,
          'PL',
        ).copyWith(subscriptionSource: source);
        final fresh = autoFixture(
          'fresh',
          2443,
          'SE',
        ).copyWith(subscriptionSource: source);
        final importer = _ScriptedSubscriptionImporter({
          source: () async => [fresh],
        });
        final now = tester.binding.clock.now;
        final due = now().add(const Duration(seconds: 5));
        await launchWithProfile(
          tester,
          initialProfile: active,
          profileImporter: importer,
          subscriptionRefreshNow: now,
          preferences: {'nextSubscriptionRefreshAt': due.toIso8601String()},
          waitForStopGuard: false,
        );
        nativeCalls.clear();
        final stopAck = Completer<bool>();
        if (statusMismatch) {
          // UI has not yet received this transitional status from Android.
          nativeStatus = 'Stopping';
        } else {
          pendingStopAck = stopAck;
          await tester.tap(find.byKey(powerKey));
          await pumpUntilNativeCall(tester, 'stopVPN');
        }
        await tester.pump(due.difference(now()));
        await tester.pump();
        final store = ProfileStore();
        expect(importer.sources, isEmpty);
        expect(await store.loadNextSubscriptionRefreshAt(), due);
        if (statusMismatch) {
          nativeStatus = 'Started';
        } else {
          nativeStatus = 'Stopped';
          pendingStopAck = null;
          stopAck.complete(true);
          await tester.pump(const Duration(milliseconds: 400));
        }
        await tester.pump(
          due.add(const Duration(minutes: 1)).difference(now()),
        );
        await tester.pumpAndSettle();
        expect(importer.sources, [source]);
        expect(importer.tunnelOnly, [statusMismatch]);
        expect(
          (await store.loadProfiles()).map((p) => p.id),
          unorderedEquals([if (statusMismatch) active.id, fresh.id]),
        );
        expect(getVpnMutations(), [if (!statusMismatch) 'stopVPN']);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'automatic subscription refresh preserves the catalog if secure storage refuses a write',
    (tester) async {
      const source = 'https://profiles.example.invalid/storage';
      final active = autoFixture(
        'active',
        1443,
        'PL',
      ).copyWith(subscriptionSource: source);
      final fresh = autoFixture(
        'fresh',
        2443,
        'SE',
      ).copyWith(subscriptionSource: source);
      final importer = _ScriptedSubscriptionImporter({
        source: () async => [fresh],
      });
      final now = tester.binding.clock.now;
      final due = now().add(const Duration(seconds: 5));
      await launchWithProfile(
        tester,
        initialProfile: active,
        profileImporter: importer,
        subscriptionRefreshNow: now,
        preferences: {'nextSubscriptionRefreshAt': due.toIso8601String()},
        waitForStopGuard: false,
      );
      final previous = FlutterSecureStoragePlatform.instance;
      final storage = _ProfileWriteFailureStore(
        Map.of(await previous.readAll(options: const {})),
      );
      FlutterSecureStoragePlatform.instance = storage;
      addTearDown(() => FlutterSecureStoragePlatform.instance = previous);
      nativeCalls.clear();
      await tester.pump(due.difference(now()));
      await tester.pumpAndSettle();
      final store = ProfileStore();
      expect(importer.sources, [source]);
      expect(storage.writeAttempts, 1);
      expect((await store.loadProfiles()).single.toJson(), active.toJson());
      expect(await store.loadSelectedProfileId(), active.id);
      expect(
        await store.loadNextSubscriptionRefreshAt(),
        due.add(const Duration(hours: 2)),
      );
      expect(find.byKey(activeServerKey), findsOneWidget);
      expect(find.byType(SnackBar), findsNothing);
      expect(getVpnMutations(), isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'automatic subscription refresh falls back to two hours after a deadline read failure',
    (tester) async {
      const source = 'https://profiles.example.invalid/deadline-read';
      const privateDetail = 'fixture-private-deadline-error';
      final active = autoFixture(
        'active',
        1443,
        'PL',
      ).copyWith(subscriptionSource: source);
      final fresh = autoFixture(
        'fresh',
        2443,
        'SE',
      ).copyWith(subscriptionSource: source);
      final importer = _ScriptedSubscriptionImporter({
        source: () async => [fresh],
      });
      final deadlineRead = Completer<DateTime?>();
      final failingStore = _PendingSubscriptionDeadlineStore(
        deadlineRead.future,
      );
      final now = tester.binding.clock.now;
      final overdue = now().subtract(const Duration(hours: 12));
      final drafts = interceptExternalLinks();
      killSwitch = {
        'known': true,
        'runtimeKnown': true,
        'requested': true,
        'alwaysOn': true,
        'lockdown': true,
        'strictRuntime': true,
        'vpnActive': true,
      };
      await launchWithProfile(
        tester,
        initialProfile: active,
        profileImporter: importer,
        profileStore: failingStore,
        subscriptionRefreshNow: now,
        viewport: const Size(380, 1200),
        preferences: {'nextSubscriptionRefreshAt': overdue.toIso8601String()},
        waitForStopGuard: false,
      );
      final saved = ProfileStore();
      expect(failingStore.deadlineReads, 1);
      expect(await saved.loadNextSubscriptionRefreshAt(), overdue.toUtc());
      expect(importer.sources, isEmpty);
      expect(find.byKey(activeServerKey), findsOneWidget);
      nativeCalls.clear();

      final failedAt = now().toUtc();
      deadlineRead.completeError(
        PlatformException(
          code: 'FIXTURE_DEADLINE_READ',
          message: privateDetail,
        ),
      );
      await tester.pump();
      final due = failedAt.add(const Duration(hours: 2));
      expect(await saved.loadNextSubscriptionRefreshAt(), due);
      expect(importer.sources, isEmpty);
      expect((await saved.loadProfiles()).single.toJson(), active.toJson());
      expect(await saved.loadSelectedProfileId(), active.id);
      expect(find.byType(SnackBar), findsNothing);
      expect(getVpnMutations(), isEmpty);

      await tester.pump(const Duration(milliseconds: 250));
      await openSupportReport(tester);
      await tester.pumpAndSettle();
      final report = drafts.single.queryParameters['body']!;
      expect(report, contains('Could not read subscription refresh schedule.'));
      expect(report, isNot(contains(privateDetail)));
      expect(report, isNot(contains('FIXTURE_DEADLINE_READ')));
      expect(report, isNot(contains(source)));

      // Pausing cancels unrelated UI polling, but the subscription timer keeps
      // working while the process is alive. Only the test clock advances.
      binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump(
        due.difference(now()) - const Duration(milliseconds: 1),
      );
      expect(importer.sources, isEmpty);
      expect(getVpnMutations(), isEmpty);
      await tester.pump(const Duration(milliseconds: 1));
      await tester.pump();
      expect(importer.sources, [source]);
      expect(importer.tunnelOnly, [true]);
      expect(
        await saved.loadNextSubscriptionRefreshAt(),
        due.add(const Duration(hours: 2)),
      );
      expect(
        (await saved.loadProfiles()).map((profile) => profile.id),
        unorderedEquals([active.id, fresh.id]),
      );
      expect(await saved.loadSelectedProfileId(), active.id);
      expect(failingStore.deadlineReads, 1);

      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('mobile-home-tab')));
      await tester.pumpAndSettle();
      expect(find.byKey(activeServerKey), findsOneWidget);
      expect(nativeStatus, 'Started');
      expect(importer.sources, [source]);
      expect(getVpnMutations(), isEmpty);
      expect(nativeCalls, isNot(contains('getDirectProbeNetwork')));
      expect(nativeCalls, isNot(contains('setKillSwitchRequested')));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 10));
    },
  );

  testWidgets(
    'automatic subscription refresh keeps its in-memory deadline when preferences refuse a write',
    (tester) async {
      const source = 'https://profiles.example.invalid/deadline-storage';
      final active = autoFixture(
        'active',
        1443,
        'PL',
      ).copyWith(subscriptionSource: source);
      final fresh = autoFixture(
        'fresh',
        2443,
        'SE',
      ).copyWith(subscriptionSource: source);
      final importer = _ScriptedSubscriptionImporter({
        source: () async => [fresh],
      });
      final now = tester.binding.clock.now;
      final due = now().add(const Duration(seconds: 5));
      await launchWithProfile(
        tester,
        initialProfile: active,
        profileImporter: importer,
        subscriptionRefreshNow: now,
        preferences: {'nextSubscriptionRefreshAt': due.toIso8601String()},
        waitForStopGuard: false,
      );
      final previous = SharedPreferencesStorePlatform.instance;
      final backend = _RejectSubscriptionDeadlineStore(await previous.getAll());
      SharedPreferencesStorePlatform.instance = backend;
      addTearDown(() => SharedPreferencesStorePlatform.instance = previous);
      nativeCalls.clear();
      await tester.pump(due.difference(now()));
      await tester.pumpAndSettle();
      expect(backend.rejectedWrites, 1);
      expect(importer.sources, [source]);
      expect(
        (await ProfileStore().loadProfiles()).map((p) => p.id),
        unorderedEquals([active.id, fresh.id]),
      );
      binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(backend.rejectedWrites, 1);
      expect(importer.sources, [source]);
      expect(getVpnMutations(), isEmpty);
      expect(find.byKey(activeServerKey), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 10));
    },
  );

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

  testWidgets('battery settings show the exemption and a safe fallback', (
    tester,
  ) async {
    final calls = <String>[];
    binding.defaultBinaryMessenger.setMockMethodCallHandler(powerChannel, (
      call,
    ) async {
      calls.add(call.method);
      return switch (call.method) {
        'isIgnoringBatteryOptimizations' => true,
        'openAppBatterySettings' => false,
        _ => fail('Unexpected battery action: ${call.method}'),
      };
    });
    await launchWithProfile(tester, connected: false);
    expect(calls, isEmpty);
    await tester.tap(find.byKey(settingsKey));
    await tester.pumpAndSettle();
    expect(
      find.text('Исключено из оптимизации батареи Android'),
      findsOneWidget,
    );
    await tapSettingsItem(
      tester,
      find.byKey(const ValueKey('mobile-background-power')),
    );
    expect(calls, ['isIgnoringBatteryOptimizations', 'openAppBatterySettings']);
    expect(
      find.text(
        'Откройте Настройки Android → Приложения → Yurich Connect → Батарея.',
      ),
      findsOneWidget,
    );
    expect(getVpnMutations(), isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Android diagnostic bridge keeps profile inventory private and rejects unsafe requests',
    (tester) async {
      final ready = <String>[];
      binding.defaultBinaryMessenger.setMockMethodCallHandler(soakChannel, (
        call,
      ) async {
        ready.add(call.method);
        return null;
      });
      addTearDown(
        () => binding.defaultBinaryMessenger.setMockMethodCallHandler(
          soakChannel,
          null,
        ),
      );
      final first = autoFixture('private-fixture-id', 1443, 'PL').copyWith(
        name: 'private-fixture-name',
        originalInput: 'private-fixture-config',
        server: 'private-fixture-host.invalid',
      );
      await launchWithProfile(
        tester,
        connected: false,
        initialProfile: first,
        extraProfiles: [offlineProfile],
        updateService: _TestHomeUpdater(channel: AppDistributionChannel.soak),
      );
      expect(ready, ['ready']);
      nativeCalls.clear();
      final inventory = await soakCommand('inventory');
      expect(inventory['ok'], isTrue);
      expect(inventory['count'], 2);
      final profiles = inventory['profiles'] as List;
      expect(profiles.map((p) => p['profileToken']), ['p0001', 'p0002']);
      expect(profiles.first['runnable'], isTrue);
      expect(profiles.last['offlineMarked'], isTrue);
      final status = await soakCommand('status');
      expect(status['selectedProfileToken'], 'p0001');
      expect(status['vpnStatus'], 'Stopped');
      final exposed = jsonEncode([inventory, status]);
      for (final privateValue in [
        first.id,
        first.name,
        first.server,
        first.originalInput,
      ]) {
        expect(exposed, isNot(contains(privateValue)));
      }
      final unknown = await soakCommand(
        'not-supported',
        requestId: 'fixture private request',
      );
      expect(unknown, {
        'ok': false,
        'requestId': 'invalid',
        'error': 'unsupported_command',
      });
      expect(
        (await soakCommand('inventory', method: 'incorrect'))['error'],
        'bridge_unavailable',
      );
      expect(
        (await soakCommand('activate', token: 'p9999'))['error'],
        'invalid_profile_token',
      );
      expect(
        (await soakCommand('activate', token: ' P0002 '))['error'],
        'offline_profile_skipped',
      );
      expect(
        (await soakCommand('probe', token: 'bad'))['error'],
        'invalid_profile_token',
      );
      final probe = await soakCommand('probe', token: 'p0001');
      expect(probe['ok'], isTrue);
      expect(probe['measurementPath'], 'current_vpn_only');
      expect(getVpnMutations(), isEmpty);
      expect(nativeCalls, isNot(contains('getDirectProbeNetwork')));
    },
  );

  for (final connected in [false, true]) {
    testWidgets(
      'persisted raw config is rejected by diagnostic activation when connected=$connected',
      (tester) async {
        binding.defaultBinaryMessenger.setMockMethodCallHandler(
          soakChannel,
          (_) async => null,
        );
        addTearDown(
          () => binding.defaultBinaryMessenger.setMockMethodCallHandler(
            soakChannel,
            null,
          ),
        );
        final supported = autoFixture('soak-supported', 1443, 'PL');
        const raw = VpnProfile(
          id: 'soak-raw-config',
          name: 'QA stored raw config',
          kind: VpnProfileKind.singBoxConfig,
          originalInput: '',
          rawConfig: '{"outbounds":[{"type":"direct","tag":"direct"}]}',
        );
        await launchWithProfile(
          tester,
          connected: connected,
          waitForStopGuard: false,
          initialProfile: supported,
          extraProfiles: [raw],
          updateService: _TestHomeUpdater(channel: AppDistributionChannel.soak),
        );
        nativeCalls.clear();

        // Legacy entries remain in storage, but the bridge must not bypass
        // the same protocol restriction as the interactive profile picker.
        final inventory = await soakCommand('inventory');
        expect(inventory['count'], 2);
        final profiles = inventory['profiles'] as List;
        expect(profiles.last['profileToken'], 'p0002');
        expect(profiles.last['kind'], 'singBoxConfig');
        expect(profiles.last['runnable'], isFalse);
        final before = await soakCommand('status');
        expect(await soakCommand('activate', token: 'p0002'), {
          'ok': false,
          'requestId': 'fixture.request',
          'profileToken': 'p0002',
          'error': 'unsupported_profile',
        });
        final after = await soakCommand('status');
        expect(after['selectedProfileToken'], 'p0001');
        expect(after['selectedProfileToken'], before['selectedProfileToken']);
        expect(after['vpnStatus'], connected ? 'Started' : 'Stopped');
        expect(after['vpnStatus'], before['vpnStatus']);
        expect(nativeStatus, connected ? 'Started' : 'Stopped');
        expect(
          (await ProfileStore().loadProfiles()).map((profile) => profile.id),
          [supported.id, raw.id],
        );
        expect(
          (await SharedPreferences.getInstance()).getString(
            'selectedProfileId',
          ),
          supported.id,
        );
        expect(getVpnMutations(), isEmpty);
        expect(
          find.byKey(activeServerKey),
          connected ? findsOneWidget : findsNothing,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'diagnostic activation contains a disclosure storage failure without starting VPN',
    (tester) async {
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        soakChannel,
        (_) async => null,
      );
      addTearDown(
        () => binding.defaultBinaryMessenger.setMockMethodCallHandler(
          soakChannel,
          null,
        ),
      );
      await launchWithProfile(
        tester,
        connected: false,
        initialProfile: autoFixture('disclosure-failure', 1443, 'PL'),
        updateService: _TestHomeUpdater(channel: AppDistributionChannel.soak),
      );
      final previous = SharedPreferencesStorePlatform.instance;
      final store = _RejectVpnDisclosureStore(await previous.getAll());
      SharedPreferencesStorePlatform.instance = store;
      addTearDown(() => SharedPreferencesStorePlatform.instance = previous);
      nativeCalls.clear();

      final result = await soakCommand(
        'activate',
        token: 'p0001',
        requestId: 'private request with spaces',
      );
      expect(result, {
        'ok': false,
        'requestId': 'invalid',
        'error': 'internal_error',
      });
      expect(store.rejectedWrites, 1);
      expect(jsonEncode(result), isNot(contains('fixture-private-storage')));
      expect((await soakCommand('inventory'))['count'], 1);
      final status = await soakCommand('status');
      expect(status['ok'], isTrue);
      expect(status['vpnStatus'], 'Stopped');
      expect(status['selectedProfileToken'], 'p0001');
      expect(getVpnMutations(), isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'malformed imported Hysteria TLS keeps a failed startup report safe',
    (tester) async {
      final drafts = interceptExternalLinks();
      const password = 'fixture-private-hysteria-password';
      final input = jsonEncode({
        'type': 'hysteria2',
        'server': '127.0.0.1',
        'server_port': 443,
        'password': password,
        'tls': false,
      });
      await launchWithProfile(
        tester,
        connected: false,
        seedProfile: false,
        viewport: const Size(380, 1200),
        preferences: const {
          'vpnDisclosureVersion': 1,
          'automaticProfileSelection': false,
        },
      );
      await tester.tap(find.byKey(const ValueKey('mobile-import')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('mobile-subscription-input')),
        input,
      );
      await tester.pump();
      await tester.tap(
        find.byKey(const ValueKey('mobile-subscription-submit')),
      );
      await tester.pumpAndSettle();
      final imported = (await ProfileStore().loadProfiles()).single;
      expect(imported.kind, VpnProfileKind.hysteria2);
      expect(imported.outbound?['tls'], isFalse);

      nativeCalls.clear();
      rejectNativeStart = true;
      await tester.tap(find.byKey(powerKey));
      await pumpUntilNativeCall(tester, 'startVPN');
      for (var frame = 0; frame < 12; frame++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      await tester.pumpAndSettle();
      expect(nativeConfigs, hasLength(2));
      expect(getVpnMutations(), [
        'saveConfig',
        'startVPN',
        'stopVPN',
        'saveConfig',
        'startVPN',
        'stopVPN',
      ]);
      expect(nativeStatus, 'Stopped');
      expect(find.byKey(activeServerKey), findsNothing);
      expect(find.byTooltip('Подключить VPN'), findsOneWidget);
      expect(powerSurface(tester), YurichMobileColors.powerError);

      await openSupportReport(tester);
      await tester.pumpAndSettle();
      final report = drafts.single.queryParameters['body']!;
      expect(report, contains('config: target=android; raw/custom config'));
      expect(report, contains('status: Stopped'));
      expect(report, isNot(contains(password)));
      expect(report, isNot(contains(input)));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Android diagnostic bridge reports busy and failed commands without claiming a tunnel is ready',
    (tester) async {
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        soakChannel,
        (_) async => null,
      );
      addTearDown(
        () => binding.defaultBinaryMessenger.setMockMethodCallHandler(
          soakChannel,
          null,
        ),
      );
      const unsupported = VpnProfile(
        id: 'soak-unsupported',
        name: 'QA unsupported core fixture',
        kind: VpnProfileKind.vlessReality,
        originalInput: '',
        countryCode: 'PL',
        outbound: {
          'type': 'vless',
          'transport': {'type': 'grpc'},
        },
      );
      await launchWithProfile(
        tester,
        connected: false,
        initialProfile: unsupported,
        extraProfiles: [await xhttpFixture()],
        updateService: _TestHomeUpdater(channel: AppDistributionChannel.soak),
      );
      expect((await soakCommand('reconnect'))['error'], 'no_runnable_profile');
      expect(
        (await soakCommand('activate', token: 'p0001'))['error'],
        'unsupported_profile',
      );
      expect(getVpnMutations(), isEmpty);

      for (final command in ['activate', 'reconnect']) {
        nativeCalls.clear();
        final stop = pendingStopAck = Completer<bool>();
        scriptedStarts.add(false);
        final response = soakCommand(command, token: 'p0002');
        await pumpUntilNativeCall(tester, 'stopVPN');
        expect(getVpnMutations(), ['saveConfig', 'startVPN', 'stopVPN']);
        expect(
          (await soakCommand('activate', token: 'p0002'))['error'],
          'busy',
        );
        expect((await soakCommand('stop'))['error'], 'busy');
        nativeStatus = 'Stopped';
        pendingStopAck = null;
        stop.complete(true);
        await tester.pump(const Duration(milliseconds: 750));
        await tester.pumpAndSettle();
        expect(await response, containsPair('ok', false));
        final result = await response;
        expect(
          result['error'],
          command == 'activate' ? 'connection_failed' : 'reconnect_failed',
        );
        expect(result['vpnStatus'], 'Stopped');
        expect(getVpnMutations(), ['saveConfig', 'startVPN', 'stopVPN']);
      }
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Android diagnostic bridge switches an active profile and reports an unconfirmed stop',
    (tester) async {
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        soakChannel,
        (_) async => null,
      );
      addTearDown(
        () => binding.defaultBinaryMessenger.setMockMethodCallHandler(
          soakChannel,
          null,
        ),
      );
      final next = await xhttpFixture();
      await launchWithProfile(
        tester,
        initialProfile: autoFixture('soak-active', 1443, 'PL'),
        extraProfiles: [next],
        waitForStopGuard: false,
        useTestStatusClock: true,
        updateService: _TestHomeUpdater(channel: AppDistributionChannel.soak),
      );
      nativeCalls.clear();
      final switchStop = pendingStopAck = Completer<bool>();
      scriptedStarts.add(true);
      final activation = soakCommand('activate', token: 'p0002');
      await pumpUntilNativeCall(tester, 'stopVPN');
      expect(getVpnMutations(), ['stopVPN']);
      nativeStatus = 'Stopped';
      pendingStopAck = null;
      switchStop.complete(true);
      await pumpUntilNativeCall(tester, 'startVPN');
      await tester.pumpAndSettle();
      final active = await activation;
      expect(active['ok'], isTrue);
      expect(active['selectedProfileToken'], 'p0002');
      expect(getVpnMutations(), ['stopVPN', 'saveConfig', 'startVPN']);

      nativeCalls.clear();
      final stopAck = pendingStopAck = Completer<bool>();
      final stopping = soakCommand('stop');
      await pumpUntilNativeCall(tester, 'stopVPN');
      nativeStatus = 'Stopping';
      pendingStopAck = null;
      stopAck.complete(true);
      await tester.pump();
      await tester.pump(const Duration(seconds: 36));
      await tester.pumpAndSettle();
      final result = await stopping;
      expect(result['ok'], isFalse);
      expect(result['vpnStatus'], 'Stopping');
      expect(result['error'], 'stop_failed');
      expect(getVpnMutations(), ['stopVPN']);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Android diagnostic bridge tracks activation, counters, reconnect and stop',
    (tester) async {
      final counters = <Map>[];
      binding.defaultBinaryMessenger.setMockMethodCallHandler(soakChannel, (
        call,
      ) async {
        if (call.method == 'counter') counters.add(call.arguments as Map);
        return null;
      });
      addTearDown(
        () => binding.defaultBinaryMessenger.setMockMethodCallHandler(
          soakChannel,
          null,
        ),
      );
      await launchWithProfile(
        tester,
        connected: false,
        initialProfile: autoFixture('fixture-active', 1443, 'PL'),
        updateService: _TestHomeUpdater(channel: AppDistributionChannel.soak),
        preferences: const {
          'automaticProfileSelection': false,
          'directLatencyAllowed': false,
        },
      );
      nativeCalls.clear();
      scriptedStarts.add(true);
      final activation = soakCommand('activate', token: 'p0001');
      await pumpUntilNativeCall(tester, 'startVPN');
      await tester.pump(const Duration(milliseconds: 600));
      expect(await activation, containsPair('ok', true));
      await emitTraffic(tester, generation: 0);
      await tester.pump(const Duration(milliseconds: 1200));
      final status = await soakCommand('status');
      expect(status['vpnStatus'], 'Started');
      expect(counters, isNotEmpty);
      expect(counters.last['profileToken'], 'p0001');
      expect(counters.last['nativeSessionTotalBytes'], isPositive);

      final reconnect = soakCommand('reconnect');
      await pumpUntilNativeCall(tester, 'reloadVPN');
      await tester.pump(const Duration(milliseconds: 500));
      expect(await reconnect, containsPair('ok', true));

      pendingStopAck = Completer<bool>();
      final stopping = soakCommand('stop');
      await pumpUntilNativeCall(tester, 'stopVPN');
      expect((await soakCommand('reconnect'))['error'], 'busy');
      nativeStatus = 'Stopped';
      pendingStopAck!.complete(true);
      pendingStopAck = null;
      await tester.pump(const Duration(milliseconds: 450));
      await tester.pumpAndSettle();
      expect(await stopping, containsPair('vpnStatus', 'Stopped'));
      expect(getVpnMutations(), [
        'saveConfig',
        'startVPN',
        'saveConfig',
        'reloadVPN',
        'stopVPN',
      ]);
      expect(
        (await SharedPreferences.getInstance()).getBool(
          'manualDisconnectRequested',
        ),
        isTrue,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 10));
    },
  );

  for (final changesToSoak in [false, true]) {
    testWidgets(
      'Play settings never download an APK, including a channel change (soak=$changesToSoak)',
      (tester) async {
        final urls = interceptExternalLinks();
        final updater = _TestHomeUpdater(channel: AppDistributionChannel.play);
        await launchWithProfile(
          tester,
          connected: false,
          viewport: const Size(400, 1200),
          updateService: updater,
        );
        final action = await openUpdatePanel(
          tester,
          actionLabel: 'Открыть Google Play',
        );
        if (changesToSoak) updater.channel = AppDistributionChannel.soak;
        await tester.tap(action);
        await tester.pumpAndSettle();
        if (changesToSoak) {
          expect(urls, isEmpty);
          expect(find.text('Обновления отключены'), findsOneWidget);
          expect(
            find.text('В тестовой soak-сборке обновления отключены.'),
            findsOneWidget,
          );
        } else {
          expect(urls.single.host, 'play.google.com');
          expect(urls.single.queryParameters['id'], 'online.dnsai.ivanvpn');
          expect(
            find.text(
              'Обновления Play-сборки устанавливаются через Google Play.',
            ),
            findsOneWidget,
          );
        }
        expect(updater.manualChecks, 0);
        expect(updater.noticeChecks, 0);
        expect(updater.downloads, isEmpty);
        expect(updater.installations, isEmpty);
        expect(getVpnMutations(), isEmpty);
      },
    );
  }

  testWidgets(
    'an unreadable update channel never falls back to a GitHub download',
    (tester) async {
      final urls = interceptExternalLinks();
      final updater = _TestHomeUpdater()
        ..distributionError = StateError(
          'Fixture Bearer hidden-channel-detail',
        );
      await launchWithProfile(
        tester,
        connected: false,
        viewport: const Size(400, 1200),
        updateService: updater,
      );
      final action = await openUpdatePanel(tester, actionLabel: 'Повторить');
      await tester.tap(action);
      await tester.pumpAndSettle();
      expect(
        find.text('Канал обновлений временно недоступен.'),
        findsOneWidget,
      );
      expect(find.textContaining('hidden-channel-detail'), findsNothing);
      expect(updater.manualChecks, 0);
      expect(updater.downloads, isEmpty);
      expect(updater.installations, isEmpty);
      expect(urls, isEmpty);
    },
  );

  testWidgets(
    'home updater reports progress and hands the verified version to the installer',
    (tester) async {
      final updater = _TestHomeUpdater();
      updater.downloadGate = Completer<File>();
      updater.installGate = Completer<void>();
      await launchWithProfile(
        tester,
        connected: false,
        viewport: const Size(400, 1200),
        updateService: updater,
      );
      final action = await openUpdatePanel(tester);
      await tester.tap(action);
      await tester.pump();
      expect(updater.downloads, [updater.release]);
      expect(tester.widget<FilledButton>(action).onPressed, isNull);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);

      updater.progress!.call(null);
      await tester.pump();
      expect(find.text('Скачиваю версию 1.0.132...'), findsOneWidget);
      updater.progress!.call(0.42);
      await tester.pump();
      expect(find.text('Скачиваю версию 1.0.132: 42%'), findsOneWidget);
      expect(
        tester
            .widget<LinearProgressIndicator>(
              find.byType(LinearProgressIndicator),
            )
            .value,
        0.42,
      );

      updater.downloadGate!.complete(updater.apk);
      await tester.pump();
      expect(updater.installations, [(updater.apk.path, 43138, '1.0.132')]);
      expect(find.textContaining('Открываю установщик'), findsOneWidget);
      updater.installGate!.complete();
      await tester.pumpAndSettle();
      expect(find.text('Установщик Android открыт'), findsOneWidget);
      expect(tester.widget<FilledButton>(action).onPressed, isNotNull);
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(getVpnMutations(), isEmpty);
    },
  );

  testWidgets(
    'ABI lookup timeouts still allow a release check from the update notification',
    (tester) async {
      final architectures = Completer<List<String>>();
      final updater = _TestHomeUpdater()
        ..abiGate = architectures.future
        ..expectedAbis = const []
        ..manualIsCurrent = true;
      updater.noticeRelease = updater.release;
      await launchWithProfile(
        tester,
        connected: false,
        viewport: const Size(400, 1200),
        updateService: updater,
      );
      expect(updater.noticeChecks, 0);
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      expect(updater.noticeChecks, 1);
      expect(
        appNotifications.where((notice) => notice['id'] == 7045),
        hasLength(1),
      );
      final action = find.widgetWithText(SnackBarAction, 'Обновить');
      expect(action, findsOneWidget);
      await tester.tap(action);
      await tester.pump();
      expect(updater.manualChecks, 0);
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      expect(updater.manualChecks, 1);
      architectures.complete(const ['arm64-v8a']);
      await tester.pump();
      expect(updater.noticeChecks, 1);
      expect(updater.manualChecks, 1);
      expect(updater.downloads, isEmpty);
      expect(updater.installations, isEmpty);
      expect(getVpnMutations(), isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'failed update checks open the generic APK fallback only on explicit request',
    (tester) async {
      final urls = interceptExternalLinks();
      final updater = _TestHomeUpdater()
        ..noticeError = StateError('Fixture Bearer fixture-update-only')
        ..lookupError = StateError('Fixture lookup failed');
      await launchWithProfile(
        tester,
        connected: false,
        viewport: const Size(400, 1200),
        updateService: updater,
      );
      expect(updater.noticeChecks, 1);
      expect(appNotifications.where((notice) => notice['id'] == 7045), isEmpty);
      expect(urls, isEmpty);
      final manual = await openUpdatePanel(tester);
      await tester.tap(manual);
      await tester.pumpAndSettle();
      expect(updater.manualChecks, 1);
      expect(urls, isEmpty);
      expect(find.textContaining('fixture-update-only'), findsNothing);
      await tester.tap(find.widgetWithText(SnackBarAction, 'APK'));
      await tester.pumpAndSettle();
      expect(urls, [AppUpdateService.manualDownloadUri('1.0.126')]);
      expect(updater.downloads, isEmpty);
      expect(updater.installations, isEmpty);
      expect(getVpnMutations(), isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  for (final notificationFails in [false, true]) {
    testWidgets(
      'home updater announces a release and clears stale availability (notification fails=$notificationFails)',
      (tester) async {
        final updater = _TestHomeUpdater()..manualIsCurrent = true;
        updater.noticeRelease = updater.release;
        if (notificationFails) {
          appNotificationError = PlatformException(
            code: 'FIXTURE_UPDATE_NOTICE_ERROR',
          );
        }
        await launchWithProfile(
          tester,
          connected: false,
          viewport: const Size(400, 1200),
          updateService: updater,
        );
        expect(updater.noticeChecks, 1);
        expect(appNotifications.single['id'], 7045);
        expect(updater.downloads, isEmpty);
        expect(updater.installations, isEmpty);

        // Dismiss the announcement as a user would. With pilot controls the
        // support row is lower and the banner can cover it.
        await tester.pumpAndSettle();
        final announcement = find.widgetWithText(
          SnackBar,
          'Вышла новая версия Yurich Connect 1.0.132.',
        );
        expect(announcement, findsOneWidget);
        await tester.drag(announcement, const Offset(0, 180));
        await tester.pumpAndSettle();
        expect(announcement, findsNothing);
        final action = await openUpdatePanel(tester);
        expect(
          find.textContaining('Доступна новая версия: 1.0.132'),
          findsWidgets,
        );

        await tester.tap(action);
        await tester.pumpAndSettle();
        expect(updater.manualChecks, 1);
        expect(find.text('Версия 1.0.126 актуальна.'), findsOneWidget);
        expect(
          find.textContaining('Доступна новая версия: 1.0.132'),
          findsNothing,
        );
        expect(updater.downloads, isEmpty);
        expect(updater.installations, isEmpty);
        expect(getVpnMutations(), isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final failure in [
    'timeout',
    'architecture',
    'install permission',
    'untrusted download',
  ]) {
    testWidgets('home updater handles $failure without claiming success', (
      tester,
    ) async {
      final updater = _TestHomeUpdater();
      final openedUrls = <Uri>[];
      const launcher = MethodChannel('plugins.flutter.io/url_launcher');
      binding.defaultBinaryMessenger.setMockMethodCallHandler(launcher, (
        call,
      ) async {
        expect(call.method, 'launch');
        openedUrls.add(Uri.parse(call.arguments['url'] as String));
        return true;
      });
      addTearDown(
        () => binding.defaultBinaryMessenger.setMockMethodCallHandler(
          launcher,
          null,
        ),
      );

      final expected = switch (failure) {
        'timeout' => 'Превышено время ожидания обновления',
        'architecture' => 'Не удалось определить архитектуру телефона',
        'install permission' => 'Разреши установку приложений',
        _ => 'Обновление не удалось:',
      };
      switch (failure) {
        case 'timeout':
          updater.lookupError = TimeoutException('fixture');
        case 'architecture':
          updater.lookupError = const AppUpdateArchitectureException();
        case 'install permission':
          updater.installError = const AppUpdatePermissionException();
        default:
          updater.downloadError = StateError(
            'Rejected Bearer fixture-private-token',
          );
      }
      await launchWithProfile(
        tester,
        connected: false,
        viewport: const Size(400, 1200),
        updateService: updater,
      );
      final action = await openUpdatePanel(tester);
      await tester.tap(action);
      await tester.pumpAndSettle();
      expect(find.textContaining(expected), findsWidgets);
      expect(find.text('Установщик Android открыт'), findsNothing);
      expect(tester.widget<FilledButton>(action).onPressed, isNotNull);
      expect(updater.manualChecks, 1);
      if (failure == 'timeout') {
        updater.lookupError = null;
        updater.manualIsCurrent = true;
        await tester.tap(find.widgetWithText(SnackBarAction, 'Повторить'));
        await tester.pumpAndSettle();
        expect(updater.manualChecks, 2);
        expect(find.text('Версия 1.0.126 актуальна.'), findsOneWidget);
      }
      if (failure == 'install permission') {
        await tester.tap(find.widgetWithText(SnackBarAction, 'Настройки'));
        await tester.pumpAndSettle();
        expect(updater.settingsOpens, 1);
        expect(updater.installations, hasLength(1));
      } else {
        expect(updater.installations, isEmpty);
      }
      if (failure == 'untrusted download') {
        expect(find.textContaining('fixture-private-token'), findsNothing);
        expect(find.textContaining('Bearer ***'), findsWidgets);
        await tester.tap(find.widgetWithText(SnackBarAction, 'APK'));
        await tester.pumpAndSettle();
        expect(openedUrls, [updater.release.downloadUrl]);
      } else {
        expect(openedUrls, isEmpty);
      }
    });
  }

  testWidgets(
    'late background update check clears an obsolete release without reinstalling it',
    (tester) async {
      final notice = Completer<AppUpdateInfo?>();
      final updater = _TestHomeUpdater()..noticeGate = notice.future;
      await launchWithProfile(
        tester,
        connected: false,
        viewport: const Size(400, 1200),
        updateService: updater,
      );
      expect(updater.noticeChecks, 1);
      final action = await openUpdatePanel(tester);
      await tester.tap(action);
      await tester.pumpAndSettle();
      expect(updater.manualChecks, 1);
      expect(updater.downloads, [updater.release]);
      expect(updater.installations, hasLength(1));
      expect(
        find.textContaining('Доступна новая версия: 1.0.132'),
        findsWidgets,
      );

      notice.complete(null);
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Доступна новая версия: 1.0.132'),
        findsNothing,
      );
      expect(updater.downloads, hasLength(1));
      expect(updater.installations, hasLength(1));
      expect(appNotifications, isEmpty);
      expect(getVpnMutations(), isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'GitHub testing builds show their own channel without installing',
    (tester) async {
      const version = '1.0.132-test.20261116.7';
      PackageInfo.setMockInitialValues(
        appName: 'Yurich Connect',
        packageName: 'online.dnsai.ivanvpn',
        version: version,
        buildNumber: '43215',
        buildSignature: '',
      );
      final updater = _TestHomeUpdater(expectedVersion: version)
        ..manualIsCurrent = true;
      await launchWithProfile(
        tester,
        connected: false,
        updateService: updater,
        preferences: const {'languageCode': 'en'},
      );
      await tester.tap(find.byKey(settingsKey));
      await tester.pumpAndSettle();
      await tapSettingsItem(tester, find.text('App and support'));
      await tapSettingsItem(tester, find.text('Updates'));
      expect(find.text('Update channel: GitHub / Testing'), findsOneWidget);
      expect(find.text('Update channel: GitHub Releases'), findsNothing);
      expect(updater.manualChecks, 0);
      await tapSettingsItem(tester, find.text('Check and install'));
      expect(updater.manualChecks, 1);
      expect(updater.downloads, isEmpty);
      expect(updater.installations, isEmpty);
      expect(getVpnMutations(), isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

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

    final links = interceptExternalLinks();
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
    final supportLink = find.text('Поддержка');
    await reveal(supportLink);
    await tester.tap(supportLink);
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
    for (final label in ['Telegram', 'VK', 'Донат']) {
      final action = find.text(label);
      await reveal(action);
      await tester.tap(action);
      await tester.pumpAndSettle();
    }
    expect(links.map((url) => url.toString()), [
      'https://t.me/ivan_it_net',
      'https://t.me/ivan_it_net',
      'https://vk.com/ivan_yurievich_it',
      'https://dzen.ru/ivanyurievich?donate=true',
    ]);

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

  for (final initiallyEnabled in [false, true]) {
    testWidgets(
      'local pilot keeps recording off when Android cannot confirm consent (revoke=$initiallyEnabled)',
      (tester) async {
        final writes = <bool>[];
        final records = <Object?>[];
        binding.defaultBinaryMessenger.setMockMethodCallHandler(
          incidentChannel,
          (call) async {
            switch (call.method) {
              case 'state':
                return {
                  'enabled': initiallyEnabled,
                  'queued': 0,
                  if (initiallyEnabled) 'epoch': 'fixture-existing-consent',
                };
              case 'setEnabled':
                writes.add(call.arguments['enabled'] == true);
                return null;
              case 'record':
                records.add(call.arguments);
                return null;
              default:
                fail('Unexpected diagnostic action: ${call.method}');
            }
          },
        );
        await launchWithProfile(
          tester,
          connected: false,
          initialProfile: await xhttpFixture(),
          viewport: const Size(380, 1100),
          preferences: const {'vpnDisclosureVersion': 1},
        );
        await tester.tap(find.byKey(settingsKey));
        await tester.pumpAndSettle();
        final tile = find.byKey(const ValueKey('mobile-local-incidents'));
        await tester.ensureVisible(tile);
        await tester.pumpAndSettle();
        expect(tester.widget<SwitchListTile>(tile).value, initiallyEnabled);
        if (initiallyEnabled) {
          await tester.tap(tile);
        } else {
          await tester.tap(tile);
          await tester.pumpAndSettle();
          await tester.tap(find.text('Оставить выключенным'));
          await tester.pumpAndSettle();
          expect(writes, isEmpty);
          expect(tester.widget<SwitchListTile>(tile).value, isFalse);
          await tester.tap(tile);
          await tester.pumpAndSettle();
          await tester.tap(find.text('Сохранять на телефоне'));
        }
        await tester.pumpAndSettle();
        expect(writes, [!initiallyEnabled]);
        expect(tester.widget<SwitchListTile>(tile).value, isFalse);
        expect(tester.widget<SwitchListTile>(tile).onChanged, isNotNull);
        expect(
          find.textContaining('Не удалось подтвердить изменение истории'),
          findsOneWidget,
        );
        expect(getVpnMutations(), isEmpty);

        await tester.tap(find.byKey(const ValueKey('mobile-home-tab')));
        await tester.pumpAndSettle();
        rejectNativeStart = true;
        await tester.tap(find.byKey(powerKey));
        await pumpUntilNativeCall(tester, 'stopVPN');
        await tester.pump(const Duration(milliseconds: 750));
        expect(getVpnMutations(), ['saveConfig', 'startVPN', 'stopVPN']);
        expect(records, isEmpty);
        expect(tester.takeException(), isNull);
      },
      skip: !LocalConnectionIncidentsService.pilotBuild,
    );
  }

  testWidgets(
    'local pilot discards a record reply after the user revokes consent',
    (tester) async {
      const key = ValueKey('mobile-local-incidents');
      const epoch = 'synthetic-revocation-epoch';
      final recorded = <Map<Object?, Object?>>[];
      final pendingRecord = Completer<Map<String, Object?>>();
      var consent = true;
      final messenger = binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(incidentChannel, (call) async {
        switch (call.method) {
          case 'state':
            return {
              'enabled': consent,
              'queued': 0,
              if (consent) 'epoch': epoch,
            };
          case 'setEnabled':
            expect(call.arguments, {'enabled': false});
            consent = false;
            return {'enabled': false, 'queued': 0};
          case 'record':
            recorded.add(Map<Object?, Object?>.from(call.arguments as Map));
            return pendingRecord.future;
          default:
            fail('Unexpected diagnostic method: ${call.method}');
        }
      });
      await launchWithProfile(
        tester,
        connected: false,
        initialProfile: await xhttpFixture(),
        preferences: const {'vpnDisclosureVersion': 1},
        viewport: const Size(360, 1000),
      );
      rejectNativeStart = true;
      await tester.tap(find.byKey(powerKey));
      for (var i = 0; i < 25 && recorded.isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 250));
      }
      expect(recorded.single['epoch'], epoch);
      expect(recorded.single['code'], 'start_failed');
      await tester.tap(find.byKey(settingsKey));
      await tester.pumpAndSettle();
      final tile = find.byKey(key);
      final scroll = find.descendant(
        of: find.byKey(const PageStorageKey('mobile-settings-scroll')),
        matching: find.byType(Scrollable),
      );
      await tester.scrollUntilVisible(tile, 150, scrollable: scroll);
      await tester.pumpAndSettle();
      expect(tester.widget<SwitchListTile>(tile).value, isTrue);
      await tester.tap(tile.hitTestable());
      await tester.pumpAndSettle();
      expect(consent, isFalse);
      pendingRecord.complete({'enabled': true, 'epoch': epoch, 'queued': 1});
      await tester.pumpAndSettle();
      expect(tester.widget<SwitchListTile>(tile).value, isFalse);

      await tester.tap(find.byKey(const ValueKey('mobile-home-tab')));
      await tester.pumpAndSettle();
      nativeCalls.clear();
      await tester.tap(find.byKey(powerKey));
      await pumpUntilNativeCall(tester, 'startVPN');
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
      expect(nativeCalls, contains('stopVPN'));
      expect(recorded, hasLength(1));
      expect(tester.takeException(), isNull);
    },
    skip: !LocalConnectionIncidentsService.pilotBuild,
  );

  for (final duringCleanup in [false, true]) {
    testWidgets(
      'local pilot attributes a terminal Auto failure only to the final physical network (cleanup=$duringCleanup)',
      (tester) async {
        const epoch = 'fixture-handover-consent';
        final reports = <Map<Object?, Object?>>[];
        binding.defaultBinaryMessenger.setMockMethodCallHandler(
          incidentChannel,
          (call) async {
            switch (call.method) {
              case 'state':
                break;
              case 'record':
                reports.add(Map<Object?, Object?>.from(call.arguments as Map));
              default:
                fail('Unexpected fixture diagnostic call: ${call.method}');
            }
            return {'enabled': true, 'epoch': epoch, 'queued': reports.length};
          },
        );
        final profile = autoFixture('pilot-network-failure', 1443, 'PL');
        networkSnapshot = physicalSnapshot('wifi', '101');
        await launchWithProfile(
          tester,
          connected: false,
          initialProfile: profile,
          useTestStatusClock: true,
          useTestReconnectClock: true,
          preferences: const {
            'automaticProfileSelection': true,
            'directLatencyAllowed': false,
            'vpnDisclosureVersion': 1,
          },
        );
        final cleanup = pendingStopAck = Completer<bool>();
        final start = Completer<bool>();
        if (duringCleanup) {
          scriptedStarts.add(false);
        } else {
          pendingStartAck = start;
        }
        nativeCalls.clear();
        await tester.tap(find.byKey(powerKey));
        await pumpUntilNativeCall(tester, 'startVPN');
        if (!duringCleanup) {
          networkSnapshot = const {'type': 'none', 'validated': false};
          nativeStatus = 'Starting';
          pendingStartAck = null;
          start.complete(true);
        }
        await pumpUntilNativeCall(tester, 'stopVPN');
        expect(getVpnMutations(), ['saveConfig', 'startVPN', 'stopVPN']);
        expect(reports, isEmpty);

        networkSnapshot = physicalSnapshot('cellular', '202');
        nativeStatus = 'Stopped';
        pendingStopAck = null;
        scriptedStarts.add(false);
        cleanup.complete(true);
        for (var frame = 0; frame < 24 && reports.isEmpty; frame++) {
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
        expect(reports.single, {
          'epoch': epoch,
          'protocol': 'naive',
          'network': 'cellular',
          'stage': 'vpn_start',
          'code': 'start_failed',
        });
        final byNetwork = (await ProfileStore()
            .loadProfileNetworkStabilityStats())[profile.id]!;
        expect(byNetwork['wifi'], isNull);
        expect(byNetwork['cellular']?.healthFailures, 1);
        expect(find.byKey(activeServerKey), findsNothing);
        expect(nativeCalls, isNot(contains('getDirectProbeNetwork')));
        expect(tester.takeException(), isNull);
      },
      skip: !LocalConnectionIncidentsService.pilotBuild,
    );
  }

  for (final phase in ['dispatch', 'readiness', 'cleanup']) {
    testWidgets(
      'local pilot records one safe terminal startup timeout ($phase)',
      (tester) async {
        const epoch = 'fixture-timeout-consent';
        final records = <Map<Object?, Object?>>[];
        binding.defaultBinaryMessenger.setMockMethodCallHandler(
          incidentChannel,
          (call) async {
            switch (call.method) {
              case 'state':
                break;
              case 'record':
                records.add(Map<Object?, Object?>.from(call.arguments as Map));
              default:
                fail('Unexpected diagnostic method: ${call.method}');
            }
            return {'enabled': true, 'epoch': epoch, 'queued': records.length};
          },
        );
        await launchWithProfile(
          tester,
          connected: false,
          initialProfile: await xhttpFixture(),
          useTestStatusClock: true,
          preferences: const {'vpnDisclosureVersion': 1},
        );
        nativeCalls.clear();

        final startAck = pendingStartAck = Completer<bool>();
        final stopAck = pendingStopAck = Completer<bool>();
        await tester.tap(find.byKey(powerKey));
        await pumpUntilNativeCall(tester, 'startVPN');
        if (phase == 'dispatch') {
          await tester.pump(const Duration(seconds: 9));
        } else {
          nativeStatus = 'Starting';
          pendingStartAck = null;
          startAck.complete(true);
          await tester.pump();
          await tester.pump(const Duration(seconds: 41));
        }
        await pumpUntilNativeCall(tester, 'stopVPN');
        expect(records, isEmpty);
        expect(getVpnMutations(), ['saveConfig', 'startVPN', 'stopVPN']);

        nativeStatus = phase == 'cleanup' ? 'Stopping' : 'Stopped';
        pendingStopAck = null;
        stopAck.complete(true);
        await tester.pump();
        if (phase == 'cleanup') {
          await tester.pump(const Duration(seconds: 34));
          expect(records, isEmpty);
          await tester.pump(const Duration(seconds: 2));
        } else {
          await tester.pump(const Duration(milliseconds: 550));
        }
        await tester.pump();
        expect(records.single, {
          'epoch': epoch,
          'protocol': 'xhttp',
          'network': 'wifi',
          'stage': 'vpn_start',
          'code': phase == 'cleanup' ? 'stop_timeout' : 'timeout',
        });

        if (phase == 'dispatch') {
          pendingStartAck = null;
          startAck.complete(true);
        }
        nativeStatus = 'Stopped';
        platform.status.add({'status': 'Stopped'});
        await tester.pumpAndSettle();
        expect(records, hasLength(1));
        expect(getVpnMutations(), ['saveConfig', 'startVPN', 'stopVPN']);
        expect(find.byKey(activeServerKey), findsNothing);
        expect(tester.takeException(), isNull);
      },
      skip: !LocalConnectionIncidentsService.pilotBuild,
    );
  }

  for (final networkChanging in [false, true]) {
    testWidgets(
      'local pilot classifies an unconfirmed pre-start stop (network changing=$networkChanging)',
      (tester) async {
        const epoch = 'fixture-stop-consent';
        final records = <Map<Object?, Object?>>[];
        binding.defaultBinaryMessenger.setMockMethodCallHandler(
          incidentChannel,
          (call) async {
            switch (call.method) {
              case 'state':
                break;
              case 'record':
                records.add(Map<Object?, Object?>.from(call.arguments as Map));
              default:
                fail('Unexpected diagnostic method: ${call.method}');
            }
            return {'enabled': true, 'epoch': epoch, 'queued': records.length};
          },
        );
        final selected = await xhttpFixture();
        await launchWithProfile(
          tester,
          connected: false,
          initialProfile: selected,
          useTestStatusClock: true,
          preferences: const {'vpnDisclosureVersion': 1},
        );
        if (networkChanging) {
          networkSnapshot = {
            ...physicalSnapshot('cellular', '202'),
            'generation': 1,
          };
          platform.status.add({'status': 'Stopped', ...networkSnapshot});
          await tester.pump();
        }
        // Discover the old runtime from the fresh status query, not a UI event.
        nativeStatus = 'Started';
        final stop = pendingStopAck = Completer<bool>();
        nativeCalls.clear();
        await tester.tap(find.byKey(powerKey));
        await pumpUntilNativeCall(tester, 'stopVPN');
        expect(records, isEmpty);
        expect(getVpnMutations(), ['stopVPN']);

        nativeStatus = 'Stopping';
        pendingStopAck = null;
        stop.complete(true);
        await tester.pump();
        await tester.pump(const Duration(seconds: 36));
        await tester.pump();
        expect(records.single, {
          'epoch': epoch,
          'protocol': 'xhttp',
          'network': networkChanging ? 'unknown' : 'wifi',
          'stage': 'vpn_start',
          'code': 'stop_timeout',
        });

        nativeStatus = 'Stopped';
        platform.status.add({'status': 'Stopped'});
        await tester.pumpAndSettle();
        expect(records, hasLength(1));
        expect(getVpnMutations(), ['stopVPN']);
        expect(nativeConfigs, isEmpty);
        expect(find.byKey(activeServerKey), findsNothing);
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getString('selectedProfileId'), selected.id);
        expect(tester.takeException(), isNull);
      },
      skip: !LocalConnectionIncidentsService.pilotBuild,
    );
  }

  for (final kind in ['malformed', 'not an object', 'oversized UTF-8']) {
    testWidgets(
      'Hermes preview safely rejects $kind',
      (tester) async {
        final preview = switch (kind) {
          'malformed' => '{fixture-preview',
          'not an object' => '["fixture-preview"]',
          _ => jsonEncode({'fixture-preview': 'я' * 600}),
        };
        final calls = <String>[];
        binding.defaultBinaryMessenger.setMockMethodCallHandler(
          incidentChannel,
          (call) async {
            calls.add(call.method);
            return switch (call.method) {
              'state' => {'enabled': false, 'queued': 0},
              'hermesPreview' => preview,
              _ => fail('Unexpected diagnostic method: ${call.method}'),
            };
          },
        );
        await launchWithProfile(tester, connected: false);
        await tester.tap(find.byKey(settingsKey));
        await tester.pumpAndSettle();
        final tile = find.byKey(const ValueKey('mobile-hermes-preview'));
        final scroll = find.byKey(
          const PageStorageKey('mobile-settings-scroll'),
        );
        for (var i = 0; i < 12 && tile.hitTestable().evaluate().isEmpty; i++) {
          await tester.drag(scroll, const Offset(0, -140));
          await tester.pumpAndSettle();
        }
        expect(tile.hitTestable(), findsOneWidget);
        await tester.tap(tile);
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsOneWidget);
        expect(find.byType(SelectableText), findsOneWidget);
        expect(
          tester.widget<SelectableText>(find.byType(SelectableText)).data,
          isNot(contains('fixture-preview')),
        );
        expect(calls, ['state', 'hermesPreview']);
        expect(getVpnMutations(), isEmpty);
        await tester.tap(find.text('Закрыть'));
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsNothing);
      },
      skip: !LocalConnectionIncidentsService.hermesPilotBuild,
    );
  }

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

  for (final (language, summary) in [
    ('ru', 'На телефоне: 2. Ничего не отправляется.'),
    ('en', 'On this device: 2. Nothing is sent.'),
  ]) {
    testWidgets(
      'local-only pilot keeps reports on-device and shows its preview ($language)',
      (tester) async {
        final calls = <String>[];
        binding.defaultBinaryMessenger.setMockMethodCallHandler(
          incidentChannel,
          (call) async {
            calls.add(call.method);
            return switch (call.method) {
              'state' => {'enabled': true, 'queued': 2, 'epoch': 'test-epoch'},
              'hermesPreview' => '{"protocol":"fixture"}',
              _ => fail('Unexpected incident action: ${call.method}'),
            };
          },
        );
        await launchWithProfile(
          tester,
          connected: false,
          preferences: {'languageCode': language},
        );
        await tester.tap(find.byKey(settingsKey));
        await tester.pumpAndSettle();
        final preview = find.byKey(const ValueKey('mobile-hermes-preview'));
        await tapSettingsItem(tester, preview);
        expect(
          find.text(
            language == 'en'
                ? 'Synthetic example only. Reports stay on this device; upload is unavailable.'
                : 'Только пример. Отчёты остаются на телефоне, отправка недоступна.',
          ),
          findsWidgets,
        );
        await tester.tap(find.text(language == 'en' ? 'Close' : 'Закрыть'));
        await tester.pumpAndSettle();
        expect(find.text(summary), findsOneWidget);
        expect(
          find.byKey(const ValueKey('mobile-hermes-delivery')),
          findsNothing,
        );
        expect(calls, ['state', 'hermesPreview']);
        expect(getVpnMutations(), isEmpty);
        expect(tester.takeException(), isNull);
      },
      skip:
          !LocalConnectionIncidentsService.pilotBuild ||
          !LocalConnectionIncidentsService.hermesPilotBuild ||
          LocalConnectionIncidentsService.hermesDeliveryPilotBuild,
    );
  }

  testWidgets(
    'Hermes dialog blocks token entry without local consent',
    (tester) async {
      final secureScreen = <bool>[];
      binding.defaultBinaryMessenger.setMockMethodCallHandler(incidentChannel, (
        call,
      ) async {
        switch (call.method) {
          case 'state':
            return {'enabled': false, 'queued': 0};
          case 'hermesDeliveryState':
            return {'enabled': false, 'tokenConfigured': false};
          case 'setHermesSecretScreen':
            secureScreen.add(call.arguments['enabled'] == true);
            return true;
          default:
            fail('Unexpected incident action: ${call.method}');
        }
      });
      await launchWithProfile(
        tester,
        connected: false,
        preferences: const {'languageCode': 'en'},
      );
      final tile = await findHermesDeliveryTile(tester);
      const localKey = ValueKey('mobile-local-incidents');
      await tapSettingsItem(tester, find.byKey(localKey));
      expect(
        find.textContaining('This does not grant permission to send reports.'),
        findsOneWidget,
      );
      await tester.tap(find.text('Keep off'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<SwitchListTile>(find.byKey(localKey)).value,
        isFalse,
      );
      await tapSettingsItem(tester, tile);
      expect(
        find.text('First allow local failure recording in Settings.'),
        findsOneWidget,
      );
      for (final key in [
        'hermes-delivery-bearer',
        'hermes-delivery-consent',
        'hermes-delivery-save',
      ]) {
        expect(find.byKey(ValueKey(key)), findsNothing);
      }
      expect(secureScreen, [true]);
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      expect(secureScreen, [true, false]);
      expect(getVpnMutations(), isEmpty);
      expect(tester.takeException(), isNull);
    },
    skip: !LocalConnectionIncidentsService.hermesDeliveryPilotBuild,
  );

  testWidgets(
    'Hermes dialog reports blocked authorization and rejects a malformed token',
    (tester) async {
      final screenEvents = <bool>[];
      binding.defaultBinaryMessenger.setMockMethodCallHandler(incidentChannel, (
        call,
      ) async {
        switch (call.method) {
          case 'state':
            return {'enabled': true, 'queued': 2, 'epoch': 'test-epoch'};
          case 'hermesDeliveryState':
            return {
              'enabled': true,
              'tokenConfigured': true,
              'authorizationBlocked': true,
              'routeReady': false,
            };
          case 'setHermesSecretScreen':
            screenEvents.add(call.arguments['enabled'] == true);
            return true;
          default:
            fail('Unexpected incident action: ${call.method}');
        }
      });
      await launchWithProfile(
        tester,
        connected: false,
        preferences: const {'languageCode': 'en'},
      );
      final tile = await findHermesDeliveryTile(tester);
      expect(
        find.text('On this device: 2. Sending requires separate permission.'),
        findsOneWidget,
      );
      await tapSettingsItem(tester, tile);
      expect(
        find.text('Sending is paused: a valid token is required.'),
        findsOneWidget,
      );
      expect(screenEvents, [true]);
      final consent = find.byKey(const ValueKey('hermes-delivery-consent'));
      final field = find.byKey(const ValueKey('hermes-delivery-bearer'));
      final save = find.byKey(const ValueKey('hermes-delivery-save'));
      await tester.ensureVisible(consent);
      await tester.tap(consent);
      await tester.ensureVisible(field);
      await tester.enterText(field, 'Bearer fixture-token');
      await tester.pumpAndSettle();
      expect(
        find.text('Enter the token without spaces or the Bearer prefix.'),
        findsOneWidget,
      );
      expect(tester.widget<FilledButton>(save).onPressed, isNull);
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      expect(screenEvents, [true, false]);
      expect(getVpnMutations(), isEmpty);
      expect(tester.takeException(), isNull);
    },
    skip: !LocalConnectionIncidentsService.hermesDeliveryPilotBuild,
  );

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
    'Hermes delivery reconciles lost ACKs and lets the user retry a partial revoke',
    (tester) async {
      const fixtureToken = 'fixture-only-never-transmitted';
      var state = <String, Object>{'enabled': false, 'tokenConfigured': false};
      final writes = <Map<Object?, Object?>>[];
      final screenEvents = <bool>[];
      var reads = 0;
      binding.defaultBinaryMessenger.setMockMethodCallHandler(incidentChannel, (
        call,
      ) async {
        switch (call.method) {
          case 'state':
            return {'enabled': true, 'queued': 0, 'epoch': 'fixture-local'};
          case 'hermesDeliveryState':
            reads++;
            return state;
          case 'setHermesSecretScreen':
            screenEvents.add(call.arguments['enabled'] == true);
            return true;
          case 'configureHermesDelivery':
            final write = Map<Object?, Object?>.from(call.arguments as Map);
            writes.add(write);
            final enabled = write['enabled'] == true;
            state = {
              'enabled': enabled,
              'tokenConfigured': enabled || writes.length == 2,
              'routeReady': enabled,
            };
            return writes.length == 2 ? state : null;
          default:
            fail('Unexpected diagnostic action: ${call.method}');
        }
      });
      await launchWithProfile(tester, connected: false);
      await tester.tap((await findHermesDeliveryTile(tester)).hitTestable());
      await tester.pumpAndSettle();
      expect(reads, 1);
      expect(screenEvents, [true]);
      final field = find.byKey(const ValueKey('hermes-delivery-bearer'));
      final consent = find.byKey(const ValueKey('hermes-delivery-consent'));
      final save = find.byKey(const ValueKey('hermes-delivery-save'));
      final revoke = find.byKey(const ValueKey('hermes-delivery-revoke'));
      final confirm = find.byKey(
        const ValueKey('hermes-delivery-revoke-confirm'),
      );
      await tester.ensureVisible(field);
      await tester.enterText(field, fixtureToken);
      await tester.ensureVisible(consent);
      await tester.tap(consent);
      await tester.pumpAndSettle();
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(writes, [
        {'enabled': true, 'bearer': fixtureToken},
      ]);
      expect(reads, 2);
      expect(tester.widget<TextField>(field).controller!.text, isEmpty);
      expect(find.text('Отправка разрешена только через VPN.'), findsOneWidget);
      expect(revoke, findsOneWidget);

      await tester.tap(revoke);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Отмена'));
      await tester.pumpAndSettle();
      expect(writes, hasLength(1));

      await tester.tap(revoke);
      await tester.pumpAndSettle();
      await tester.tap(confirm);
      await tester.pumpAndSettle();
      expect(writes.last, {'enabled': false});
      expect(writes, hasLength(2));
      expect(
        find.textContaining('Не удалось подтвердить изменение'),
        findsOneWidget,
      );
      expect(revoke, findsOneWidget);
      expect(tester.widget<TextField>(field).controller!.text, isEmpty);

      await tester.tap(revoke);
      await tester.pumpAndSettle();
      await tester.tap(confirm);
      await tester.pumpAndSettle();
      expect(writes.last, {'enabled': false});
      expect(writes, hasLength(3));
      expect(reads, 3);
      expect(revoke, findsNothing);
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
    'Hermes delivery leaves the secret screen closed without a readable state',
    (tester) async {
      final calls = <String>[];
      binding.defaultBinaryMessenger.setMockMethodCallHandler(incidentChannel, (
        call,
      ) async {
        calls.add(call.method);
        return switch (call.method) {
          'state' => {'enabled': true, 'queued': 0, 'epoch': 'fixture-local'},
          'hermesDeliveryState' => null,
          _ => fail('Unexpected diagnostic action: ${call.method}'),
        };
      });
      await launchWithProfile(tester, connected: false);
      await tester.tap((await findHermesDeliveryTile(tester)).hitTestable());
      await tester.pumpAndSettle();
      expect(calls, contains('hermesDeliveryState'));
      expect(calls, isNot(contains('setHermesSecretScreen')));
      expect(calls, isNot(contains('configureHermesDelivery')));
      expect(
        find.byKey(const ValueKey('hermes-delivery-bearer')),
        findsNothing,
      );
      expect(find.text('Настройки отправки недоступны.'), findsOneWidget);
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

  testWidgets(
    'traffic scheduler failure is contained and later counters recover',
    (tester) async {
      var failNextTrafficTimer = false;
      var injectedFailures = 0;
      final drafts = interceptExternalLinks();
      // Register the listener in this zone: stream callbacks execute in their
      // subscription zone, not the zone that later emits an event.
      await runZoned(
        () async {
          await launchWithProfile(
            tester,
            waitForStopGuard: false,
            viewport: const Size(380, 1200),
          );
          nativeCalls.clear();
          failNextTrafficTimer = true;
          await emitTraffic(tester, generation: 0);
          failNextTrafficTimer = false;

          expect(injectedFailures, 1);
          expect(find.text('0 B'), findsOneWidget);
          expect(find.byKey(activeServerKey), findsOneWidget);
          expect(find.text('Нет стабильного соединения'), findsNothing);
          expect(getVpnMutations(), isEmpty);
          expect(tester.takeException(), isNull);

          await emitTraffic(tester, generation: 0);
          await tester.pump(const Duration(seconds: 1));
          expect(find.text('1 MB'), findsOneWidget);
          expect(injectedFailures, 1);
          await openSupportReport(tester);
          await tester.pumpAndSettle();
          final report = drafts.single.queryParameters['body']!;
          expect(report, contains('engine-stream-error:traffic:'));
          expect(report, contains('traffic-scheduler-unavailable-test'));
          expect(report, isNot(contains('engine-stream-error:traffic-flush:')));
          expect(report, contains('status: Started'));
          expect(getVpnMutations(), isEmpty);
          expect(tester.takeException(), isNull);
        },
        zoneSpecification: ZoneSpecification(
          createTimer: (self, parent, zone, duration, callback) {
            // Fault injection, not a network simulation: fail just one flush
            // timer and delegate every subsequent timer to the test clock.
            if (failNextTrafficTimer &&
                duration == const Duration(seconds: 1)) {
              failNextTrafficTimer = false;
              injectedFailures++;
              throw StateError('traffic-scheduler-unavailable-test');
            }
            return parent.createTimer(zone, duration, callback);
          },
        ),
      );
    },
  );

  testWidgets(
    'malformed Android status and traffic events do not break later counters',
    (tester) async {
      final drafts = interceptExternalLinks();
      await launchWithProfile(
        tester,
        waitForStopGuard: false,
        viewport: const Size(380, 1200),
      );
      nativeCalls.clear();
      platform.status.add({'status': false});
      platform.traffic.add({'formattedDownlinkSpeed': false});
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.byKey(activeServerKey), findsOneWidget);
      expect(find.text('0 B'), findsOneWidget);
      expect(find.text('Нет стабильного соединения'), findsNothing);

      // A valid event on that same stream still updates the counters.
      await emitTraffic(tester, generation: 0);
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('1 MB'), findsOneWidget);
      await openSupportReport(tester);
      await tester.pumpAndSettle();
      final report = drafts.single.queryParameters['body']!;
      expect(report, contains('engine-stream-error:status:'));
      expect(report, contains('engine-stream-error:traffic-flush:'));
      expect(report, contains('status: Started'));
      expect(getVpnMutations(), isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'in-flight notification sync sends the latest state after an Android stop',
    (tester) async {
      await launchWithProfile(tester, waitForStopGuard: false);
      connectionNotifications.clear();
      nativeCalls.clear();
      final ack = pendingConnectionNotification = Completer<bool>();
      await emitConnected(tester);
      expect(connectionNotifications.single['status'], 'connected');
      await emitTraffic(tester, generation: 0);
      await tester.pump(const Duration(seconds: 1));
      nativeStatus = 'Stopped';
      platform.status.add({
        'status': 'Stopped',
        'manualDisconnectRequested': true,
      });
      await tester.pump();
      expect(connectionNotifications, hasLength(1));

      pendingConnectionNotification = null;
      ack.complete(true);
      await tester.pump();
      expect(connectionNotifications, hasLength(2));
      final latest = connectionNotifications.last;
      expect(latest['status'], 'disconnected');
      expect(latest['profileName'], isNull);
      expect(latest['pingMs'], isNull);
      expect(find.byKey(activeServerKey), findsNothing);
      expect(getVpnMutations(), isEmpty);
      expect(tester.takeException(), isNull);
    },
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

  for (final stopsDuringSettle in [false, true]) {
    testWidgets(
      'Android resume reports an unexpected stop without competing with native recovery (settle=$stopsDuringSettle)',
      (tester) async {
        final profile = autoFixture('resume-fixture', 1443, 'PL');
        await launchWithProfile(
          tester,
          initialProfile: profile,
          waitForStopGuard: false,
        );
        final prefs = await SharedPreferences.getInstance();
        binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        await tester.pump();
        nativeCalls.clear();
        if (!stopsDuringSettle) nativeStatus = 'Stopped';
        binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        await tester.pump(const Duration(milliseconds: 2100));
        await tester.pump();
        if (stopsDuringSettle) {
          expect(find.byKey(activeServerKey), findsOneWidget);
          expect(prefs.getString('profileNetworkStabilityStats'), isNull);
          nativeStatus = 'Stopped';
          await tester.pump(const Duration(seconds: 5));
          await tester.pump();
        }
        final expectedReason = stopsDuringSettle
            ? 'unexpected-stop:app-resume-after-settle'
            : 'unexpected-stop:app-resume';
        final stats =
            jsonDecode(prefs.getString('profileNetworkStabilityStats')!) as Map;
        expect(stats[profile.id]['wifi']['healthFailures'], 1);
        expect(stats[profile.id]['wifi']['lastFailureReason'], expectedReason);
        expect(find.byKey(activeServerKey), findsNothing);
        expect(find.textContaining('VPN остановлен неожиданно'), findsWidgets);
        expect(getVpnMutations(), isEmpty);

        nativeStatus = 'Started';
        await emitConnected(tester);
        await tester.pump();
        expect(find.byKey(activeServerKey), findsOneWidget);
        expect(find.textContaining('VPN остановлен неожиданно'), findsNothing);
        expect(getVpnMutations(), isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'manual stop during resume settling does not arm another recovery',
    (tester) async {
      await launchWithProfile(tester, waitForStopGuard: false);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump(const Duration(milliseconds: 2100));
      await tester.pump();
      expect(find.byKey(activeServerKey), findsOneWidget);

      nativeCalls.clear();
      pendingStopAck = Completer<bool>();
      await tester.tap(find.byKey(powerKey));
      await pumpUntilNativeCall(tester, 'stopVPN');
      nativeStatus = 'Stopped';
      pendingStopAck!.complete(true);
      pendingStopAck = null;
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(seconds: 6));
      await tester.pumpAndSettle();

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('manualDisconnectRequested'), isTrue);
      expect(prefs.getString('profileNetworkStabilityStats'), isNull);
      expect(find.byTooltip('Подключить VPN'), findsOneWidget);
      expect(find.textContaining('VPN остановлен неожиданно'), findsNothing);
      expect(getVpnMutations(), ['stopVPN']);
      expect(tester.takeException(), isNull);
    },
  );

  for (final scenario in [
    'matches',
    'stale',
    'read failure',
    'user stopped',
    'restoration failed',
  ]) {
    testWidgets('restored VLESS reconciliation: $scenario', (tester) async {
      final selected = (await ProfileImporter().importFromText(
        'vless://11111111-1111-4111-8111-111111111111@127.0.0.1:1443'
        '?security=tls&type=tcp&sni=fixture.invalid#Fixture',
      )).single.copyWith(countryCode: 'PL');
      final expected = SingBoxConfigBuilder().build(selected);
      final map = jsonDecode(expected) as Map;
      // A change in JSON layout alone must never restart an active tunnel.
      restoredNativeConfig = jsonEncode(
        Map.fromEntries(map.entries.toList().reversed),
      );
      expect(restoredNativeConfig, isNot(expected));
      if (scenario == 'stale') {
        restoredNativeConfig = SingBoxConfigBuilder().build(
          selected.copyWith(
            port: 2443,
            outbound: {...selected.outbound!, 'server_port': 2443},
          ),
        );
        expect(
          RuntimeConfigMatcher.equivalent(restoredNativeConfig, expected),
          isFalse,
        );
      }
      if (scenario == 'read failure') {
        configReadError = PlatformException(
          code: 'CONFIG_READ_FIXTURE_FAILURE',
        );
      }
      if (scenario == 'user stopped') nativeManualStopRequested = true;
      // The stale-restoration case starts in Android before configuration is readable.
      final waiting = scenario == 'stale' || scenario == 'restoration failed';
      await launchWithProfile(
        tester,
        connected: scenario != 'user stopped' && !waiting,
        initialNativeStatus: waiting ? 'Starting' : null,
        initialProfile: selected,
        preferences: const {'smartRouteRuDirect': false},
        waitForStopGuard: false,
      );
      if (scenario == 'restoration failed') {
        expect(nativeCalls, isNot(contains('getConfig')));
        nativeStatus = 'Stopped';
        await tester.pump(const Duration(milliseconds: 450));
        await tester.pump();
        expect(nativeCalls, isNot(contains('getConfig')));
        expect(getVpnMutations(), isEmpty);
        expect(find.byTooltip('Подключить VPN'), findsOneWidget);
      } else if (waiting) {
        expect(nativeCalls, isNot(contains('getConfig')));
        expect(getVpnMutations(), isEmpty);
        nativeStatus = 'Started';
        await pumpUntilNativeCall(tester, 'reloadVPN');
        await tester.pump(const Duration(milliseconds: 350));
        expect(getVpnMutations(), ['saveConfig', 'reloadVPN']);
        expect(
          RuntimeConfigMatcher.equivalent(nativeConfigs.single, expected),
          isTrue,
        );
      } else if (scenario == 'user stopped') {
        expect(nativeCalls, isNot(contains('getConfig')));
        expect(find.byTooltip('Подключить VPN'), findsOneWidget);
        expect(getVpnMutations(), isEmpty);
      } else {
        expect(
          nativeCalls.where((method) => method == 'getConfig'),
          hasLength(1),
        );
        expect(getVpnMutations(), isEmpty);
        expect(find.byKey(activeServerKey), findsOneWidget);
      }
      expect(
        (await SharedPreferences.getInstance()).getString('selectedProfileId'),
        selected.id,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 10));
    });
  }

  for (final stopAckPending in [false, true]) {
    testWidgets(
      'manual Stop fences a late restored VLESS config (stop ACK pending=$stopAckPending)',
      (tester) async {
        final selected = (await ProfileImporter().importFromText(
          'vless://11111111-1111-4111-8111-111111111111@127.0.0.1:1443'
          '?security=tls&type=tcp&sni=fixture.invalid#Fixture',
        )).single.copyWith(countryCode: 'PL');
        final expected = SingBoxConfigBuilder().build(selected);
        final stale = SingBoxConfigBuilder().build(
          selected.copyWith(
            port: 2443,
            outbound: {...selected.outbound!, 'server_port': 2443},
          ),
        );
        expect(RuntimeConfigMatcher.equivalent(stale, expected), isFalse);
        final configReply = pendingRuntimeConfigRead = Completer<String>();
        await launchWithProfile(
          tester,
          initialProfile: selected,
          preferences: const {'smartRouteRuDirect': false},
          waitForStopGuard: false,
          useTestStatusClock: true,
        );
        expect(
          nativeCalls.where((method) => method == 'getConfig'),
          hasLength(1),
        );
        expect(getVpnMutations(), isEmpty);
        final stopAck = pendingStopAck = Completer<bool>();
        await tester.tap(find.byKey(powerKey));
        await pumpUntilNativeCall(tester, 'stopVPN');
        expect(getVpnMutations(), ['stopVPN']);

        Future<void> confirmStop() async {
          nativeStatus = 'Stopped';
          pendingStopAck = null;
          stopAck.complete(true);
          await tester.pump(const Duration(milliseconds: 400));
          await tester.pump();
        }

        if (!stopAckPending) await confirmStop();
        // The old read must never acquire a new running intent after Stop,
        // whether the native stop is still in flight or already confirmed.
        pendingRuntimeConfigRead = null;
        configReply.complete(stale);
        await tester.pump(const Duration(milliseconds: 250));
        if (stopAckPending) await confirmStop();
        for (var frame = 0; frame < 16; frame++) {
          await tester.pump(const Duration(milliseconds: 500));
        }
        await tester.pumpAndSettle();

        expect(getVpnMutations(), ['stopVPN']);
        expect(nativeConfigs, isEmpty);
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getBool('manualDisconnectRequested'), isTrue);
        expect(prefs.getString('selectedProfileId'), selected.id);
        expect(find.byKey(activeServerKey), findsNothing);
        expect(find.byTooltip('Подключить VPN'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'restored VLESS still reconciles a delayed mismatch after a Started heartbeat',
    (tester) async {
      final selected = (await ProfileImporter().importFromText(
        'vless://11111111-1111-4111-8111-111111111111@127.0.0.1:1443'
        '?security=tls&type=tcp&sni=fixture.invalid#Fixture',
      )).single.copyWith(countryCode: 'PL');
      final configReply = pendingRuntimeConfigRead = Completer<String>();
      await launchWithProfile(
        tester,
        initialProfile: selected,
        preferences: const {'smartRouteRuDirect': false},
        waitForStopGuard: false,
      );
      expect(
        nativeCalls.where((method) => method == 'getConfig'),
        hasLength(1),
      );
      expect(getVpnMutations(), isEmpty);
      await emitConnected(tester);
      // A repeated native Started is not a new user command. The fresh Dart
      // controller also has no local running intent for this restored tunnel.
      pendingRuntimeConfigRead = null;
      configReply.complete('{}');
      await pumpUntilNativeCall(tester, 'reloadVPN');
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();

      expect(getVpnMutations(), ['saveConfig', 'reloadVPN']);
      expect(
        RuntimeConfigMatcher.equivalent(
          nativeConfigs.single,
          SingBoxConfigBuilder().build(selected),
        ),
        isTrue,
      );
      expect(find.byKey(activeServerKey), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 10));
    },
  );

  for (final changeProfile in [false, true]) {
    testWidgets(
      'late restored VLESS config cannot supersede Stop then a new manual connection (change profile=$changeProfile)',
      (tester) async {
        final selected = (await ProfileImporter().importFromText(
          'vless://11111111-1111-4111-8111-111111111111@127.0.0.1:1443'
          '?security=tls&type=tcp&sni=fixture.invalid#Fixture',
        )).single.copyWith(countryCode: 'PL');
        final next = autoFixture('new-manual-profile', 3443, 'SE');
        final configReply = pendingRuntimeConfigRead = Completer<String>();
        await launchWithProfile(
          tester,
          initialProfile: selected,
          extraProfiles: [next],
          preferences: const {
            'smartRouteRuDirect': false,
            'automaticProfileSelection': false,
            'vpnDisclosureVersion': 1,
          },
          waitForStopGuard: false,
          useTestStatusClock: true,
        );
        expect(
          nativeCalls.where((method) => method == 'getConfig'),
          hasLength(1),
        );
        expect(getVpnMutations(), isEmpty);
        final stopAck = pendingStopAck = Completer<bool>();
        await tester.tap(find.byKey(powerKey));
        await pumpUntilNativeCall(tester, 'stopVPN');
        nativeStatus = 'Stopped';
        pendingStopAck = null;
        stopAck.complete(true);
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pumpAndSettle();
        expect(getVpnMutations(), ['stopVPN']);
        if (changeProfile) {
          await chooseServer(tester, next);
          await tester.pumpAndSettle();
        }

        scriptedStarts.add(true);
        await tester.tap(find.byKey(powerKey));
        await pumpUntilNativeCall(tester, 'startVPN');
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pumpAndSettle();
        final prefs = await SharedPreferences.getInstance();
        final expectedProfile = changeProfile ? next : selected;
        expect(prefs.getBool('manualDisconnectRequested'), isFalse);
        expect(prefs.getString('selectedProfileId'), expectedProfile.id);
        expect(find.byKey(activeServerKey), findsOneWidget);
        expect(getVpnMutations(), ['stopVPN', 'saveConfig', 'startVPN']);

        // The old config is stale, but Stop -> Start has already established
        // a newer command even when the selected profile ID stayed the same.
        pendingRuntimeConfigRead = null;
        configReply.complete('{}');
        for (var frame = 0; frame < 16; frame++) {
          await tester.pump(const Duration(milliseconds: 500));
        }
        await tester.pumpAndSettle();
        expect(getVpnMutations(), ['stopVPN', 'saveConfig', 'startVPN']);
        expect(nativeConfigs, hasLength(1));
        expect(prefs.getBool('manualDisconnectRequested'), isFalse);
        expect(prefs.getString('selectedProfileId'), expectedProfile.id);
        expect(find.byKey(activeServerKey), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'restored VLESS keeps the matching tunnel when the status query times out',
    (tester) async {
      final selected = (await ProfileImporter().importFromText(
        'vless://11111111-1111-4111-8111-111111111111@127.0.0.1:1443'
        '?security=tls&type=tcp&sni=fixture.invalid#Fixture',
      )).single.copyWith(countryCode: 'PL');
      restoredNativeConfig = SingBoxConfigBuilder().build(selected);
      await launchWithProfile(
        tester,
        connected: false,
        initialNativeStatus: 'Started',
        initialProfile: selected,
        preferences: const {'smartRouteRuDirect': false},
        bootstrapFrames: 2,
      );
      expect(find.byKey(activeServerKey), findsOneWidget);
      expect(nativeCalls, isNot(contains('getConfig')));
      final statusReply = pendingVpnStatusRead = Completer<String>();
      nativeCalls.clear();

      await pumpUntilNativeCall(tester, 'getVPNStatus');
      expect(nativeCalls, isNot(contains('getConfig')));
      await tester.pump(const Duration(seconds: 3));
      await tester.pump();
      expect(
        nativeCalls.where((method) => method == 'getConfig'),
        hasLength(1),
      );
      expect(getVpnMutations(), isEmpty);

      pendingVpnStatusRead = null;
      statusReply.complete('Stopped');
      await tester.pumpAndSettle();
      expect(find.byKey(activeServerKey), findsOneWidget);
      expect(getVpnMutations(), isEmpty);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('selectedProfileId'), selected.id);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'watchdog detects network change by fingerprint and keeps traffic on the right network',
    (tester) async {
      final profile = autoFixture('network-fixture', 1443, 'PL');
      networkSnapshot = {
        ...physicalSnapshot('wifi', '101'),
        'fingerprint': 'fixture-wifi',
        'generation': 0,
      };
      await launchWithProfile(tester, initialProfile: profile);
      await emitTraffic(tester, generation: 0);
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('1 MB'), findsOneWidget);
      nativeCalls.clear();

      // Some snapshots carry no usable generation number. The changed
      // fingerprint still fences old readings and establishes a new baseline.
      networkSnapshot = {
        ...physicalSnapshot('cellular', '202'),
        'fingerprint': 'fixture-cellular',
        'generation': 0,
      };
      await tester.pump(const Duration(seconds: 20));
      await tester.pump();
      expect(find.text('Переподключение'), findsWidgets);
      expect(find.text('Нет стабильного соединения'), findsNothing);
      expect(find.text('1 MB'), findsOneWidget);
      expect(getVpnMutations(), isEmpty);

      nativeStatus = 'Starting';
      platform.status.add({
        ...networkSnapshot,
        'status': 'Starting',
        'sessionReason': 'network-rebind',
        'desiredRunning': true,
        'manualDisconnectRequested': false,
      });
      await tester.pump();
      await tester.pump();
      expect(find.text('1 MB'), findsOneWidget);
      expect(find.byKey(activeServerKey), findsNothing);
      nativeStatus = 'Started';
      platform.status.add({
        ...networkSnapshot,
        'status': 'Started',
        'manualDisconnectRequested': false,
        'readyPhysicalPath': 'cellular:202',
      });
      await tester.pump();
      await tester.pump();
      expect(find.byKey(activeServerKey), findsOneWidget);
      platform.traffic.add({
        ...networkSnapshot,
        'sessionTotal': 2 * 1024 * 1024,
        'formattedSessionTotal': '2 MB',
      });
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('2 MB'), findsOneWidget);
      final stats = (await ProfileStore()
          .loadProfileNetworkStabilityStats())[profile.id]!;
      expect(stats['wifi']!.trafficBytes, 1024 * 1024);
      expect(stats['cellular']!.trafficBytes, 1024 * 1024);
      expect(stats.values.map((row) => row.healthFailures), everyElement(0));
      expect(getVpnMutations(), isEmpty);
    },
  );

  testWidgets(
    'watchdog detects a silent stop even when the network snapshot fails',
    (tester) async {
      final profile = autoFixture('silent-stop', 1443, 'PL');
      await launchWithProfile(tester, initialProfile: profile);
      nativeCalls.clear();
      networkSnapshotError = PlatformException(
        code: 'NETWORK_SNAPSHOT_FIXTURE_FAILURE',
      );
      nativeStatus = 'Stopped';
      await tester.pump(const Duration(seconds: 20));
      await tester.pump();
      expect(
        nativeCalls,
        containsAllInOrder(['getNetworkSnapshot', 'getVPNStatus']),
      );
      expect(find.textContaining('VPN остановлен неожиданно'), findsWidgets);
      expect(find.byKey(activeServerKey), findsNothing);
      Future<void> oneFailure() async {
        final stats = (await ProfileStore()
            .loadProfileNetworkStabilityStats())[profile.id]!['wifi']!;
        expect(stats.healthFailures, 1);
        expect(stats.lastFailureReason, 'unexpected-stop:watchdog');
      }

      await oneFailure();
      await tester.pump(const Duration(seconds: 20));
      await tester.pump();
      await oneFailure();
      expect(getVpnMutations(), isEmpty);

      networkSnapshotError = null;
      nativeStatus = 'Started';
      await tester.pump(const Duration(seconds: 20));
      await tester.pump();
      expect(find.byKey(activeServerKey), findsOneWidget);
      expect(find.textContaining('VPN остановлен неожиданно'), findsNothing);
      expect(getVpnMutations(), isEmpty);
    },
  );

  testWidgets(
    'rapid background and foreground transitions share one recovery check',
    (tester) async {
      await launchWithProfile(tester, waitForStopGuard: false);
      nativeCalls.clear();
      int statusReads() =>
          nativeCalls.where((method) => method == 'getVPNStatus').length;
      void leaveAndReturn() {
        binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      }

      leaveAndReturn();
      await tester.pump(const Duration(milliseconds: 2100));
      await tester.pump();
      final reads = statusReads();
      expect(reads, 1);

      leaveAndReturn();
      await tester.pump(const Duration(milliseconds: 2100));
      await tester.pump();
      expect(statusReads(), reads);
      await tester.pump(const Duration(seconds: 3));
      await tester.pump();
      expect(statusReads(), reads + 1);
      expect(find.byKey(activeServerKey), findsOneWidget);
      expect(getVpnMutations(), isEmpty);
    },
  );

  testWidgets(
    'late Started without a new user intent is stopped after manual disconnect',
    (tester) async {
      await launchWithProfile(tester, waitForStopGuard: false);
      nativeCalls.clear();
      final firstStop = Completer<bool>();
      pendingStopAck = firstStop;
      await tester.tap(find.byKey(powerKey));
      await pumpUntilNativeCall(tester, 'stopVPN');
      nativeStatus = 'Stopped';
      firstStop.complete(true);
      pendingStopAck = null;
      await tester.pump(const Duration(milliseconds: 450));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Подключить VPN'), findsOneWidget);

      final staleStop = Completer<bool>();
      pendingStopAck = staleStop;
      nativeStatus = 'Started';
      platform.status.add({'status': 'Started'});
      platform.status.add({'status': 'Started'});
      for (var i = 0; i < 10 && getVpnMutations().length < 2; i++) {
        await tester.pump(const Duration(milliseconds: 250));
      }
      expect(getVpnMutations(), ['stopVPN', 'stopVPN']);
      nativeStatus = 'Stopped';
      staleStop.complete(true);
      pendingStopAck = null;
      await tester.pump(const Duration(milliseconds: 450));
      await tester.pumpAndSettle();
      expect(find.byKey(activeServerKey), findsNothing);
      expect(find.byTooltip('Подключить VPN'), findsOneWidget);
      expect(
        (await SharedPreferences.getInstance()).getBool(
          'manualDisconnectRequested',
        ),
        isTrue,
      );
      expect(getVpnMutations(), ['stopVPN', 'stopVPN']);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'closing HomeScreen cancels a pending manual stop guard without restarting VPN',
    (tester) async {
      await launchWithProfile(tester, waitForStopGuard: false);
      nativeCalls.clear();
      final firstStop = Completer<bool>();
      pendingStopAck = firstStop;
      await tester.tap(find.byKey(powerKey));
      await pumpUntilNativeCall(tester, 'stopVPN');
      nativeStatus = 'Stopped';
      firstStop.complete(true);
      pendingStopAck = null;
      await tester.pump(const Duration(milliseconds: 450));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Подключить VPN'), findsOneWidget);

      final guardStop = Completer<bool>();
      pendingStopAck = guardStop;
      nativeStatus = 'Started';
      platform.status.add({'status': 'Started'});
      for (var frame = 0; frame < 10 && getVpnMutations().length < 2; frame++) {
        await tester.pump(const Duration(milliseconds: 250));
      }
      expect(getVpnMutations(), ['stopVPN', 'stopVPN']);

      // The Android reply may arrive after navigation disposes the screen.
      // Cancellation must not revive the old command or emit setState errors.
      await tester.pumpWidget(const SizedBox.shrink());
      nativeStatus = 'Stopped';
      guardStop.complete(true);
      pendingStopAck = null;
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      expect(getVpnMutations(), ['stopVPN', 'stopVPN']);
      expect(
        (await SharedPreferences.getInstance()).getBool(
          'manualDisconnectRequested',
        ),
        isTrue,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'closing HomeScreen ignores a late rejected Stop and preserves manual intent',
    (tester) async {
      await launchWithProfile(tester, waitForStopGuard: false);
      nativeCalls.clear();
      final stopAck = Completer<bool>();
      pendingStopAck = stopAck;
      await tester.tap(find.byKey(powerKey));
      await pumpUntilNativeCall(tester, 'stopVPN');
      expect(getVpnMutations(), ['stopVPN']);

      await tester.pumpWidget(const SizedBox.shrink());
      stopAck.completeError(PlatformException(code: 'DISPATCH_REJECTED'));
      pendingStopAck = null;
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      expect(getVpnMutations(), ['stopVPN']);
      expect(
        (await SharedPreferences.getInstance()).getBool(
          'manualDisconnectRequested',
        ),
        isTrue,
      );
      expect(tester.takeException(), isNull);
    },
  );

  for (final hadTraffic in [true, false]) {
    testWidgets(
      'fallback health check distinguishes fresh traffic from a failed probe (traffic=$hadTraffic)',
      (tester) async {
        final profile = await xhttpFixture();
        await launchWithProfile(
          tester,
          connected: false,
          initialNativeStatus: 'Started',
          initialProfile: profile,
        );
        if (hadTraffic) {
          await emitTraffic(tester, generation: 0);
          await tester.pump(const Duration(seconds: 1));
        }
        nativeCalls.clear();

        // Without Android's native health owner, a stream error triggers
        // the fallback check. Flutter's widget binding returns HTTP 400
        // for all probe requests; it never makes a real network request.
        await emitStreamError(tester, 'status');
        for (var i = 0; i < 8; i++) {
          await tester.pump(const Duration(milliseconds: 350));
        }
        final profileStats = (await ProfileStore()
            .loadProfileStabilityStats())[profile.id]!;
        if (hadTraffic) {
          expect(profileStats.lastHealthyAt, isNotNull);
          expect(profileStats.healthFailures, 0);
          expect(find.text('Нет стабильного соединения'), findsNothing);
        } else {
          expect(profileStats.healthFailures, 1);
          expect(
            profileStats.lastFailureReason,
            'health-probe:engine-stream-status',
          );
          expect(find.text('Нет стабильного соединения'), findsOneWidget);
          await emitConnected(tester);
          await emitTraffic(tester, generation: 0);
          await tester.pump(const Duration(seconds: 1));
          await tester.pump();
          expect(find.text('Нет стабильного соединения'), findsNothing);
          expect(powerSurface(tester), YurichMobileColors.powerActive);
        }
        expect(find.byKey(activeServerKey), findsOneWidget);
        expect(nativeStatus, 'Started');
        expect(getVpnMutations(), isEmpty);
        expect(tester.takeException(), isNull);
      },
      variant: const TargetPlatformVariant({TargetPlatform.windows}),
    );
  }

  for (final outcome in ['ready', 'rejected', 'timeout']) {
    final probePasses = outcome == 'ready';
    testWidgets(
      'XHTTP waits for tunnel traffic confirmation when the native owner is absent ($outcome)',
      (tester) async {
        final profile = await xhttpFixture();
        final requests = <String?>[];
        final clients = <_IdleHealthClient>[];
        final response = Completer<void>();
        await HttpOverrides.runZoned(
          () async {
            await launchWithProfile(
              tester,
              connected: false,
              initialProfile: profile,
              preferences: const {'vpnDisclosureVersion': 1},
            );
            nativeCalls.clear();
            scriptedStarts.add(true);
            final stopAck = Completer<bool>();
            if (!probePasses) pendingStopAck = stopAck;
            await tester.tap(find.byKey(powerKey));
            for (var frame = 0; frame < 20 && requests.isEmpty; frame++) {
              await tester.pump(const Duration(milliseconds: 250));
            }
            expect(requests, isNotEmpty);
            expect(
              requests,
              everyElement(
                'PROXY 127.0.0.1:${SingBoxConfigBuilder.localMixedProxyPort}',
              ),
            );
            expect(getVpnMutations(), ['saveConfig', 'startVPN']);
            expect(
              (await ProfileStore().loadProfileStabilityStats())[profile.id],
              isNull,
            );

            if (outcome == 'timeout') {
              // The mixed proxy does not open an HTTPS request before its
              // bounded connect timeout. Don't wait on the fake response.
              await tester.pump(const Duration(seconds: 4));
              expect(getVpnMutations(), ['saveConfig', 'startVPN']);
              await tester.pump(const Duration(seconds: 2));
            } else {
              response.complete();
            }
            if (!probePasses) {
              await pumpUntilNativeCall(tester, 'stopVPN');
              final startedClients = clients.where((client) => client.didDial);
              expect(startedClients, isNotEmpty);
              expect(
                startedClients.every((client) => client.forceClosed),
                isTrue,
              );
              nativeStatus = 'Stopped';
              stopAck.complete(true);
              pendingStopAck = null;
            }
            if (outcome == 'timeout') response.complete();
            for (var frame = 0; frame < 8; frame++) {
              await tester.pump(const Duration(milliseconds: 250));
            }
            await tester.pumpAndSettle();

            final stats = (await ProfileStore()
                .loadProfileStabilityStats())[profile.id]!;
            expect(stats.successfulStarts, probePasses ? 1 : 0);
            expect(stats.failedStarts, probePasses ? 0 : 1);
            expect(
              find.byKey(activeServerKey),
              probePasses ? findsOneWidget : findsNothing,
            );
            expect(getVpnMutations(), [
              'saveConfig',
              'startVPN',
              if (!probePasses) 'stopVPN',
            ]);
            expect(nativeCalls, isNot(contains('getDirectProbeNetwork')));
            expect(tester.takeException(), isNull);
          },
          createHttpClient: (_) {
            final client = _IdleHealthClient(
              probePasses,
              requests.add,
              gate: response.future,
            );
            clients.add(client);
            return client;
          },
        );
      },
      variant: const TargetPlatformVariant({TargetPlatform.windows}),
    );
  }

  testWidgets(
    'Stop cancels the startup proxy check and closes clients before native cleanup',
    (tester) async {
      final profile = await xhttpFixture();
      final response = Completer<void>();
      final requests = <String?>[];
      final clients = <_IdleHealthClient>[];
      await HttpOverrides.runZoned(
        () async {
          await launchWithProfile(
            tester,
            connected: false,
            initialProfile: profile,
            preferences: const {'vpnDisclosureVersion': 1},
          );
          nativeCalls.clear();
          scriptedStarts.add(true);
          await tester.tap(find.byKey(powerKey));
          for (var frame = 0; frame < 20 && requests.isEmpty; frame++) {
            await tester.pump(const Duration(milliseconds: 250));
          }
          expect(requests, isNotEmpty);
          expect(
            requests,
            everyElement(
              'PROXY 127.0.0.1:${SingBoxConfigBuilder.localMixedProxyPort}',
            ),
          );
          expect(getVpnMutations(), ['saveConfig', 'startVPN']);
          final stop = pendingStopAck = Completer<bool>();
          await tester.tap(find.byKey(powerKey));
          await pumpUntilNativeCall(tester, 'stopVPN');

          // Stop is still unacknowledged. Probe sockets must already be closed;
          // a late successful response must not finish the old startup.
          expect(response.isCompleted, isFalse);
          final dialed = clients.where((client) => client.didDial).toList();
          expect(dialed, isNotEmpty);
          expect(
            dialed,
            everyElement(predicate<_IdleHealthClient>((c) => c.forceClosed)),
          );
          expect(getVpnMutations(), ['saveConfig', 'startVPN', 'stopVPN']);
          nativeStatus = 'Stopped';
          pendingStopAck = null;
          stop.complete(true);
          await tester.pump(const Duration(milliseconds: 450));
          response.complete();
          await tester.pump(const Duration(seconds: 2));
          await tester.pumpAndSettle();

          expect(find.byKey(activeServerKey), findsNothing);
          expect(find.byTooltip('Подключить VPN'), findsOneWidget);
          expect(getVpnMutations(), ['saveConfig', 'startVPN', 'stopVPN']);
          expect(
            (await SharedPreferences.getInstance()).getBool(
              'manualDisconnectRequested',
            ),
            isTrue,
          );
          final stats = (await ProfileStore()
              .loadProfileStabilityStats())[profile.id];
          expect(stats?.successfulStarts ?? 0, 0);
          expect(stats?.lastHealthyAt, isNull);
          expect(tester.takeException(), isNull);
        },
        createHttpClient: (_) {
          final client = _IdleHealthClient(
            true,
            requests.add,
            gate: response.future,
          );
          clients.add(client);
          return client;
        },
      );
    },
    variant: const TargetPlatformVariant({TargetPlatform.windows}),
  );

  testWidgets(
    'a late health check result cannot change a manually stopped tunnel',
    (tester) async {
      final profile = await xhttpFixture();
      final response = Completer<void>();
      final requests = <String?>[];
      await HttpOverrides.runZoned(
        () async {
          await launchWithProfile(
            tester,
            connected: false,
            initialNativeStatus: 'Started',
            initialProfile: profile,
            waitForStopGuard: false,
          );
          nativeCalls.clear();
          await emitStreamError(tester, 'status');
          expect(requests, isNotEmpty);

          final stopAck = Completer<bool>();
          pendingStopAck = stopAck;
          await tester.tap(find.byKey(powerKey));
          await pumpUntilNativeCall(tester, 'stopVPN');
          nativeStatus = 'Stopped';
          stopAck.complete(true);
          pendingStopAck = null;
          await tester.pump(const Duration(milliseconds: 450));
          expect(find.byKey(activeServerKey), findsNothing);

          response.complete();
          for (var frame = 0; frame < 10; frame++) {
            await tester.pump(const Duration(milliseconds: 350));
          }
          expect(getVpnMutations(), ['stopVPN']);
          expect(find.byTooltip('Подключить VPN'), findsOneWidget);
          expect(
            (await ProfileStore().loadProfileStabilityStats())[profile.id],
            isNull,
          );
          expect(nativeStatus, 'Stopped');
          expect(tester.takeException(), isNull);
        },
        createHttpClient: (_) =>
            _IdleHealthClient(false, requests.add, gate: response.future),
      );
    },
    variant: const TargetPlatformVariant({TargetPlatform.windows}),
  );

  testWidgets(
    'fallback idle check validates a previously active tunnel through its proxy',
    (tester) async {
      final drafts = interceptExternalLinks();
      final profile = await xhttpFixture();
      final requests = <String?>[];
      final clients = <_IdleHealthClient>[];
      var now = DateTime.now();
      await HttpOverrides.runZoned(
        () async {
          await launchWithProfile(
            tester,
            initialProfile: profile,
            waitForStopGuard: false,
            viewport: const Size(380, 1200),
            vpnHealthNow: () => now,
          );
          await emitTraffic(tester, generation: 0);
          await tester.pump(const Duration(seconds: 1));
          nativeCalls.clear();
          requests.clear();
          clients.clear();

          // Data flowed before the pause: idle (3 min) is not stale (5 min).
          now = DateTime.now().add(const Duration(minutes: 4));
          await tester.pump(const Duration(seconds: 20));
          await tester.pump();
          expect(requests, isNotEmpty);
          expect(
            requests,
            everyElement(
              'PROXY 127.0.0.1:${SingBoxConfigBuilder.localMixedProxyPort}',
            ),
          );
          final stats = (await ProfileStore()
              .loadProfileStabilityStats())[profile.id]!;
          expect(stats.lastHealthyAt, isNotNull);
          expect(stats.healthFailures, 0);
          expect(find.text('Нет стабильного соединения'), findsNothing);
          expect(find.byKey(activeServerKey), findsOneWidget);
          expect(nativeStatus, 'Started');
          expect(nativeCalls, isNot(contains('getDirectProbeNetwork')));
          expect(getVpnMutations(), isEmpty);
          expect(clients.where((client) => client.didDial), isNotEmpty);
          expect(
            clients.where((client) => client.didDial),
            everyElement(predicate<_IdleHealthClient>((c) => c.forceClosed)),
          );
          await openSupportReport(tester);
          await tester.pumpAndSettle();
          final report = drafts.single.queryParameters['body']!;
          expect(
            report,
            contains('keeper_last_action: probe-ok:watchdog-idle'),
          );
          expect(
            report,
            contains('last_idle_health_check_local: ${now.toIso8601String()}'),
          );
          expect(tester.takeException(), isNull);
        },
        createHttpClient: (_) {
          final client = _IdleHealthClient(true, requests.add);
          clients.add(client);
          return client;
        },
      );
    },
    variant: const TargetPlatformVariant({TargetPlatform.windows}),
  );

  testWidgets(
    'Android leaves an idle tunnel running without inventing a failure',
    (tester) async {
      final profile = autoFixture('android-idle', 1443, 'PL');
      var now = DateTime.now();
      await launchWithProfile(
        tester,
        initialProfile: profile,
        connected: false,
        initialNativeStatus: 'Started',
        vpnHealthNow: () => now,
      );
      nativeCalls.clear();
      now = now.add(const Duration(minutes: 12));
      await tester.pump(const Duration(seconds: 20));
      await tester.pump();
      expect(nativeCalls, contains('getVPNStatus'));
      expect(find.text('Ожидание'), findsOneWidget);
      expect(find.text('Нет стабильного соединения'), findsNothing);
      expect(find.text('0 B'), findsOneWidget);
      expect(find.byKey(activeServerKey), findsOneWidget);
      expect(
        (await ProfileStore().loadProfileNetworkStabilityStats())[profile.id],
        isNull,
      );
      expect(nativeCalls, isNot(contains('getDirectProbeNetwork')));
      expect(getVpnMutations(), isEmpty);
    },
  );

  for (final scenario in ['handover grace', 'fresh readiness', 'sing-box']) {
    testWidgets(
      'fallback tunnel health chooses the safe check for $scenario',
      (tester) async {
        final drafts = interceptExternalLinks();
        final requests = <String?>[];
        final profile = scenario == 'sing-box'
            ? autoFixture('singbox-health', 1443, 'PL')
            : await xhttpFixture();
        var now = DateTime.now();
        await HttpOverrides.runZoned(() async {
          await launchWithProfile(
            tester,
            initialProfile: profile,
            connected: scenario == 'fresh readiness',
            initialNativeStatus: 'Started',
            waitForStopGuard: false,
            viewport: const Size(380, 1200),
            vpnHealthNow: () => now,
          );
          nativeCalls.clear();
          requests.clear();
          String keeper;
          final store = ProfileStore();
          if (scenario == 'handover grace') {
            networkSnapshot = {
              ...physicalSnapshot('cellular', '202'),
              'generation': 2,
            };
            platform.status.add({'status': 'Started', ...networkSnapshot});
            await tester.pump();
            // The readiness event can run the separate latency label check.
            // Measure only requests made after the stream error below.
            requests.clear();
            now = DateTime.now().add(const Duration(seconds: 1));
            await emitStreamError(tester, 'status');
            await tester.pump(const Duration(seconds: 2));
            expect(requests, isEmpty);
            expect(await store.loadProfileNetworkStabilityStats(), isEmpty);

            // During the grace period the stream error did not probe an
            // unsettled route. Afterwards the watchdog can check via VPN.
            now = now.add(const Duration(seconds: 80));
            await tester.pump(const Duration(seconds: 20));
            await tester.pump();
            expect(requests, isNotEmpty);
            expect(
              requests,
              everyElement(
                'PROXY 127.0.0.1:${SingBoxConfigBuilder.localMixedProxyPort}',
              ),
            );
            final stats = (await store
                .loadProfileNetworkStabilityStats())[profile.id]?['cellular'];
            expect(stats?.lastHealthyAt, isNotNull);
            expect(stats?.healthFailures, 0);
            keeper = 'probe-ok:watchdog';
          } else if (scenario == 'fresh readiness') {
            // The native readiness event already supplied a recent healthy
            // timestamp; the counter stream hasn't delivered any samples.
            now = DateTime.now().add(const Duration(seconds: 1));
            await emitStreamError(tester, 'status');
            final stats = (await store
                .loadProfileNetworkStabilityStats())[profile.id]?['wifi'];
            expect(stats?.lastHealthyAt, isNotNull);
            expect(stats?.healthFailures, 0);
            expect(stats?.trafficBytes, 0);
            expect(requests, isEmpty);
            keeper = 'traffic-ok:engine-stream-status';
          } else {
            now = now.add(const Duration(minutes: 4));
            await tester.pump(const Duration(seconds: 20));
            await tester.pump();
            expect(requests, isEmpty);
            expect(await store.loadProfileNetworkStabilityStats(), isEmpty);
            expect(find.text('Ожидание'), findsOneWidget);
            keeper = 'native-status-ok:watchdog-idle';
          }

          await openSupportReport(tester);
          await tester.pumpAndSettle();
          final report = drafts.single.queryParameters['body']!;
          expect(report, contains('keeper_last_action: $keeper'));
          if (scenario == 'handover grace') {
            expect(
              report,
              contains(
                'keeper:health-skip-network-changing:engine-stream-status',
              ),
            );
          }
          expect(nativeStatus, 'Started');
          expect(getVpnMutations(), isEmpty);
          expect(nativeCalls, isNot(contains('getDirectProbeNetwork')));
          expect(tester.takeException(), isNull);
        }, createHttpClient: (_) => _IdleHealthClient(true, requests.add));
      },
      variant: const TargetPlatformVariant({TargetPlatform.windows}),
    );
  }

  for (final probePasses in [true, false]) {
    testWidgets(
      'idle tunnel fallback checks the proxied path without restarting it (passes=$probePasses)',
      (tester) async {
        final requests = <String?>[];
        final profile = await xhttpFixture();
        final base = DateTime.now();
        var now = base;
        await HttpOverrides.runZoned(
          () async {
            await launchWithProfile(
              tester,
              initialProfile: profile,
              connected: false,
              initialNativeStatus: 'Started',
              vpnHealthNow: () => now,
            );
            nativeCalls.clear();
            requests.clear();
            now = base.add(const Duration(minutes: 4));
            await tester.pump(const Duration(seconds: 20));
            for (var i = 0; i < 8; i++) {
              await tester.pump(const Duration(milliseconds: 350));
            }
            expect(requests, isNotEmpty);
            expect(
              requests,
              everyElement(
                'PROXY 127.0.0.1:${SingBoxConfigBuilder.localMixedProxyPort}',
              ),
            );
            final store = ProfileStore();
            final stats = (await store
                .loadProfileNetworkStabilityStats())[profile.id]!['wifi']!;
            if (probePasses) {
              expect(stats.lastHealthyAt, isNotNull);
              expect(stats.healthFailures, 0);
              expect(find.text('Ожидание'), findsOneWidget);
              final before = requests.length;
              now = now.add(const Duration(seconds: 20));
              await tester.pump(const Duration(seconds: 20));
              await tester.pump();
              expect(requests, hasLength(before));
              final withinCooldown = (await store
                  .loadProfileNetworkStabilityStats())[profile.id]!['wifi']!;
              expect(withinCooldown.lastHealthyAt, stats.lastHealthyAt);
            } else {
              expect(stats.healthFailures, 1);
              expect(stats.lastFailureReason, 'health-probe:watchdog-idle');
              now = base.add(const Duration(minutes: 6));
              await tester.pump(const Duration(seconds: 20));
              for (var i = 0; i < 8; i++) {
                await tester.pump(const Duration(milliseconds: 350));
              }
              final stale = (await store
                  .loadProfileNetworkStabilityStats())[profile.id]!['wifi']!;
              expect(stale.healthFailures, 2);
              expect(stale.lastFailureReason, 'health-probe:watchdog-stale');
              expect(find.text('Нет стабильного соединения'), findsOneWidget);
            }
            expect(nativeStatus, 'Started');
            expect(nativeCalls, isNot(contains('getDirectProbeNetwork')));
            expect(getVpnMutations(), isEmpty);
            expect(tester.takeException(), isNull);
          },
          createHttpClient: (_) => _IdleHealthClient(probePasses, requests.add),
        );
      },
      variant: const TargetPlatformVariant({TargetPlatform.windows}),
    );
  }

  for (final probePasses in [true, false]) {
    testWidgets(
      'support report records a completed idle tunnel check with zero user traffic (passes=$probePasses)',
      (tester) async {
        final drafts = interceptExternalLinks();
        final clipboard = interceptClipboardWrites();
        final requests = <String?>[];
        final profile = await xhttpFixture();
        var now = DateTime.now();
        await HttpOverrides.runZoned(() async {
          await launchWithProfile(
            tester,
            initialProfile: profile,
            connected: false,
            initialNativeStatus: 'Started',
            viewport: const Size(380, 1200),
            vpnHealthNow: () => now,
          );
          nativeCalls.clear();
          requests.clear();
          now = now.add(const Duration(minutes: 4));
          await tester.pump(const Duration(seconds: 20));
          for (var frame = 0; frame < 8; frame++) {
            await tester.pump(const Duration(milliseconds: 350));
          }
          expect(requests, isNotEmpty);
          expect(
            requests,
            everyElement(
              'PROXY 127.0.0.1:${SingBoxConfigBuilder.localMixedProxyPort}',
            ),
          );
          expect(find.byKey(activeServerKey), findsOneWidget);
          final stats = (await ProfileStore()
              .loadProfileNetworkStabilityStats())[profile.id]!['wifi']!;
          expect(stats.trafficBytes, 0);
          expect(stats.healthFailures, probePasses ? 0 : 1);

          await openSupportReport(tester);
          await tester.pumpAndSettle();
          final draft = drafts.single;
          expect(draft.scheme, 'mailto');
          final report = draft.queryParameters['body']!;
          for (final line in [
            'status: Started',
            'idle_health_checks: 1',
            'health_failures: ${probePasses ? 0 : 1}',
            'last_idle_health_check_local: ${now.toIso8601String()}',
            'keeper_last_action: probe-${probePasses ? 'ok' : 'failed'}:watchdog-idle',
            'traffic: up=0 B/s down=0 B/s total=0 B',
          ]) {
            expect(report, contains('\n$line\n'));
          }
          expect(clipboard, isEmpty);
          expect(nativeCalls, isNot(contains('getDirectProbeNetwork')));
          expect(getVpnMutations(), isEmpty);
          expect(nativeStatus, 'Started');
          expect(tester.takeException(), isNull);
        }, createHttpClient: (_) => _IdleHealthClient(probePasses, requests.add));
      },
      variant: const TargetPlatformVariant({TargetPlatform.windows}),
    );
  }

  for (final changesBeforePublish in [false, true]) {
    testWidgets(
      'direct latency publishes only on the checked physical network (changed=$changesBeforePublish)',
      (tester) async {
        final base = autoFixture('direct-latency-fixture', 1443, 'PL');
        final profile = base.copyWith(
          server: '1.1.1.1',
          outbound: {...base.outbound!, 'server': '1.1.1.1'},
        );
        killSwitch = {'known': true, 'supported': true, 'vpnActive': false};
        pendingDirectGate = Completer<String?>()..complete('test-wifi');
        final socket = _FixtureLatencySocket();
        var dials = 0;
        var cancellations = 0;
        await IOOverrides.runZoned(
          () async {
            await launchWithProfile(
              tester,
              connected: false,
              initialProfile: profile,
              extraProfiles: [offlineProfile],
              preferences: const {'directLatencyAllowed': true},
            );
            await tester.tap(find.byKey(serverPickerKey));
            await tester.pumpAndSettle();
            nativeCalls.clear();
            await tester.tap(find.byKey(checkServersKey));
            await tester.pumpAndSettle();
            final reading = find.textContaining(
              RegExp(r'^TCP \d+ мс · напрямую$'),
            );
            expect(
              reading,
              changesBeforePublish ? findsNothing : findsOneWidget,
            );
            if (changesBeforePublish) {
              expect(find.textContaining('Нет прямого замера'), findsOneWidget);
            }
            expect(dials, 1);
            expect(socket.destroyed, isTrue);
            expect(cancellations, 1);
            expect(getVpnMutations(), isEmpty);
            expect(tester.takeException(), isNull);
          },
          socketStartConnect:
              (host, port, {sourceAddress, sourcePort = 0}) async {
                dials++;
                expect(host, InternetAddress('1.1.1.1'));
                expect(port, 1443);
                if (changesBeforePublish) {
                  pendingDirectGate = Completer<String?>()
                    ..complete('test-cellular');
                }
                return ConnectionTask.fromSocket(
                  Future<Socket>.value(socket),
                  () => cancellations++,
                );
              },
        );
      },
    );
  }

  testWidgets(
    'a stalled direct latency batch clears the old result and cancels a late socket',
    (tester) async {
      final fixture = autoFixture('stalled-direct-latency', 1443, 'PL');
      final profile = fixture.copyWith(
        server: '1.1.1.1',
        outbound: {...fixture.outbound!, 'server': '1.1.1.1'},
      );
      killSwitch = {'known': true, 'supported': true, 'vpnActive': false};
      pendingDirectGate = Completer<String?>()..complete('test-wifi');
      final stalledDial = Completer<ConnectionTask<Socket>>();
      var dials = 0;
      var lateCancellations = 0;
      await IOOverrides.runZoned(
        () async {
          await launchWithProfile(
            tester,
            connected: false,
            initialProfile: profile,
            preferences: const {'directLatencyAllowed': true},
          );
          await tester.tap(find.byKey(serverPickerKey));
          await tester.pumpAndSettle();
          final check = find.byKey(checkServersKey);
          final reading = find.textContaining(
            RegExp(r'^TCP \d+ мс · напрямую$'),
          );
          nativeCalls.clear();
          await tester.tap(check);
          await tester.pumpAndSettle();
          expect(reading, findsOneWidget);
          expect(dials, 1);

          await tester.tap(check);
          await tester.pump();
          expect(dials, 2);
          await tester.pump(const Duration(seconds: 12));
          await tester.pumpAndSettle();
          expect(find.textContaining('Нет прямого замера'), findsOneWidget);
          expect(reading, findsNothing);
          expect(tester.widget<IconButton>(check).onPressed, isNotNull);

          final lateSocket = _FixtureLatencySocket();
          stalledDial.complete(
            ConnectionTask.fromSocket(Future<Socket>.value(lateSocket), () {
              lateCancellations++;
              lateSocket.destroy();
            }),
          );
          await tester.pump();
          expect(lateCancellations, 1);
          expect(lateSocket.destroyed, isTrue);
          expect(reading, findsNothing);
          expect(dials, 2);
          expect(getVpnMutations(), isEmpty);
          expect(tester.takeException(), isNull);
        },
        socketStartConnect:
            (host, port, {sourceAddress, sourcePort = 0}) async {
              expect(host, InternetAddress('1.1.1.1'));
              expect(port, 1443);
              if (++dials == 2) return stalledDial.future;
              return ConnectionTask.fromSocket(
                Future<Socket>.value(_FixtureLatencySocket()),
                () {},
              );
            },
      );
    },
  );

  testWidgets(
    'watchdog does not confuse a missing Android status reply with a stop',
    (tester) async {
      final profile = autoFixture('missing-status', 1443, 'PL');
      await launchWithProfile(tester, initialProfile: profile);
      nativeCalls.clear();
      statusReadError = PlatformException(code: 'STATUS_FIXTURE_FAILURE');
      await tester.pump(const Duration(seconds: 20));
      await tester.pump();
      expect(nativeCalls, contains('getVPNStatus'));
      expect(find.byKey(activeServerKey), findsOneWidget);
      expect(find.textContaining('VPN остановлен неожиданно'), findsNothing);
      expect(
        (await ProfileStore().loadProfileNetworkStabilityStats())[profile.id],
        isNull,
      );
      expect(getVpnMutations(), isEmpty);

      statusReadError = null;
      nativeStatus = 'Stopped';
      await tester.pump(const Duration(seconds: 20));
      await tester.pump();
      final stats = (await ProfileStore()
          .loadProfileNetworkStabilityStats())[profile.id]!['wifi']!;
      expect(stats.healthFailures, 1);
      expect(stats.lastFailureReason, 'unexpected-stop:watchdog');
      expect(find.byKey(activeServerKey), findsNothing);
      expect(getVpnMutations(), isEmpty);
    },
  );

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

  testWidgets(
    'native stop and recovery render correctly without any saved profiles',
    (tester) async {
      await launchWithProfile(
        tester,
        connected: false,
        seedProfile: false,
        initialNativeStatus: 'Started',
      );
      nativeCalls.clear();
      expect(find.byTooltip('Отключить VPN'), findsOneWidget);
      expect(find.byKey(activeServerKey), findsNothing);

      nativeStatus = 'Stopped';
      platform.status.add({
        ...networkSnapshot,
        'status': 'Stopped',
        'manualDisconnectRequested': false,
      });
      await tester.pumpAndSettle();
      expect(
        find.text('VPN остановлен. Открой логи sing-box.'),
        findsOneWidget,
      );
      expect(powerSurface(tester), YurichMobileColors.powerError);
      expect(getVpnMutations(), isEmpty);

      nativeStatus = 'Started';
      platform.status.add({
        ...networkSnapshot,
        'status': 'Started',
        'manualDisconnectRequested': false,
      });
      await tester.pumpAndSettle();
      expect(find.text('VPN остановлен. Открой логи sing-box.'), findsNothing);
      expect(find.byTooltip('Отключить VPN'), findsOneWidget);
      expect(find.byKey(activeServerKey), findsNothing);
      expect(await ProfileStore().loadProfiles(), isEmpty);
      expect(await ProfileStore().loadSelectedProfileId(), isNull);
      expect(getVpnMutations(), isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'foreground watchdog honors the resume settle window without a duplicate VPN command',
    (tester) async {
      final drafts = interceptExternalLinks();
      var now = DateTime.now();
      await launchWithProfile(
        tester,
        connected: false,
        initialNativeStatus: 'Started',
        initialProfile: autoFixture('resume-quiet-fixture', 1443, 'PL'),
        viewport: const Size(380, 1200),
        vpnHealthNow: () => now,
      );
      nativeCalls.clear();
      binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      now = DateTime.now().add(const Duration(seconds: 3));
      await tester.pump(const Duration(seconds: 2));
      await tester.pump(const Duration(seconds: 5));
      await tester.pump();
      final readsAfterResume = nativeCalls
          .where((call) => call == 'getVPNStatus')
          .length;
      expect(readsAfterResume, 2);
      await tester.pump(const Duration(seconds: 13));
      await tester.pump();
      expect(
        nativeCalls.where((call) => call == 'getVPNStatus'),
        hasLength(readsAfterResume + 1),
      );
      expect(find.byKey(activeServerKey), findsOneWidget);
      await openSupportReport(tester);
      await tester.pumpAndSettle();
      expect(
        drafts.single.queryParameters['body'],
        contains('keeper_last_action: watchdog-resume-quiet'),
      );
      expect(getVpnMutations(), isEmpty);
      expect(nativeCalls, isNot(contains('getDirectProbeNetwork')));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'background traffic and a native stop persist Wi-Fi health without a second start',
    (tester) async {
      final profile = autoFixture('background-health', 1443, 'PL');
      await launchWithProfile(
        tester,
        connected: false,
        initialNativeStatus: 'Started',
        initialProfile: profile,
      );
      binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      nativeCalls.clear();
      final store = ProfileStore();

      Future<void> sendTraffic(int total) async {
        platform.traffic.add({...networkSnapshot, 'sessionTotal': total});
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
      }

      Future<int?> bytesSaved() async =>
          (await store.loadProfileNetworkStabilityStats())[profile.id]?['wifi']
              ?.trafficBytes;
      await sendTraffic(1024);
      expect(await bytesSaved(), 1024);
      await sendTraffic(2048);
      expect(await bytesSaved(), 1024);
      const total = 2 * 1024 * 1024;
      await sendTraffic(total);
      expect(await bytesSaved(), total);

      nativeStatus = 'Stopped';
      platform.status.add({
        ...networkSnapshot,
        'status': 'Stopped',
        'manualDisconnectRequested': false,
      });
      await tester.pumpAndSettle();

      final stability = (await store.loadProfileStabilityStats())[profile.id]!;
      expect(stability.failedStarts, 1);
      final wifi = (await store
          .loadProfileNetworkStabilityStats())[profile.id]!['wifi']!;
      expect(wifi.healthFailures, 1);
      expect(wifi.lastFailureReason, 'unexpected-stop:status-event');
      expect(wifi.trafficBytes, total);
      expect(getVpnMutations(), isEmpty);
      // A paused Flutter surface does not rebuild until the app returns.
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      await tester.pump(const Duration(seconds: 3));
      expect(find.byKey(activeServerKey), findsNothing);
      expect(getVpnMutations(), isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

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

  testWidgets(
    'TV Home wires profile import, settings, links and connection without mobile side effects',
    (tester) async {
      final urls = interceptExternalLinks();
      final first = autoFixture(
        'tv-original',
        1443,
        'PL',
      ).copyWith(name: '🇵🇱 Fixture original');
      final alternate = await xhttpFixture();
      final udp = udpProfile.copyWith(
        id: 'tv-udp-variant',
        name: 'Fixture UDP',
      );
      final vless = (await ProfileImporter().importFromText(
        'vless://11111111-1111-4111-8111-111111111111@127.0.0.1:3443'
        '?security=tls&type=tcp&sni=fixture.invalid#FixtureTLS',
      )).single.copyWith(countryCode: 'PL');
      await launchWithProfile(
        tester,
        initialProfile: first,
        extraProfiles: [alternate, udp, vless],
        connected: false,
        tvMode: true,
        viewport: const Size(1280, 720),
        updateService: _TestHomeUpdater(channel: AppDistributionChannel.tv),
        preferences: const {
          'vpnDisclosureVersion': 1,
          'smartRouteRuDirect': false,
        },
      );
      TvHomeScreen tv() =>
          tester.widget<TvHomeScreen>(find.byType(TvHomeScreen));
      expect(tv().profiles.map((profile) => profile.group), [
        TvProtocolGroup.naive,
        TvProtocolGroup.xhttp,
        TvProtocolGroup.hysteria,
        TvProtocolGroup.vless,
      ]);
      expect(tv().profiles.first.name, 'Fixture original');
      await tester.tap(find.byKey(ValueKey('tv-profile-${alternate.id}')));
      await tester.pumpAndSettle();
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('selectedProfileId'), alternate.id);
      expect(
        tv().profiles.singleWhere((profile) => profile.selected).id,
        alternate.id,
      );

      nativeCalls.clear();
      await tester.tap(find.byKey(const ValueKey('tv-refresh')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('tv-import-input')), findsOneWidget);
      await tester.tap(find.byTooltip('Закрыть'));
      await tester.pumpAndSettle();
      expect((await ProfileStore().loadProfiles()), hasLength(4));

      await tester.tap(find.byKey(const ValueKey('tv-import')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('tv-import-input')),
        'hy2://fixture@127.0.0.1:4443#Poland%20TV',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('tv-import-submit')));
      await tester.pumpAndSettle();
      expect((await ProfileStore().loadProfiles()), hasLength(5));
      expect(
        tv().profiles.singleWhere((profile) => profile.selected).group,
        TvProtocolGroup.hysteria,
      );

      await tester.tap(find.byKey(const ValueKey('tv-settings-tab')));
      await tester.pumpAndSettle();
      for (final key in ['tv-smart-route', 'tv-auto-dns', 'tv-language']) {
        final control = find.byKey(ValueKey(key));
        await tester.ensureVisible(control);
        await tester.tap(control);
        await tester.pumpAndSettle();
      }
      expect(prefs.getBool('smartRouteRuDirect'), isTrue);
      expect(prefs.getString('dnsProtectionMode'), 'leak_guard');
      expect(prefs.getString('languageCode'), 'en');
      for (final text in ['TV releases on GitHub', 'Privacy policy']) {
        final item = find.text(text);
        await tester.ensureVisible(item);
        await tester.tap(item);
        await tester.pumpAndSettle();
      }
      expect(urls.map((uri) => (uri.host, uri.path)), [
        ('github.com', '/ivan-yurich/Yurich-Connect-Android/releases'),
        (
          'github.com',
          '/ivan-yurich/Yurich-Connect-Android/blob/main/PRIVACY.md',
        ),
      ]);
      expect(getVpnMutations(), isEmpty);

      scriptedStarts.add(true);
      await tester.tap(find.byKey(const ValueKey('tv-connect')));
      await pumpUntilNativeCall(tester, 'startVPN');
      await tester.pump(const Duration(milliseconds: 700));
      await tester.pumpAndSettle();
      expect(tv().connected, isTrue);
      expect(getVpnMutations(), ['saveConfig', 'startVPN']);
      expect(nativeConfigs.single, contains('"server_port":4443'));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 10));
    },
  );

  testWidgets(
    'TV log stream is bounded, strips terminal escapes and hides fixture credentials',
    (tester) async {
      await launchWithProfile(
        tester,
        connected: false,
        tvMode: true,
        viewport: const Size(1280, 720),
      );
      await tester.tap(find.byKey(const ValueKey('tv-logs-tab')));
      await tester.pumpAndSettle();
      expect(platform.logs.hasListener, isTrue);
      platform.logs.add({'type': 'other', 'message': 'fixture-ignored-event'});
      platform.logs.add({'type': 'log', 'message': ''});
      for (var i = 0; i < 270; i++) {
        platform.logs.add({
          'type': 'log',
          'message':
              ' \x1B[32mfixture-stream-$i Bearer fixture-private-bearer\x1B[0m ',
        });
      }
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      final logs = tester.widget<TvHomeScreen>(find.byType(TvHomeScreen)).logs;
      expect(logs, hasLength(180));
      expect(logs.first, 'fixture-stream-90 Bearer ***');
      expect(logs.last, 'fixture-stream-269 Bearer ***');
      expect(
        logs.join('\n'),
        allOf(
          isNot(contains('fixture-private-bearer')),
          isNot(contains('fixture-ignored-event')),
          isNot(contains('\x1B')),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('tv-profiles-tab')));
      await tester.pumpAndSettle();
      expect(platform.logs.hasListener, isFalse);
      expect(getVpnMutations(), isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('TV log stream survives a malformed event and a platform error', (
    tester,
  ) async {
    await launchWithProfile(
      tester,
      connected: false,
      tvMode: true,
      viewport: const Size(1280, 720),
    );
    await tester.tap(find.byKey(const ValueKey('tv-logs-tab')));
    await tester.pumpAndSettle();
    platform.logs.add({'type': 'log', 'message': false});
    platform.logs.addError(
      PlatformException(
        code: 'LOG_FIXTURE_ERROR',
        message: 'Bearer fixture-stream-only',
      ),
    );
    platform.logs.add({'type': 'log', 'message': 'fixture-log-after-errors'});
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    final logs = tester.widget<TvHomeScreen>(find.byType(TvHomeScreen)).logs;
    expect(
      logs.where((line) => line.contains('Engine stream error [log]')),
      hasLength(2),
    );
    expect(logs, contains('fixture-log-after-errors'));
    expect(logs.join('\n'), isNot(contains('fixture-stream-only')));
    expect(platform.logs.hasListener, isTrue);
    expect(getVpnMutations(), isEmpty);
    expect(tester.takeException(), isNull);
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

  for (final (mode, tv, launch) in [('mobile', false, entrypoint.main)]) {
    testWidgets('app entry point launches $mode without starting VPN', (
      tester,
    ) async {
      nativeStatus = 'Stopped';
      tester.view.physicalSize = tv
          ? const Size(960, 540)
          : const Size(390, 820);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);

      final dispatcher = ui.PlatformDispatcher.instance;
      final originalFrameworkHandler = FlutterError.onError;
      final originalEngineHandler = dispatcher.onError;
      late final void Function(FlutterErrorDetails)? frameworkHandler;
      late final ui.ErrorCallback? engineHandler;
      Zone? appZone;
      try {
        // Capture the child zone runZonedGuarded enters in the entry point.
        runZoned(
          launch,
          zoneSpecification: ZoneSpecification(
            run: <R>(self, parent, zone, R Function() callback) {
              if (!identical(self.errorZone, zone.errorZone)) appZone ??= zone;
              return parent.run(zone, callback);
            },
          ),
        );
        frameworkHandler = FlutterError.onError;
        engineHandler = dispatcher.onError;
      } finally {
        // Keep flutter_test in charge of real framework errors during pumping.
        FlutterError.onError = originalFrameworkHandler;
        dispatcher.onError = originalEngineHandler;
      }
      await tester.pumpAndSettle();
      expect(
        tester.widget<YurichConnectApp>(find.byType(YurichConnectApp)).tvMode,
        tv,
      );
      expect(find.byType(TvHomeScreen), tv ? findsOneWidget : findsNothing);
      expect(getVpnMutations(), isEmpty);
      expect(frameworkHandler, isNot(same(originalFrameworkHandler)));
      expect(engineHandler, isNot(same(originalEngineHandler)));

      if (!tv) {
        final records = <MethodCall>[];
        final presentation = <FlutterErrorDetails>[];
        final originalPresent = FlutterError.presentError;
        final originalPrint = debugPrint;
        final messenger = binding.defaultBinaryMessenger;
        const channel = OnDeviceDiagnosticsService.channel;
        messenger.setMockMethodCallHandler(channel, (call) async {
          records.add(call);
          return null;
        });
        addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
        final error = StateError('fixture startup detail');
        final details = FlutterErrorDetails(exception: error);
        late final bool handled;
        try {
          FlutterError.presentError = presentation.add;
          debugPrint = (_, {wrapWidth}) {};
          expect(appZone, isNotNull);
          appZone!.run(() {
            frameworkHandler!(details);
            handled = engineHandler!(error, StackTrace.current);
          });
        } finally {
          debugPrint = originalPrint;
          FlutterError.presentError = originalPresent;
        }
        await tester.pump();
        expect(handled, isTrue);
        expect(presentation, [details]);
        expect(records.map((call) => call.method), [
          'recordError',
          'recordError',
        ]);
        for (final call in records) {
          expect(call.arguments, {'type': 'uncaught'});
        }
      }

      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 10));
    });
  }

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

class _HomeQrScanner extends MobileScannerPlatform {
  final frames = StreamController<BarcodeCapture?>.broadcast();

  @override
  Stream<BarcodeCapture?> get barcodesStream => frames.stream;

  @override
  Stream<TorchState> get torchStateStream => const Stream.empty();

  @override
  Stream<double> get zoomScaleStateStream => const Stream.empty();

  @override
  Widget buildCameraView() => const SizedBox.expand();

  @override
  Future<MobileScannerViewAttributes> start(StartOptions startOptions) async =>
      const MobileScannerViewAttributes(
        cameraDirection: CameraFacing.back,
        currentTorchMode: TorchState.unavailable,
        size: Size(640, 480),
      );

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async {}
}

class _IdleHealthClient extends Fake implements HttpClient {
  _IdleHealthClient(this.passes, this.recordRoute, {this.gate});

  final bool passes;
  final void Function(String?) recordRoute;
  final Future<void>? gate;
  bool didDial = false;
  bool forceClosed = false;

  @override
  Duration? connectionTimeout;

  @override
  String Function(Uri)? findProxy;

  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    didDial = true;
    recordRoute(findProxy?.call(url));
    if (gate case final pending?) await pending;
    return _IdleHealthRequest(passes ? 204 : 503);
  }

  @override
  void close({bool force = false}) {
    if (force) forceClosed = true;
  }
}

class _FixtureLatencySocket extends Fake implements Socket {
  bool destroyed = false;

  @override
  void destroy() => destroyed = true;
}

class _IdleHealthRequest extends Fake implements HttpClientRequest {
  _IdleHealthRequest(this.status);

  final int status;

  @override
  final HttpHeaders headers = _IdleHealthHeaders();

  @override
  bool followRedirects = false;

  @override
  Future<HttpClientResponse> close() async => _IdleHealthResponse(status);
}

class _IdleHealthHeaders extends Fake implements HttpHeaders {
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {}
}

class _IdleHealthResponse extends Fake implements HttpClientResponse {
  _IdleHealthResponse(this.statusCode);

  @override
  final int statusCode;
}

class _ScriptedSubscriptionImporter extends ProfileImporter {
  _ScriptedSubscriptionImporter(this.responses);

  final Map<String, Future<List<VpnProfile>> Function()> responses;
  final sources = <String>[];
  final tunnelOnly = <bool>[];

  @override
  Future<List<VpnProfile>> importFromText(
    String input, {
    bool currentTunnelOnly = false,
  }) async {
    sources.add(input);
    tunnelOnly.add(currentTunnelOnly);
    final response = responses[input];
    if (response == null) throw StateError('Unexpected fixture subscription');
    return response();
  }
}

class _ScriptedHomeGeo extends ProfileGeoService {
  _ScriptedHomeGeo({this.endpointResult, this.endpointGate});

  final ProfileGeo? endpointResult;
  final Future<ProfileGeo?>? endpointGate;
  final endpointIds = <String>[];
  final exitLookups =
      <
        ({ProfileGeoCancellation cancellation, Completer<ProfileGeo?> response})
      >[];

  @override
  Future<ProfileGeo?> resolveEndpointCountry(VpnProfile profile) async {
    endpointIds.add(profile.id);
    if (endpointGate case final gate?) return gate;
    return endpointResult;
  }

  @override
  Future<ProfileGeo?> resolveExitCountryThroughTunnel({
    ProfileGeoCancellation? cancellation,
  }) {
    final response = Completer<ProfileGeo?>();
    exitLookups.add((cancellation: cancellation!, response: response));
    return response.future;
  }
}

class _ProfileWriteFailureStore extends TestFlutterSecureStoragePlatform {
  _ProfileWriteFailureStore(super.data);

  int writeAttempts = 0;

  @override
  Future<void> write({
    required String key,
    required String value,
    required Map<String, String> options,
  }) async {
    if (key == 'profiles.v1') {
      writeAttempts++;
      throw PlatformException(code: 'FIXTURE_STORAGE_UNAVAILABLE');
    }
    await super.write(key: key, value: value, options: options);
  }
}

class _GatedSubscriptionProfileStore extends TestFlutterSecureStoragePlatform {
  _GatedSubscriptionProfileStore(super.data);

  final commit = Completer<void>();
  int writes = 0;

  @override
  Future<void> write({
    required String key,
    required String value,
    required Map<String, String> options,
  }) async {
    if (key == 'profiles.v1') {
      writes++;
      await commit.future;
    }
    await super.write(key: key, value: value, options: options);
  }
}

class _DelayedManualStopStore extends InMemorySharedPreferencesStore {
  _DelayedManualStopStore(super.data) : super.withData();
  final gate = Completer<void>();
  int writes = 0;

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    if (key == 'flutter.manualDisconnectRequested' && value == true) {
      writes++;
      await gate.future;
    }
    return super.setValue(valueType, key, value);
  }
}

class _RejectSubscriptionDeadlineStore extends InMemorySharedPreferencesStore {
  _RejectSubscriptionDeadlineStore(super.data) : super.withData();

  int rejectedWrites = 0;

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    if (key == 'flutter.nextSubscriptionRefreshAt') {
      rejectedWrites++;
      return false;
    }
    return super.setValue(valueType, key, value);
  }
}

class _PendingSubscriptionDeadlineStore extends ProfileStore {
  _PendingSubscriptionDeadlineStore(this.answer);

  final Future<DateTime?> answer;
  int deadlineReads = 0;

  @override
  Future<DateTime?> loadNextSubscriptionRefreshAt() {
    deadlineReads++;
    return answer;
  }
}

class _RejectVpnDisclosureStore extends InMemorySharedPreferencesStore {
  _RejectVpnDisclosureStore(super.data) : super.withData();

  int rejectedWrites = 0;

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    if (key == 'flutter.vpnDisclosureVersion') {
      rejectedWrites++;
      throw PlatformException(
        code: 'FIXTURE_DISCLOSURE_WRITE_ERROR',
        message: 'fixture-private-storage',
      );
    }
    return super.setValue(valueType, key, value);
  }
}

class _RejectDirectLatencyOptIn extends InMemorySharedPreferencesStore {
  _RejectDirectLatencyOptIn(super.data, {required this.throws})
    : super.withData();

  final bool throws;
  int rejectedWrites = 0;

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    if (key == 'flutter.directLatencyAllowed' && value == true) {
      rejectedWrites++;
      if (throws) throw PlatformException(code: 'FIXTURE_CONSENT_WRITE_ERROR');
      return false;
    }
    return super.setValue(valueType, key, value);
  }
}

class _TestHomeUpdater extends AppUpdateService {
  _TestHomeUpdater({
    this.channel = AppDistributionChannel.github,
    this.expectedVersion = '1.0.126',
  });

  AppDistributionChannel channel;
  final String expectedVersion;
  final release = AppUpdateInfo(
    version: '1.0.132',
    assetName: 'fixture.apk',
    downloadUrl: Uri.parse('https://update.example.invalid/fixture.apk'),
    size: 4,
  );
  final apk = File('fixture.apk');
  final downloads = <AppUpdateInfo>[];
  final installations = <(String, int?, String?)>[];
  AppUpdateInfo? noticeRelease;
  Future<AppUpdateInfo?>? noticeGate;
  bool manualIsCurrent = false;
  Object? lookupError;
  Object? noticeError;
  Object? downloadError;
  Object? installError;
  Object? distributionError;
  Future<AppDistributionChannel>? distributionGate;
  Future<List<String>>? abiGate;
  List<String> expectedAbis = const ['arm64-v8a'];
  Completer<File>? downloadGate;
  Completer<void>? installGate;
  void Function(double?)? progress;
  int manualChecks = 0;
  int noticeChecks = 0;
  int settingsOpens = 0;

  @override
  Future<AppDistributionChannel> distributionChannel() async {
    if (distributionError case final error?) throw error;
    if (distributionGate case final gate?) return gate;
    return channel;
  }

  @override
  Future<List<String>> supportedAbis() async {
    if (abiGate case final gate?) return gate;
    return ['arm64-v8a'];
  }

  @override
  Future<AppUpdateInfo?> findLatest({
    required String currentVersion,
    required List<String> supportedAbis,
    Duration timeout = const Duration(seconds: 60),
  }) async {
    expect(currentVersion, expectedVersion);
    expect(supportedAbis, expectedAbis);
    if (timeout == const Duration(seconds: 26)) {
      noticeChecks++;
      if (noticeError case final error?) throw error;
      if (noticeGate case final gate?) return gate;
      return noticeRelease;
    }
    expect(timeout, const Duration(seconds: 60));
    manualChecks++;
    if (lookupError case final error?) throw error;
    return manualIsCurrent ? null : release;
  }

  @override
  Future<File> download(
    AppUpdateInfo update, {
    required void Function(double? progress) onProgress,
  }) async {
    downloads.add(update);
    progress = onProgress;
    if (downloadError case final error?) throw error;
    return await downloadGate?.future ?? apk;
  }

  @override
  Future<void> installApk(
    File file, {
    int? currentBuildNumber,
    String? expectedVersion,
  }) async {
    installations.add((file.path, currentBuildNumber, expectedVersion));
    if (installError case final error?) throw error;
    await installGate?.future;
  }

  @override
  Future<void> openInstallSettings() async => settingsOpens++;
}
