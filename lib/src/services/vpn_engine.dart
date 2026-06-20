import 'dart:async';

import 'android_vpn_engine.dart';
import 'sing_box_config_builder.dart';

class AurumVpnStatus {
  static const stopped = 'Stopped';
  static const starting = 'Starting';
  static const started = 'Started';
  static const stopping = 'Stopping';
}

abstract class VpnEngine {
  Stream<Map<String, dynamic>> get onStatusChanged;
  Stream<Map<String, dynamic>> get onTrafficUpdate;
  Stream<Map<String, dynamic>> get onLogMessage;

  SingBoxConfigTarget get configTarget;

  Future<bool> setNotificationTitle(String title);
  Future<String> getNotificationTitle();
  Future<bool> setNotificationDescription(String description);
  Future<String> getNotificationDescription();
  Future<bool> updateConnectionNotification(Map<String, Object?> state);
  Future<bool> requestNotificationPermission();
  Future<bool> showAppNotification({
    required String title,
    required String body,
    int id,
  });
  Future<String> getVPNStatus();
  Future<bool> saveConfig(String config);
  Future<String> getConfig();
  Future<bool> startVPN();
  Future<bool> stopVPN();
  Future<List<String>> getLogs();
  Future<bool> clearLogs();
  Future<void> dispose();
}

VpnEngine createVpnEngine() {
  return AndroidVpnEngine();
}
