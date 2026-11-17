import 'package:aurum_vpn/src/models/vpn_profile.dart';
import 'package:aurum_vpn/src/models/profile_network_stability.dart';
import 'package:aurum_vpn/src/models/profile_stability.dart';
import 'package:aurum_vpn/src/services/profile_auto_selector.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const selector = ProfileAutoSelector();

  test('Auto prefers a recently healthy server to old success counters', () {
    final now = DateTime.utc(2026, 6, 18, 8);
    final profiles = [
      _profile('old', VpnProfileKind.vlessReality, 'old.example'),
      _profile('recent', VpnProfileKind.hysteria2, 'recent.example'),
    ];
    final networkStats = {
      'old': ProfileNetworkStabilityStats(
        successfulStarts: 50,
        lastHealthyAt: now.subtract(const Duration(hours: 6)),
      ),
      'recent': ProfileNetworkStabilityStats(
        successfulStarts: 1,
        lastHealthyAt: now.subtract(const Duration(minutes: 3)),
      ),
    };
    final ranked = selector.rankForLatency(
      profiles,
      preferCurrentNetwork: true,
      networkStats: networkStats,
      now: now,
    );
    expect(ranked.first.id, 'recent');
    expect(
      selector
          .rankForLatency(
            profiles,
            preferCurrentNetwork: true,
            networkStats: networkStats,
            directLatencyMs: const {'old': 40, 'recent': 70},
            now: now,
          )
          .first
          .id,
      'old',
    );
  });

  test(
    'Auto keeps a recovered candidate but excludes an unresolved recent failure',
    () {
      final now = DateTime.utc(2026, 6, 18, 8);
      final lastFailure = now.subtract(const Duration(minutes: 2));
      final profiles = [
        _profile('failed', VpnProfileKind.naive, 'failed.example'),
        _profile('recovered', VpnProfileKind.vlessReality, 'recovered.example'),
        _profile('fallback', VpnProfileKind.hysteria2, 'fallback.example'),
      ];
      final ranked = selector.rankForLatency(
        profiles,
        directLatencyMs: const {'failed': 5, 'recovered': 35, 'fallback': 60},
        stabilityStats: {
          'recovered': ProfileStabilityStats(
            failedStarts: 1,
            lastFailureAt: lastFailure,
            lastHealthyAt: now.subtract(const Duration(minutes: 1)),
          ),
          'failed': ProfileStabilityStats(
            failedStarts: 1,
            lastFailureAt: lastFailure,
            lastStartedAt: now.subtract(const Duration(minutes: 3)),
          ),
        },
        now: now,
      );

      expect(ranked.map((profile) => profile.id), ['recovered', 'fallback']);
    },
  );

  test(
    'Auto prefers fresher health on the current network regardless of input order',
    () {
      final now = DateTime.utc(2026, 6, 18, 8);
      final profiles = [
        _profile('fresh', VpnProfileKind.hysteria2, 'fresh.example'),
        _profile('older', VpnProfileKind.naive, 'older.example'),
        _profile('stale', VpnProfileKind.vlessReality, 'stale.example'),
      ];
      final networkStats = {
        'fresh': ProfileNetworkStabilityStats(
          lastHealthyAt: now.subtract(const Duration(minutes: 2)),
        ),
        'older': ProfileNetworkStabilityStats(
          successfulStarts: 20,
          lastHealthyAt: now.subtract(const Duration(minutes: 15)),
        ),
        'stale': ProfileNetworkStabilityStats(
          successfulStarts: 50,
          lastHealthyAt: now.subtract(const Duration(minutes: 31)),
        ),
      };
      for (final input in [profiles, profiles.reversed.toList()]) {
        final ranked = selector.rankForLatency(
          input,
          lastProfileId: 'stale',
          now: now,
          preferCurrentNetwork: true,
          networkStats: networkStats,
        );
        expect(ranked.map((profile) => profile.id), [
          'fresh',
          'older',
          'stale',
        ]);
      }
    },
  );

  test('Auto ties use past reliability unless evaluating a new network', () {
    final now = DateTime.utc(2026, 6, 18, 8);
    final profiles = [
      _profile('preferred', VpnProfileKind.naive, 'preferred.example'),
      _profile('steady', VpnProfileKind.naive, 'steady.example'),
    ];
    List<String> rank({required bool preferCurrentNetwork}) => selector
        .rankForLatency(
          profiles,
          now: now,
          directLatencyMs: const {'preferred': 40, 'steady': 40},
          stabilityStats: {
            'preferred': ProfileStabilityStats(
              failedStarts: 1,
              lastFailureAt: now.subtract(const Duration(hours: 2)),
            ),
          },
          lastProfileId: 'preferred',
          preferCurrentNetwork: preferCurrentNetwork,
        )
        .map((profile) => profile.id)
        .toList();

    expect(rank(preferCurrentNetwork: false), ['steady', 'preferred']);
    expect(rank(preferCurrentNetwork: true), ['preferred', 'steady']);
  });

  test(
    'legacy Auto favors a longer subscription without excluding near expiry',
    () {
      final now = DateTime.utc(2026, 6, 18, 8);
      final soon = _profile(
        'soon',
        VpnProfileKind.vlessReality,
        'soon.example',
        expiresAt: now.add(const Duration(days: 5) - Duration(seconds: 1)),
      );
      final longer = _profile(
        'longer',
        VpnProfileKind.vlessReality,
        'longer.example',
        expiresAt: now.add(const Duration(days: 5)),
      );

      expect(
        selector.choose(
          [soon, longer],
          pingMs: const {'soon': 40, 'longer': 40},
          now: now,
        ),
        same(longer),
      );
      expect(selector.choose([soon], now: now), same(soon));
    },
  );

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

  test('does not auto-select unavailable profiles', () {
    final profiles = [
      _profile(
        'unavailable',
        VpnProfileKind.vlessMkcp,
        'tunnel.example',
        outbound: const {
          'type': 'vless',
          'transport': {'type': 'mkcp'},
        },
      ),
      _profile(
        'https',
        VpnProfileKind.naive,
        'https.example',
        outbound: {'type': 'naive'},
      ),
    ];

    final selected = selector.choose(
      profiles,
      pingMs: const {'unavailable': 1, 'https': 120},
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
  Map<String, dynamic>? outbound,
}) {
  return VpnProfile(
    id: id,
    name: id,
    kind: kind,
    originalInput: '$kind://$server',
    server: server,
    port: 443,
    subscriptionExpiresAt: expiresAt,
    outbound:
        outbound ?? {'type': kind == VpnProfileKind.naive ? 'naive' : 'vless'},
  );
}
