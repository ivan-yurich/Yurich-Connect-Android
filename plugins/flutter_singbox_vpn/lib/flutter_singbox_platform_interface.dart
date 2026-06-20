import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'flutter_singbox_method_channel.dart';

abstract class FlutterSingboxPlatform extends PlatformInterface {
  /// Constructs a FlutterSingboxPlatform.
  FlutterSingboxPlatform() : super(token: _token);

  static final Object _token = Object();

  static FlutterSingboxPlatform _instance = MethodChannelFlutterSingbox();

  /// The default instance of [FlutterSingboxPlatform] to use.
  ///
  /// Defaults to [MethodChannelFlutterSingbox].
  static FlutterSingboxPlatform get instance => _instance;

  /// Platform-specific implementations should set this with their own
  /// platform-specific class that extends [FlutterSingboxPlatform] when
  /// they register themselves.
  static set instance(FlutterSingboxPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  Future<String?> getPlatformVersion() {
    throw UnimplementedError('platformVersion() has not been implemented.');
  }

  /// Save SingBox configuration
  Future<bool> saveConfig(String config) {
    throw UnimplementedError('saveConfig() has not been implemented.');
  }

  /// Get current SingBox configuration
  Future<String> getConfig() {
    throw UnimplementedError('getConfig() has not been implemented.');
  }

  /// Start VPN connection
  Future<bool> startVPN() {
    throw UnimplementedError('startVPN() has not been implemented.');
  }

  /// Stop VPN connection
  Future<bool> stopVPN() {
    throw UnimplementedError('stopVPN() has not been implemented.');
  }

  /// Get current VPN status
  Future<String> getVPNStatus() {
    throw UnimplementedError('getVPNStatus() has not been implemented.');
  }

  /// Stream of VPN status updates
  Stream<Map<String, dynamic>> get onStatusChanged {
    throw UnimplementedError('onStatusChanged has not been implemented.');
  }

  /// Stream of traffic statistics updates
  Stream<Map<String, dynamic>> get onTrafficUpdate {
    throw UnimplementedError('onTrafficUpdate has not been implemented.');
  }

  /// Set per-app proxy mode
  /// Valid values are: "off", "include", "exclude"
  Future<bool> setPerAppProxyMode(String mode) {
    throw UnimplementedError('setPerAppProxyMode() has not been implemented.');
  }

  /// Get current per-app proxy mode
  Future<String> getPerAppProxyMode() {
    throw UnimplementedError('getPerAppProxyMode() has not been implemented.');
  }

  /// Set list of apps for per-app proxy
  Future<bool> setPerAppProxyList(List<String>? appList) {
    throw UnimplementedError('setPerAppProxyList() has not been implemented.');
  }

  /// Get current list of apps for per-app proxy
  Future<List<String>> getPerAppProxyList() {
    throw UnimplementedError('getPerAppProxyList() has not been implemented.');
  }

  /// Get list of installed apps
  /// Returns a list of maps with keys: "packageName", "appName", "isSystemApp"
  Future<List<Map<String, dynamic>>> getInstalledApps() {
    throw UnimplementedError('getInstalledApps() has not been implemented.');
  }

  /// Stream of log messages from the VPN service
  Stream<Map<String, dynamic>> get onLogMessage {
    throw UnimplementedError('onLogMessage has not been implemented.');
  }

  /// Get buffered log messages
  Future<List<String>> getLogs() {
    throw UnimplementedError('getLogs() has not been implemented.');
  }

  /// Clear the log buffer
  Future<bool> clearLogs() {
    throw UnimplementedError('clearLogs() has not been implemented.');
  }

  /// Set notification title
  Future<bool> setNotificationTitle(String title) {
    throw UnimplementedError(
      'setNotificationTitle() has not been implemented.',
    );
  }

  /// Get notification title
  Future<String> getNotificationTitle() {
    throw UnimplementedError(
      'getNotificationTitle() has not been implemented.',
    );
  }

  /// Set notification description
  Future<bool> setNotificationDescription(String description) {
    throw UnimplementedError(
      'setNotificationDescription() has not been implemented.',
    );
  }

  /// Get notification description
  Future<String> getNotificationDescription() {
    throw UnimplementedError(
      'getNotificationDescription() has not been implemented.',
    );
  }

  /// Update the persistent VPN foreground notification with the current
  /// connection snapshot.
  Future<bool> updateConnectionNotification(Map<String, Object?> state) {
    throw UnimplementedError(
      'updateConnectionNotification() has not been implemented.',
    );
  }

  /// Ask Android 13+ for notification permission so the VPN foreground
  /// notification is visible in the notification shade.
  Future<bool> requestNotificationPermission() {
    throw UnimplementedError(
      'requestNotificationPermission() has not been implemented.',
    );
  }

  /// Show a one-shot app notification.
  Future<bool> showAppNotification({
    required String title,
    required String body,
    int id = 7001,
  }) {
    throw UnimplementedError('showAppNotification() has not been implemented.');
  }
}
