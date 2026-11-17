import 'package:aurum_vpn/src/services/tunnel_staleness_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final now = DateTime.utc(2026, 1, 1, 12);
  const grace = Duration(minutes: 5);
  final atLimit = now.subtract(grace);
  final overLimit = atLimit.subtract(const Duration(microseconds: 1));

  bool isStale({
    DateTime? lastHealthyAt,
    DateTime? lastTrafficAt,
    DateTime? connectedSince,
  }) => TunnelStalenessPolicy.isStale(
    now: now,
    grace: grace,
    lastHealthyAt: lastHealthyAt,
    lastTrafficAt: lastTrafficAt,
    connectedSince: connectedSince,
  );

  test('confirmed health takes precedence over traffic and start time', () {
    expect(
      isStale(
        lastHealthyAt: atLimit,
        lastTrafficAt: overLimit,
        connectedSince: now.subtract(const Duration(hours: 1)),
      ),
      isFalse,
    );
    expect(isStale(lastHealthyAt: overLimit, lastTrafficAt: now), isTrue);
  });

  test('traffic supplies freshness when confirmed health is absent', () {
    final connectedSince = now.subtract(const Duration(hours: 1));
    expect(
      isStale(lastTrafficAt: atLimit, connectedSince: connectedSince),
      isFalse,
    );
    expect(
      isStale(lastTrafficAt: overLimit, connectedSince: connectedSince),
      isTrue,
    );
  });

  test('session start is the last fallback and retains the grace period', () {
    expect(isStale(connectedSince: atLimit), isFalse);
    expect(isStale(connectedSince: overLimit), isTrue);
  });

  test('a tunnel with no timestamp evidence is stale', () {
    expect(isStale(), isTrue);
  });
}
