import 'package:aurum_vpn/src/models/vpn_profile.dart';
import 'package:aurum_vpn/src/models/profile_stability.dart';
import 'package:aurum_vpn/src/services/profile_auto_selector.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const selector = ProfileAutoSelector();

  test('keeps selected Reality profile for auto connect', () {
    final profiles = [
      _profile('turbo', VpnProfileKind.hysteria2, 'turbo.example'),
      _profile('reality', VpnProfileKind.vlessReality, 'reality.example'),
      _profile('https', VpnProfileKind.naive, 'https.example'),
    ];

    final selected = selector.choose(
      profiles,
      selectedProfileId: 'reality',
      pingMs: const {'reality': 180, 'https': 90},
    );

    expect(selected?.id, 'reality');
  });

  test('does not choose Hysteria automatically', () {
    final profiles = [
      _profile('turbo', VpnProfileKind.hysteria2, 'turbo.example'),
      _profile('https', VpnProfileKind.naive, 'https.example'),
    ];

    final selected = selector.choose(
      profiles,
      selectedProfileId: 'turbo',
      pingMs: const {'turbo': 2, 'https': 150},
    );

    expect(selected?.id, 'https');
  });

  test('prefers healthy Reality before HTTPS when both are usable', () {
    final profiles = [
      _profile('https', VpnProfileKind.naive, 'https.example'),
      _profile('reality', VpnProfileKind.vlessReality, 'reality.example'),
    ];

    final selected = selector.choose(
      profiles,
      pingMs: const {'https': 70, 'reality': 160},
    );

    expect(selected?.id, 'reality');
  });

  test('skips offline and expired profiles', () {
    final expired = DateTime.now().toUtc().subtract(const Duration(days: 1));
    final active = DateTime.now().toUtc().add(const Duration(days: 30));
    final profiles = [
      _profile(
        'expired',
        VpnProfileKind.vlessReality,
        'expired.example',
        expiresAt: expired,
      ),
      _profile('offline', VpnProfileKind.vlessReality, 'offline.example'),
      _profile(
        'https',
        VpnProfileKind.naive,
        'https.example',
        expiresAt: active,
      ),
    ];

    final selected = selector.choose(
      profiles,
      offlineProfileIds: const {'offline'},
    );

    expect(selected?.id, 'https');
  });

  test('penalizes recently unstable profiles', () {
    final now = DateTime.utc(2026, 6, 18, 8);
    final profiles = [
      _profile('reality-a', VpnProfileKind.vlessReality, 'a.example'),
      _profile('reality-b', VpnProfileKind.vlessReality, 'b.example'),
    ];

    final selected = selector.choose(
      profiles,
      pingMs: const {'reality-a': 80, 'reality-b': 140},
      stabilityStats: {
        'reality-a': ProfileStabilityStats(
          failedStarts: 2,
          recoveries: 1,
          healthFailures: 2,
          lastFailureAt: now.subtract(const Duration(minutes: 5)),
        ),
      },
      now: now,
    );

    expect(selected?.id, 'reality-b');
  });

  test('allows previously unstable profiles after cooldown', () {
    final now = DateTime.utc(2026, 6, 18, 8);
    final profiles = [
      _profile('reality-a', VpnProfileKind.vlessReality, 'a.example'),
      _profile('reality-b', VpnProfileKind.vlessReality, 'b.example'),
    ];

    final selected = selector.choose(
      profiles,
      pingMs: const {'reality-a': 60, 'reality-b': 250},
      stabilityStats: {
        'reality-a': ProfileStabilityStats(
          failedStarts: 2,
          recoveries: 1,
          healthFailures: 2,
          lastFailureAt: now.subtract(const Duration(hours: 2)),
          lastHealthyAt: now.subtract(const Duration(minutes: 10)),
        ),
      },
      now: now,
    );

    expect(selected?.id, 'reality-a');
  });
}

VpnProfile _profile(
  String id,
  VpnProfileKind kind,
  String server, {
  DateTime? expiresAt,
}) {
  return VpnProfile(
    id: id,
    name: id,
    kind: kind,
    originalInput: '$kind://$server',
    server: server,
    port: 443,
    subscriptionExpiresAt: expiresAt,
    outbound: {'type': kind == VpnProfileKind.naive ? 'naive' : 'vless'},
  );
}
