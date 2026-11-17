import 'package:aurum_vpn/src/models/profile_network_stability.dart';
import 'package:aurum_vpn/src/models/profile_stability.dart';
import 'package:aurum_vpn/src/models/vpn_profile.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final now = DateTime.utc(2026, 11, 16, 10);

  test('health penalties decay at the documented time boundaries', () {
    for (final (age, penalty) in [
      (const Duration(minutes: 14, seconds: 59), 320),
      (const Duration(minutes: 15), 180),
      (const Duration(hours: 1), 80),
      (const Duration(hours: 6), 0),
    ]) {
      expect(
        ProfileStabilityStats(
          lastFailureAt: now.subtract(age),
        ).autoSelectPenalty(now: now),
        penalty,
        reason: 'failure age: $age',
      );
    }
    final stats = const ProfileStabilityStats()
        .recordStartFailure('start', at: now)
        .recordHealthFailure('health', at: now)
        .recordRecovery(at: now);
    expect(stats.isTemporarilyUnstable(now: now), isTrue);
    expect(
      stats.isTemporarilyUnstable(now: now.add(const Duration(minutes: 30))),
      isFalse,
    );
    final healthy = stats.recordHealthy(at: now);
    expect(
      healthy.autoSelectPenalty(now: now),
      (stats.autoSelectPenalty(now: now) * .45).round(),
    );
    expect(healthy.lastFailureReason, 'health');
    expect(stats.lastHealthyAt, isNull);
  });

  test('network health separates traffic, recovery and successful starts', () {
    final initial = const ProfileNetworkStabilityStats().recordHealthFailure(
      'timeout',
      at: now,
    );
    expect(initial.recordTraffic(0), same(initial));
    expect(initial.recordTraffic(-1), same(initial));
    final later = now.add(const Duration(seconds: 2));
    final recovered = initial
        .recordRecovery(at: later)
        .recordTraffic(2048, at: later);
    expect(recovered.lastHealthyAt, later);
    expect(recovered.recoveries, 1);
    expect(recovered.successfulStarts, 0);
    expect(recovered.trafficBytes, 2048);
    expect(recovered.lastFailureAt, now);
    final healthy = recovered
        .recordHealthy(at: now)
        .recordStartSuccess(at: later);
    expect(healthy.healthFailures, 0);
    expect(healthy.lastHealthyAt, later);
    expect(healthy.lastFailureReason, 'timeout');
    expect(healthy.successfulStarts, 1);
    expect(
      ProfileNetworkStabilityStats.fromJson(healthy.toJson()).toJson(),
      healthy.toJson(),
    );
  });

  test('legacy numeric and date formats migrate without invalid counters', () {
    final stability = ProfileStabilityStats.fromJson({
      'successfulStarts': 2.8,
      'failedStarts': '3',
      'healthFailures': 'bad',
      'lastStartedAt': now,
      'lastFailureAt': now.millisecondsSinceEpoch,
      'lastHealthyAt': 'not a date',
    });
    expect(
      (
        stability.successfulStarts,
        stability.failedStarts,
        stability.healthFailures,
      ),
      (2, 3, 0),
    );
    expect(stability.lastStartedAt, now);
    expect(stability.lastFailureAt, now);
    expect(stability.lastHealthyAt, isNull);
    expect(
      ProfileStabilityStats.fromJson(stability.toJson()).toJson(),
      stability.toJson(),
    );

    final network = ProfileNetworkStabilityStats.fromJson({
      'trafficBytes': '1234',
      'recoveries': 1.2,
      'lastHealthyAt': now,
      'lastFailureAt': now.millisecondsSinceEpoch,
    });
    expect((network.trafficBytes, network.recoveries), (1234, 1));
    expect(network.lastHealthyAt, now);
    expect(network.lastFailureAt, now);
  });

  test(
    'stored profiles retain metadata and legacy profiles remain readable',
    () {
      final legacy = VpnProfile.fromJson({
        'id': 'fixture-profile',
        'name': 'Legacy',
        'kind': 'unknownHistoricalKind',
      });
      expect(legacy.kind, VpnProfileKind.vlessReality);
      expect(legacy.originalInput, isEmpty);
      expect(legacy.endpoint, 'VLESS Reality');
      final saved = legacy.copyWith(
        server: 'node.example.invalid',
        port: 8443,
        countryCode: 'NL',
        subscriptionExpiresAt: now,
      );
      expect(
        legacy.copyWith(server: 'node.example.invalid').endpoint,
        'node.example.invalid',
      );
      expect(saved.endpoint, 'node.example.invalid:8443');
      expect(VpnProfile.fromJson(saved.toJson()).toJson(), saved.toJson());
      expect(
        () => VpnProfile.fromJson({
          ...saved.toJson(),
          'outbound': {'type': ' PINGTUNNEL '},
        }),
        throwsFormatException,
      );
    },
  );
}
