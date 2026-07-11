import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_singbox_vpn/flutter_singbox_method_channel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  MethodChannelFlutterSingbox platform = MethodChannelFlutterSingbox();
  const MethodChannel channel = MethodChannel(
    'com.tecclub.flutter_singbox/methods',
  );

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
          switch (methodCall.method) {
            case 'getPlatformVersion':
              return '42';
            case 'saveConfig':
              return true;
            case 'getConfig':
              return '{"test": "config"}';
            case 'startVPN':
              return true;
            case 'stopVPN':
              return true;
            case 'getVPNStatus':
              return 'Stopped';
            case 'getManualDisconnectRequested':
              return true;
            default:
              return null;
          }
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('getPlatformVersion', () async {
    expect(await platform.getPlatformVersion(), '42');
  });

  test('saveConfig', () async {
    expect(await platform.saveConfig('{"test": "config"}'), true);
  });

  test('getConfig', () async {
    expect(await platform.getConfig(), '{"test": "config"}');
  });

  test('getVPNStatus', () async {
    expect(await platform.getVPNStatus(), 'Stopped');
  });

  test('getManualDisconnectRequested', () async {
    expect(await platform.getManualDisconnectRequested(), true);
  });
}
