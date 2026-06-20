import 'dart:async';

import 'package:flutter_singbox_vpn/flutter_singbox.dart';

import 'sing_box_config_builder.dart';
import 'vpn_engine.dart';

class AndroidVpnEngine implements VpnEngine {
  AndroidVpnEngine() : _singBox = FlutterSingbox();

  final FlutterSingbox _singBox;

  @override
  SingBoxConfigTarget get configTarget => SingBoxConfigTarget.android;

  @override
  Stream<Map<String, dynamic>> get onStatusChanged => _singBox.onStatusChanged;

  @override
  Stream<Map<String, dynamic>> get onTrafficUpdate => _singBox.onTrafficUpdate;

  @override
  Stream<Map<String, dynamic>> get onLogMessage => _singBox.onLogMessage;

  @override
  Future<bool> setNotificationTitle(String title) {
    return _singBox.setNotificationTitle(title);
  }

  @override
  Future<String> getNotificationTitle() => _singBox.getNotificationTitle();

  @override
  Future<bool> setNotificationDescription(String description) {
    return _singBox.setNotificationDescription(description);
  }

  @override
  Future<String> getNotificationDescription() {
    return _singBox.getNotificationDescription();
  }

  @override
  Future<bool> updateConnectionNotification(Map<String, Object?> state) {
    return _singBox.updateConnectionNotification(state);
  }

  @override
  Future<bool> requestNotificationPermission() {
    return _singBox.requestNotificationPermission();
  }

  @override
  Future<bool> showAppNotification({
    required String title,
    required String body,
    int id = 7001,
  }) {
    return _singBox.showAppNotification(title: title, body: body, id: id);
  }

  @override
  Future<String> getVPNStatus() => _singBox.getVPNStatus();

  @override
  Future<bool> saveConfig(String config) => _singBox.saveConfig(config);

  @override
  Future<String> getConfig() => _singBox.getConfig();

  @override
  Future<bool> startVPN() => _singBox.startVPN();

  @override
  Future<bool> stopVPN() => _singBox.stopVPN();

  @override
  Future<List<String>> getLogs() => _singBox.getLogs();

  @override
  Future<bool> clearLogs() => _singBox.clearLogs();

  @override
  Future<void> dispose() async {}
}
