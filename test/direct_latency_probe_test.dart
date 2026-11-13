import 'dart:async';
import 'dart:io';

import 'package:aurum_vpn/src/models/profile_network_stability.dart';
import 'package:aurum_vpn/src/models/profile_stability.dart';
import 'package:aurum_vpn/src/models/vpn_profile.dart';
import 'package:aurum_vpn/src/services/direct_latency_probe.dart';
import 'package:aurum_vpn/src/services/profile_auto_selector.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

VpnProfile profile(
  String id, {
  String? host,
  VpnProfileKind? kind,
  DateTime? expiry,
}) => VpnProfile(
  id: id,
  name: id,
  kind: kind ?? VpnProfileKind.vlessReality,
  originalInput: '',
  server: host ?? 'vpn.example.org',
  port: 443,
  subscriptionExpiresAt: expiry,
);

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.tecclub.flutter_singbox/methods');
  test('direct checks never dial local, special or untrusted host syntax', () {
    for (final ip in [
      '127.0.0.1',
      '0.0.0.0',
      '10.1.2.3',
      '192.168.0.1',
      '100.64.0.1',
      '169.254.169.254',
      '172.31.0.1',
      '192.0.2.1',
      '198.51.100.1',
      '203.0.113.1',
      '224.1.2.3',
      '::1',
      'fc00::1',
      'fe80::1',
      '::ffff:127.0.0.1',
      '2001:db8::1',
    ]) {
      expect(
        DirectLatencyProbe.isPublicAddress(InternetAddress(ip)),
        isFalse,
        reason: ip,
      );
      expect(DirectLatencyProbe.eligible(profile('local', host: ip)), isFalse);
    }
    for (final host in [
      'http://a.example.org',
      'a.local',
      'localhost',
      '-c',
      'a.example.org:443',
    ]) {
      expect(
        DirectLatencyProbe.eligible(profile('bad', host: host)),
        isFalse,
        reason: host,
      );
    }
    expect(
      DirectLatencyProbe.isPublicAddress(InternetAddress('1.1.1.1')),
      isTrue,
    );
    expect(
      DirectLatencyProbe.isPublicAddress(InternetAddress('2606:4700::1111')),
      isTrue,
    );
    expect(DirectLatencyProbe.eligible(profile('eligible')), isTrue);
  });

  test('absent or changed Android gate stops before DNS', () async {
    final calls = <String>[];
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      calls.add(call.method);
      return 'changed-network';
    });
    addTearDown(
      () => binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
    final probe = DirectLatencyProbe();
    addTearDown(probe.close);
    expect(
      await probe.check(
        profile('candidate'),
        networkKey: 'prior',
        stillAllowed: () => true,
      ),
      isNull,
    );
    expect(calls, ['getDirectProbeNetwork']);
    probe.close();
    expect(
      await probe.check(
        profile('candidate'),
        networkKey: 'changed-network',
        stillAllowed: () => true,
      ),
      isNull,
    );
    expect(calls, hasLength(1));
  });

  test(
    'closing the batch cancels Android DNS and ignores late answers',
    () async {
      final started = Completer<int>();
      final cancelled = Completer<int>();
      final answer = Completer<List<String>>();
      binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        switch (call.method) {
          case 'getDirectProbeNetwork':
            return 'physical';
          case 'resolveDirectProbeHost':
            started.complete(call.arguments['request'] as int);
            return answer.future;
          case 'cancelDirectProbeDns':
            cancelled.complete(call.arguments['request'] as int);
            return null;
          default:
            fail('Unexpected platform call: ${call.method}');
        }
      });
      addTearDown(
        () => binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      final probe = DirectLatencyProbe();
      final result = probe.check(
        profile('candidate'),
        networkKey: 'physical',
        stillAllowed: () => true,
      );
      final request = await started.future;
      probe.close();
      expect(await cancelled.future, request);
      answer.complete(['1.1.1.1']);
      expect(await result, isNull);
    },
  );

  test(
    'auto ranks actual measurements, includes Hysteria and excludes unsafe choices',
    () {
      final now = DateTime.utc(2026, 11, 12);
      final udp = profile('udp', kind: VpnProfileKind.hysteria2);
      final tcp = profile('tcp');
      final failed = profile('failed');
      final ranked = const ProfileAutoSelector().rankForLatency(
        [
          tcp,
          udp,
          failed,
          profile('offline'),
          profile('expired', expiry: now.subtract(const Duration(days: 1))),
        ],
        directLatencyMs: {
          'tcp': 80,
          'udp': 25,
          'offline': 1,
          'expired': 1,
          'failed': 2,
        },
        offlineProfileIds: {'offline'},
        stabilityStats: {
          'failed': ProfileStabilityStats(failedStarts: 1, lastFailureAt: now),
        },
        now: now,
      );
      expect(ranked.map((item) => item.id), ['udp', 'tcp']);
    },
  );

  test('auto falls back to actual success on the current network', () {
    final ranked = const ProfileAutoSelector().rankForLatency(
      [profile('old'), profile('wifi'), profile('unmeasured')],
      lastProfileId: 'old',
      stabilityStats: {'old': const ProfileStabilityStats(successfulStarts: 4)},
      networkStats: {
        'wifi': const ProfileNetworkStabilityStats(successfulStarts: 1),
      },
      directLatencyMs: {'unmeasured': 0},
    );
    expect(ranked.map((item) => item.id), ['wifi', 'old', 'unmeasured']);
  });
}
