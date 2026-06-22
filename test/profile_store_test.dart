import 'package:aurum_vpn/src/models/vpn_profile.dart';
import 'package:aurum_vpn/src/models/profile_stability.dart';
import 'package:aurum_vpn/src/services/profile_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('remembers deleted subscription profile ids by source', () async {
    final store = ProfileStore();
    const profile = VpnProfile(
      id: 'profile-1',
      name: 'Finland',
      kind: VpnProfileKind.naive,
      originalInput: 'naive+https://user:pass@example.com:443',
      subscriptionSource: 'https://example.com/sub/links.txt',
      server: 'example.com',
      port: 443,
    );

    await store.rememberDeletedSubscriptionProfile(profile);

    final deleted = await store.loadDeletedProfileIdsBySubscriptionSource();
    expect(deleted, contains('https://example.com/sub/links.txt'));
    expect(deleted['https://example.com/sub/links.txt'], contains('profile-1'));
  });

  test(
    'clears deleted profile ids when subscription is imported again',
    () async {
      final store = ProfileStore();
      const source = 'https://example.com/sub/links.txt';
      const profile = VpnProfile(
        id: 'profile-1',
        name: 'Finland',
        kind: VpnProfileKind.naive,
        originalInput: 'naive+https://user:pass@example.com:443',
        subscriptionSource: source,
        server: 'example.com',
        port: 443,
      );

      await store.rememberDeletedSubscriptionProfile(profile);
      await store.clearDeletedProfilesForSubscriptionSource(source);

      final deleted = await store.loadDeletedProfileIdsBySubscriptionSource();
      expect(deleted, isEmpty);
    },
  );

  test(
    'ignores manually deleted profiles without subscription source',
    () async {
      final store = ProfileStore();
      const profile = VpnProfile(
        id: 'manual-profile',
        name: 'Manual',
        kind: VpnProfileKind.naive,
        originalInput: 'naive+https://user:pass@example.com:443',
        server: 'example.com',
        port: 443,
      );

      await store.rememberDeletedSubscriptionProfile(profile);

      final deleted = await store.loadDeletedProfileIdsBySubscriptionSource();
      expect(deleted, isEmpty);
    },
  );

  test('stores Smart Route preference', () async {
    final store = ProfileStore();

    expect(await store.loadSmartRouteRuDirect(), isFalse);

    await store.saveSmartRouteRuDirect(true);
    expect(await store.loadSmartRouteRuDirect(), isTrue);

    await store.saveSmartRouteRuDirect(false);
    expect(await store.loadSmartRouteRuDirect(), isFalse);
  });

  test('stores manual disconnect guard', () async {
    final store = ProfileStore();

    expect(await store.loadManualDisconnectRequested(), isFalse);

    await store.saveManualDisconnectRequested(true);
    expect(await store.loadManualDisconnectRequested(), isTrue);

    await store.saveManualDisconnectRequested(false);
    expect(await store.loadManualDisconnectRequested(), isFalse);
  });

  test('stores profile stability stats', () async {
    final store = ProfileStore();
    final lastFailureAt = DateTime.utc(2026, 6, 18, 8);

    await store.saveProfileStabilityStats({
      'profile-1': ProfileStabilityStats(
        successfulStarts: 3,
        failedStarts: 1,
        recoveries: 2,
        healthFailures: 4,
        lastFailureAt: lastFailureAt,
        lastFailureReason: 'health-probe',
      ),
    });

    final loaded = await store.loadProfileStabilityStats();
    expect(loaded['profile-1']?.successfulStarts, 3);
    expect(loaded['profile-1']?.failedStarts, 1);
    expect(loaded['profile-1']?.recoveries, 2);
    expect(loaded['profile-1']?.healthFailures, 4);
    expect(loaded['profile-1']?.lastFailureAt, lastFailureAt);
    expect(loaded['profile-1']?.lastFailureReason, 'health-probe');
  });
}
