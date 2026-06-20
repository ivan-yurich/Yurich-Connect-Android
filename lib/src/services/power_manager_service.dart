import 'dart:io';

import 'package:flutter/services.dart';

class PowerManagerService {
  static const _channel = MethodChannel('online.dnsai.ivanvpn/power');

  Future<bool> isIgnoringBatteryOptimizations() async {
    if (!Platform.isAndroid) {
      return true;
    }
    try {
      return await _channel.invokeMethod<bool>(
            'isIgnoringBatteryOptimizations',
          ) ??
          true;
    } on MissingPluginException {
      return true;
    }
  }

  Future<void> requestIgnoreBatteryOptimizations() async {
    if (!Platform.isAndroid) {
      return;
    }
    try {
      await _channel.invokeMethod<void>('requestIgnoreBatteryOptimizations');
    } on MissingPluginException {
      return;
    }
  }

  Future<void> openBatteryOptimizationSettings() async {
    if (!Platform.isAndroid) {
      return;
    }
    try {
      await _channel.invokeMethod<void>('openBatteryOptimizationSettings');
    } on MissingPluginException {
      return;
    }
  }
}
