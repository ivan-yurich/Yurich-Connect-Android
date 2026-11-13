import 'package:aurum_vpn/src/models/profile_network_stability.dart';
import 'package:aurum_vpn/src/models/profile_stability.dart';
import 'package:aurum_vpn/src/models/vpn_profile.dart';
import 'package:aurum_vpn/src/services/auto_failover_order.dart';
import 'package:aurum_vpn/src/services/profile_auto_selector.dart';
import 'package:flutter_test/flutter_test.dart';

VpnProfile _profile(
  String id, {
  String? country,
  String? raw,
  DateTime? expiry,
}) {
  return VpnProfile(
    id: id,
    name: id,
    kind: VpnProfileKind.vlessReality,
    originalInput: '',
    countryCode: country,
    rawConfig: raw,
    subscriptionExpiresAt: expiry,
  );
}

void main() {
  final now = DateTime.utc(2026, 11, 12);
  final recent = now.subtract(const Duration(seconds: 20));

  test('keeps the first rank, then diversifies and never repeats an ID', () {
    final first = _profile('first', country: 'DE');
    final ranked = [
      first,
      _profile('first', country: 'FR'),
      _profile('near', country: ' de '),
      _profile('unknown'),
      _profile('different', country: 'FR'),
      _profile('second-fr', country: 'FR'),
      _profile('third-country', country: 'PL'),
    ];
    final order = orderAutoFailoverCandidates(
      ranked,
      locationOf: (profile) => profile.countryCode,
    );
    expect(order.first, same(first));
    expect(order.map((profile) => profile.id), [
      'first',
      'different',
      'third-country',
      'near',
      'unknown',
      'second-fr',
    ]);
  });

  test('preserves an unknown first choice but not later unknown locations', () {
    final order = orderAutoFailoverCandidates([
      _profile('first'),
      _profile('blank', country: ' '),
      _profile('known', country: 'NL'),
    ], locationOf: (profile) => profile.countryCode);
    expect(order.map((profile) => profile.id), ['first', 'known', 'blank']);
  });

  test('demotes a recent local failure instead of dropping it', () {
    final order = const ProfileAutoSelector().rankForLatency(
      [
        _profile('remote-failure'),
        _profile('local-failure'),
        _profile('untested'),
        _profile('offline'),
        _profile('raw', raw: '{}'),
        _profile('expired', expiry: now.subtract(const Duration(days: 1))),
      ],
      offlineProfileIds: {'offline'},
      directLatencyMs: {'remote-failure': 20, 'local-failure': 1},
      stabilityStats: {
        'remote-failure': ProfileStabilityStats(
          failedStarts: 5,
          lastFailureAt: recent,
        ),
      },
      networkStats: {
        'local-failure': ProfileNetworkStabilityStats(lastFailureAt: recent),
      },
      preferCurrentNetwork: true,
      now: now,
    );
    expect(order.map((profile) => profile.id), [
      'remote-failure',
      'untested',
      'local-failure',
    ]);
  });

  test(
    'keeps profiles recovered since the last failure and expired cooldown',
    () {
      final order = const ProfileAutoSelector().rankForLatency(
        [_profile('recovering'), _profile('recovered'), _profile('old')],
        directLatencyMs: {'recovering': 1, 'recovered': 2, 'old': 3},
        networkStats: {
          'recovering': ProfileNetworkStabilityStats(lastFailureAt: recent),
          'recovered': ProfileNetworkStabilityStats(
            lastFailureAt: recent,
            lastHealthyAt: now,
          ),
          'old': ProfileNetworkStabilityStats(
            lastFailureAt: now.subtract(const Duration(minutes: 3)),
          ),
        },
        preferCurrentNetwork: true,
        now: now,
      );
      expect(order.map((profile) => profile.id), [
        'recovered',
        'old',
        'recovering',
      ]);
    },
  );
}
