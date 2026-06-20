import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_singbox_vpn/flutter_singbox.dart';
import 'package:flutter_singbox_vpn/flutter_singbox_platform_interface.dart';
import 'package:flutter_singbox_vpn/flutter_singbox_method_channel.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class MockFlutterSingboxPlatform
    with MockPlatformInterfaceMixin
    implements FlutterSingboxPlatform {
  @override
  Future<String?> getPlatformVersion() => Future.value('42');

  @override
  Future<bool> saveConfig(String config) => Future.value(true);

  @override
  Future<String> getConfig() => Future.value('{"test": "config"}');

  @override
  Future<bool> startVPN() => Future.value(true);

  @override
  Future<bool> stopVPN() => Future.value(true);

  @override
  Future<String> getVPNStatus() => Future.value('Stopped');

  @override
  Stream<Map<String, dynamic>> get onStatusChanged =>
      Stream.value({'status': 'Stopped', 'statusCode': 0});

  @override
  Stream<Map<String, dynamic>> get onTrafficUpdate => Stream.value({
    'uplinkSpeed': 0,
    'downlinkSpeed': 0,
    'uplinkTotal': 0,
    'downlinkTotal': 0,
    'connectionsIn': 0,
    'connectionsOut': 0,
    'sessionUplink': 0,
    'sessionDownlink': 0,
    'sessionTotal': 0,
    'formattedUplinkSpeed': '0 B/s',
    'formattedDownlinkSpeed': '0 B/s',
    'formattedUplinkTotal': '0 B',
    'formattedDownlinkTotal': '0 B',
    'formattedSessionUplink': '0 B',
    'formattedSessionDownlink': '0 B',
    'formattedSessionTotal': '0 B',
  });

  // Per-app tunneling methods
  @override
  Future<bool> setPerAppProxyMode(String mode) => Future.value(true);

  @override
  Future<String> getPerAppProxyMode() => Future.value('off');

  @override
  Future<bool> setPerAppProxyList(List<String>? appList) => Future.value(true);

  @override
  Future<List<String>> getPerAppProxyList() =>
      Future.value(['com.example.app1', 'com.example.app2']);

  @override
  Future<List<Map<String, dynamic>>> getInstalledApps() => Future.value([
    {
      'packageName': 'com.example.app1',
      'appName': 'App 1',
      'isSystemApp': false,
    },
    {
      'packageName': 'com.example.app2',
      'appName': 'App 2',
      'isSystemApp': false,
    },
  ]);

  @override
  Future<bool> clearLogs() {
    // TODO: implement clearLogs
    throw UnimplementedError();
  }

  @override
  Future<List<String>> getLogs() {
    // TODO: implement getLogs
    throw UnimplementedError();
  }

  @override
  // TODO: implement onLogMessage
  Stream<Map<String, dynamic>> get onLogMessage => throw UnimplementedError();

  @override
  Future<String> getNotificationDescription() {
    // TODO: implement getNotificationDescription
    throw UnimplementedError();
  }

  @override
  Future<String> getNotificationTitle() {
    // TODO: implement getNotificationTitle
    throw UnimplementedError();
  }

  @override
  Future<bool> setNotificationDescription(String description) {
    // TODO: implement setNotificationDescription
    throw UnimplementedError();
  }

  @override
  Future<bool> setNotificationTitle(String title) {
    // TODO: implement setNotificationTitle
    throw UnimplementedError();
  }

  @override
  Future<bool> updateConnectionNotification(Map<String, Object?> state) =>
      Future.value(true);

  @override
  Future<bool> requestNotificationPermission() => Future.value(true);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final FlutterSingboxPlatform initialPlatform =
      FlutterSingboxPlatform.instance;

  test('$MethodChannelFlutterSingbox is the default instance', () {
    expect(initialPlatform, isInstanceOf<MethodChannelFlutterSingbox>());
  });

  test('getPlatformVersion', () async {
    FlutterSingbox flutterSingboxPlugin = FlutterSingbox();
    MockFlutterSingboxPlatform fakePlatform = MockFlutterSingboxPlatform();
    FlutterSingboxPlatform.instance = fakePlatform;

    expect(await flutterSingboxPlugin.getPlatformVersion(), '42');
  });

  test('saveConfig', () async {
    FlutterSingbox flutterSingboxPlugin = FlutterSingbox();
    MockFlutterSingboxPlatform fakePlatform = MockFlutterSingboxPlatform();
    FlutterSingboxPlatform.instance = fakePlatform;

    expect(await flutterSingboxPlugin.saveConfig('{"test": "config"}'), true);
  });

  test('getConfig', () async {
    FlutterSingbox flutterSingboxPlugin = FlutterSingbox();
    MockFlutterSingboxPlatform fakePlatform = MockFlutterSingboxPlatform();
    FlutterSingboxPlatform.instance = fakePlatform;

    expect(await flutterSingboxPlugin.getConfig(), '{"test": "config"}');
  });

  // Tests for per-app tunneling methods
  group('Per-app tunneling tests', () {
    late FlutterSingbox flutterSingboxPlugin;
    late MockFlutterSingboxPlatform fakePlatform;

    setUp(() {
      flutterSingboxPlugin = FlutterSingbox();
      fakePlatform = MockFlutterSingboxPlatform();
      FlutterSingboxPlatform.instance = fakePlatform;
    });

    test('setPerAppProxyMode', () async {
      expect(await flutterSingboxPlugin.setPerAppProxyMode('include'), true);
    });

    test('getPerAppProxyMode', () async {
      expect(await flutterSingboxPlugin.getPerAppProxyMode(), 'off');
    });

    test('setPerAppProxyList', () async {
      expect(
        await flutterSingboxPlugin.setPerAppProxyList(['com.example.app1']),
        true,
      );
    });

    test('getPerAppProxyList', () async {
      expect(await flutterSingboxPlugin.getPerAppProxyList(), [
        'com.example.app1',
        'com.example.app2',
      ]);
    });

    test('getInstalledApps', () async {
      final apps = await flutterSingboxPlugin.getInstalledApps();
      expect(apps.length, 2);
      expect(apps[0]['packageName'], 'com.example.app1');
      expect(apps[1]['appName'], 'App 2');
    });
  });
}
