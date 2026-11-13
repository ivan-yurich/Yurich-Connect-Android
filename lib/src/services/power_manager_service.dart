import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class PowerManagerService {
  static const _channel = MethodChannel('online.dnsai.ivanvpn/power');

  bool get supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  Future<bool?> isIgnoringBatteryOptimizations() async {
    if (!supported) return null;
    try {
      return await _channel.invokeMethod<bool>(
        'isIgnoringBatteryOptimizations',
      );
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  Future<bool> openAppBatterySettings() async {
    if (!supported) return false;
    try {
      return await _channel.invokeMethod<bool>('openAppBatterySettings') ??
          false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }
}
