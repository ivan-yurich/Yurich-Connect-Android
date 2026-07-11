import 'dart:convert';

import 'package:aurum_vpn/src/models/dns_protection_mode.dart';
import 'package:aurum_vpn/src/models/vpn_profile.dart';
import 'package:aurum_vpn/src/models/profile_network_stability.dart';
import 'package:aurum_vpn/src/models/profile_stability.dart';
import 'package:aurum_vpn/src/services/profile_store.dart';
import 'package:aurum_vpn/src/services/secure_profile_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late _MemorySecureProfileStorage secureStorage;
  late ProfileStore store;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    secureStorage = _MemorySecureProfileStorage();
    store = ProfileStore(secureStorage: secureStorage);
  });

  test('remembers deleted subscription profile ids by source', () async {
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
    expect(await store.loadSmartRouteRuDirect(), isFalse);

    await store.saveSmartRouteRuDirect(true);
    expect(await store.loadSmartRouteRuDirect(), isTrue);

    await store.saveSmartRouteRuDirect(false);
    expect(await store.loadSmartRouteRuDirect(), isFalse);
  });

  test('stores DNS protection mode', () async {
    expect(await store.loadDnsProtectionMode(), DnsProtectionMode.stable);

    await store.saveDnsProtectionMode(DnsProtectionMode.leakGuard);
    expect(await store.loadDnsProtectionMode(), DnsProtectionMode.leakGuard);
  });

  test('stores manual disconnect guard', () async {
    expect(await store.loadManualDisconnectRequested(), isFalse);

    await store.saveManualDisconnectRequested(true);
    expect(await store.loadManualDisconnectRequested(), isTrue);

    await store.saveManualDisconnectRequested(false);
    expect(await store.loadManualDisconnectRequested(), isFalse);
  });

  test('stores profile stability stats', () async {
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

  test('stores profile network stability stats by network type', () async {
    final lastHealthyAt = DateTime.utc(2026, 6, 30, 9);

    await store.saveProfileNetworkStabilityStats({
      'profile-1': {
        'wifi': ProfileNetworkStabilityStats(
          successfulStarts: 2,
          recoveries: 1,
          healthFailures: 0,
          trafficBytes: 1024,
          lastHealthyAt: lastHealthyAt,
        ),
        'cellular': const ProfileNetworkStabilityStats(
          healthFailures: 3,
          lastFailureReason: 'health-probe:watchdog',
        ),
      },
    });

    final loaded = await store.loadProfileNetworkStabilityStats();
    expect(loaded['profile-1']?['wifi']?.successfulStarts, 2);
    expect(loaded['profile-1']?['wifi']?.recoveries, 1);
    expect(loaded['profile-1']?['wifi']?.trafficBytes, 1024);
    expect(loaded['profile-1']?['wifi']?.lastHealthyAt, lastHealthyAt);
    expect(loaded['profile-1']?['cellular']?.healthFailures, 3);
    expect(
      loaded['profile-1']?['cellular']?.lastFailureReason,
      'health-probe:watchdog',
    );
  });

  test('migrates plaintext profiles to secure storage once', () async {
    const profile = VpnProfile(
      id: 'secure-profile',
      name: 'Secure',
      kind: VpnProfileKind.vlessReality,
      originalInput: 'vless://secret@example.com:443',
      server: 'example.com',
      port: 443,
      outbound: {'type': 'vless', 'uuid': 'secret'},
    );
    SharedPreferences.setMockInitialValues({
      'profiles': jsonEncode([profile.toJson()]),
    });

    final loaded = await store.loadProfiles();

    expect(loaded.single.id, profile.id);
    expect(await secureStorage.read('profiles.v1'), isNotEmpty);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.containsKey('profiles'), isFalse);
  });

  test('saves profile secrets only in secure storage', () async {
    const profile = VpnProfile(
      id: 'secure-profile',
      name: 'Secure',
      kind: VpnProfileKind.hysteria2,
      originalInput: 'hy2://password@example.com:443',
      server: 'example.com',
      port: 443,
      outbound: {'type': 'hysteria2', 'password': 'password'},
    );

    await store.saveProfiles([profile]);

    final secured = await secureStorage.read('profiles.v1');
    expect(secured, contains('password'));
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.containsKey('profiles'), isFalse);
  });
}

final class _MemorySecureProfileStorage implements SecureProfileStorage {
  final _values = <String, String>{};

  @override
  Future<void> delete(String key) async {
    _values.remove(key);
  }

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> write(String key, String value) async {
    _values[key] = value;
  }
}
