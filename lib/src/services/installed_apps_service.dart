import 'package:flutter/services.dart';

class InstalledAppsService {
  static const _channel = MethodChannel('online.dnsai.ivanvpn/apps');

  Future<List<String>> installedPackageNames() async {
    try {
      final result = await _channel.invokeMethod<List<Object?>>(
        'getInstalledPackages',
      );
      if (result == null) {
        return const [];
      }
      return result.whereType<String>().toList(growable: false);
    } on PlatformException {
      return const [];
    } on MissingPluginException {
      return const [];
    }
  }
}
