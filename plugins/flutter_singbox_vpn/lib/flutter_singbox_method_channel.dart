import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'flutter_singbox_platform_interface.dart';

/// An implementation of [FlutterSingboxPlatform] that uses method channels.
class MethodChannelFlutterSingbox extends FlutterSingboxPlatform {
  /// The method channel used to interact with the native platform.
  @visibleForTesting
  final methodChannel = const MethodChannel(
    'com.tecclub.flutter_singbox/methods',
  );

  /// Event channel for status updates
  final EventChannel _statusEventChannel = const EventChannel(
    'com.tecclub.flutter_singbox/status_events',
  );

  /// Event channel for traffic stats
  final EventChannel _trafficEventChannel = const EventChannel(
    'com.tecclub.flutter_singbox/traffic_events',
  );

  /// Event channel for log messages
  final EventChannel _logEventChannel = const EventChannel(
    'com.tecclub.flutter_singbox/log_events',
  );

  /// Stream controller for status events
  late final StreamController<Map<String, dynamic>> _statusStreamController;

  /// Stream controller for traffic stats
  late final StreamController<Map<String, dynamic>> _trafficStreamController;

  /// Stream controller for log messages
  late final StreamController<Map<String, dynamic>> _logStreamController;

  /// Constructor
  MethodChannelFlutterSingbox() {
    _statusStreamController =
        StreamController<Map<String, dynamic>>.broadcast();
    _trafficStreamController =
        StreamController<Map<String, dynamic>>.broadcast();
    _logStreamController = StreamController<Map<String, dynamic>>.broadcast();

    // Listen to status events
    _statusEventChannel.receiveBroadcastStream().listen((event) {
      if (event is Map) {
        _statusStreamController.add(Map<String, dynamic>.from(event));
      }
    });

    // Listen to traffic events
    _trafficEventChannel.receiveBroadcastStream().listen((event) {
      if (event is Map) {
        _trafficStreamController.add(Map<String, dynamic>.from(event));
      }
    });

    // Listen to log events
    _logEventChannel.receiveBroadcastStream().listen((event) {
      if (event is Map) {
        _logStreamController.add(Map<String, dynamic>.from(event));
      }
    });
  }

  @override
  Future<String?> getPlatformVersion() async {
    final version = await methodChannel.invokeMethod<String>(
      'getPlatformVersion',
    );
    return version;
  }

  @override
  Future<bool> saveConfig(String config) async {
    final result = await methodChannel.invokeMethod<bool>('saveConfig', {
      'config': config,
    });
    return result ?? false;
  }

  @override
  Future<String> getConfig() async {
    final config = await methodChannel.invokeMethod<String>('getConfig');
    return config ?? '{}';
  }

  @override
  Future<bool> startVPN() async {
    final result = await methodChannel.invokeMethod<bool>('startVPN');
    return result ?? false;
  }

  @override
  Future<bool> stopVPN() async {
    final result = await methodChannel.invokeMethod<bool>('stopVPN');
    return result ?? false;
  }

  @override
  Future<String> getVPNStatus() async {
    final status = await methodChannel.invokeMethod<String>('getVPNStatus');
    return status ?? 'Stopped';
  }

  @override
  Stream<Map<String, dynamic>> get onStatusChanged =>
      _statusStreamController.stream;

  @override
  Stream<Map<String, dynamic>> get onTrafficUpdate =>
      _trafficStreamController.stream;

  @override
  Future<bool> setPerAppProxyMode(String mode) async {
    final result = await methodChannel.invokeMethod<bool>(
      'setPerAppProxyMode',
      {'mode': mode},
    );
    return result ?? false;
  }

  @override
  Future<String> getPerAppProxyMode() async {
    final mode = await methodChannel.invokeMethod<String>('getPerAppProxyMode');
    return mode ?? 'off';
  }

  @override
  Future<bool> setPerAppProxyList(List<String>? appList) async {
    final result = await methodChannel.invokeMethod<bool>(
      'setPerAppProxyList',
      {'appList': appList ?? []},
    );
    return result ?? false;
  }

  @override
  Future<List<String>> getPerAppProxyList() async {
    final appList = await methodChannel.invokeMethod<List<dynamic>>(
      'getPerAppProxyList',
    );
    if (appList == null) return [];
    return appList.cast<String>();
  }

  @override
  Future<List<Map<String, dynamic>>> getInstalledApps() async {
    final apps = await methodChannel.invokeMethod<List<dynamic>>(
      'getInstalledApps',
    );
    if (apps == null) return [];
    return apps.map((app) => Map<String, dynamic>.from(app as Map)).toList();
  }

  @override
  Stream<Map<String, dynamic>> get onLogMessage => _logStreamController.stream;

  @override
  Future<List<String>> getLogs() async {
    final logs = await methodChannel.invokeMethod<List<dynamic>>('getLogs');
    if (logs == null) return [];
    return logs.cast<String>();
  }

  @override
  Future<bool> clearLogs() async {
    final result = await methodChannel.invokeMethod<bool>('clearLogs');
    return result ?? false;
  }

  @override
  Future<bool> setNotificationTitle(String title) async {
    final result = await methodChannel.invokeMethod<bool>(
      'setNotificationTitle',
      {'title': title},
    );
    return result ?? false;
  }

  @override
  Future<String> getNotificationTitle() async {
    final title = await methodChannel.invokeMethod<String>(
      'getNotificationTitle',
    );
    return title ?? 'VPN Service';
  }

  @override
  Future<bool> setNotificationDescription(String description) async {
    final result = await methodChannel.invokeMethod<bool>(
      'setNotificationDescription',
      {'description': description},
    );
    return result ?? false;
  }

  @override
  Future<String> getNotificationDescription() async {
    final description = await methodChannel.invokeMethod<String>(
      'getNotificationDescription',
    );
    return description ?? 'Connected';
  }

  @override
  Future<bool> updateConnectionNotification(Map<String, Object?> state) async {
    final result = await methodChannel.invokeMethod<bool>(
      'updateConnectionNotification',
      {'state': state},
    );
    return result ?? false;
  }

  @override
  Future<bool> requestNotificationPermission() async {
    final result = await methodChannel.invokeMethod<bool>(
      'requestNotificationPermission',
    );
    return result ?? false;
  }

  @override
  Future<bool> showAppNotification({
    required String title,
    required String body,
    int id = 7001,
  }) async {
    final result = await methodChannel.invokeMethod<bool>(
      'showAppNotification',
      {'title': title, 'body': body, 'id': id},
    );
    return result ?? false;
  }
}
