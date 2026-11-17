import 'dart:io';

import 'package:aurum_vpn/src/services/app_update_service.dart';
import 'package:aurum_vpn/src/services/kill_switch_http_policy.dart';
import 'package:aurum_vpn/src/services/sing_box_config_builder.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'update_http_fixture.dart';

const _updaterChannel = MethodChannel('online.dnsai.ivanvpn/updater');
const _vpnChannel = MethodChannel('com.tecclub.flutter_singbox/methods');

void registerAppUpdateAndroidCases(TestDefaultBinaryMessenger messenger) {
  final calls = <String>[];
  String? method;
  Object? reply;
  var requested = false;
  var protectionReads = 0;

  setUp(() {
    expect(Platform.isAndroid, isTrue, reason: 'Android runtime required');
    method = null;
    reply = null;
    requested = false;
    protectionReads = 0;
    calls.clear();
    messenger.setMockMethodCallHandler(_updaterChannel, (call) async {
      calls.add(call.method);
      expect(call.method, method);
      expect(call.arguments, isNull);
      return reply;
    });
    messenger.setMockMethodCallHandler(_vpnChannel, (call) async {
      protectionReads++;
      expect(call.method, 'getKillSwitchState');
      expect(call.arguments, isNull);
      return {'supported': true, 'known': true, 'requested': requested};
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(_updaterChannel, null);
    messenger.setMockMethodCallHandler(_vpnChannel, null);
  });

  AppUpdateService offlineService() => AppUpdateService(
    client: UpdateHttpClient((_) => fail('Unexpected updater HTTP request')),
  );

  testWidgets('Android ABI reply keeps only strings and accepts no reply', (
    tester,
  ) async {
    method = 'getSupportedAbis';
    final service = offlineService();
    reply = ['x86_64', null, 64, 'x86'];
    expect(await service.supportedAbis(), ['x86_64', 'x86']);
    reply = null;
    expect(await service.supportedAbis(), isEmpty);
    expect(calls, [method, method]);
    expect(protectionReads, 0);
  });

  testWidgets('only the confirmed GitHub channel allows external updates', (
    tester,
  ) async {
    method = 'getDistributionChannel';
    final service = offlineService();
    for (final (wire, channel, allowed) in [
      (' github ', AppDistributionChannel.github, true),
      ('tv', AppDistributionChannel.tv, false),
      ('play', AppDistributionChannel.play, false),
      ('soak', AppDistributionChannel.soak, false),
      ('unexpected', AppDistributionChannel.unknown, false),
      (null, AppDistributionChannel.unknown, false),
    ]) {
      reply = wire;
      expect(await service.distributionChannel(), channel);
      expect(await service.externalUpdatesEnabled(), allowed);
    }
    expect(calls, List.filled(12, method));
    expect(protectionReads, 0);
  });

  testWidgets('installer settings are requested once on the mock channel', (
    tester,
  ) async {
    method = 'openInstallSettings';
    await offlineService().openInstallSettings();
    expect(calls, [method]);
    expect(protectionReads, 0);
  });

  testWidgets('revoked updater client is replaced with a proxy-only client', (
    tester,
  ) async {
    const assetName = 'YurichConnect-android-x86_64-v1.0.2.apk';
    final feed = Uri.https('updates.example.invalid', '/release');
    final asset = Uri.https('updates.example.invalid', '/$assetName');
    const proxy = 'PROXY 127.0.0.1:${SingBoxConfigBuilder.localMixedProxyPort}';
    final old = UpdateHttpClient((_) => fail('Revoked client was reused'));
    late final UpdateHttpClient fresh;
    fresh = UpdateHttpClient(
      (request) {
        expect(request.method, 'GET');
        expect(request.uri, feed);
        return UpdateHttpResponse.json({
          'tag_name': 'v1.0.2',
          'assets': [
            {
              'name': assetName,
              'browser_download_url': asset.toString(),
              'size': 123,
            },
          ],
        });
      },
      beforeOpen: (request) {
        expect(fresh.findProxy?.call(request.uri), proxy);
      },
    );

    // Exercise the real Android routing facade; only platform IO is mocked.
    final service = AppUpdateService(
      client: old,
      releaseApiUris: [feed],
      githubReleasePageUri: Uri.https('fallback.example.invalid', '/latest'),
    );
    addTearDown(() {
      KillSwitchHttpPolicy.forget(old);
      KillSwitchHttpPolicy.forget(fresh);
    });
    await KillSwitchHttpPolicy.protect(old);
    expect(old.findProxy, isNull);
    expect(old.closeCalls, isEmpty);
    expect(KillSwitchHttpPolicy.isRevoked(old), isFalse);
    expect(protectionReads, 1);

    requested = true;
    KillSwitchHttpPolicy.cancelDirectRequests();
    expect(KillSwitchHttpPolicy.isRevoked(old), isTrue);
    expect(old.closeCalls, [true]);

    var creations = 0;
    final update = await HttpOverrides.runZoned(
      () => service.findLatest(
        currentVersion: '1.0.1',
        supportedAbis: ['x86_64'],
      ),
      createHttpClient: (_) {
        expect(++creations, 1);
        return fresh;
      },
    );
    expect(creations, 1);
    expect(update?.version, '1.0.2');
    expect(update?.assetName, assetName);
    expect(update?.downloadUrl, asset);
    expect(old.requests, isEmpty);
    expect(fresh.requests.map((request) => request.uri), [feed]);
    expect(fresh.connectionTimeout, old.connectionTimeout);
    expect(fresh.closeCalls, isEmpty);
    expect(protectionReads, 2);
    expect(calls, isEmpty);
  });
}
