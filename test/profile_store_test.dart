import 'dart:async';
import 'dart:convert';

import 'package:aurum_vpn/src/models/dns_protection_mode.dart';
import 'package:aurum_vpn/src/models/vpn_profile.dart';
import 'package:aurum_vpn/src/models/profile_network_stability.dart';
import 'package:aurum_vpn/src/models/profile_stability.dart';
import 'package:aurum_vpn/src/services/profile_store.dart';
import 'package:aurum_vpn/src/services/profile_auto_selector.dart';
import 'package:aurum_vpn/src/services/secure_profile_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
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

  group('Smart Route install default', () {
    const channel = MethodChannel('com.tecclub.flutter_singbox/methods');
    const preferenceKey = 'smartRouteRuDirect';
    final installTime = DateTime.utc(2026, 11, 12, 10);
    final later = installTime.add(const Duration(days: 1));
    final epoch = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
    final calls = <String>[];
    Object? nativeAnswer;
    PlatformException? nativeError;
    Completer<bool>? pendingSeed;

    setUp(() {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      calls.clear();
      nativeAnswer = true;
      nativeError = null;
      pendingSeed = null;
      binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        calls.add(call.method);
        if (nativeError case final error?) throw error;
        if (pendingSeed case final seed?) return seed.future;
        return nativeAnswer;
      });
    });

    tearDown(() {
      binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
      debugDefaultTargetPlatformOverride = null;
    });

    Future<bool> loadFresh() => store.loadSmartRouteRuDirect(
      installTime: installTime,
      updateTime: installTime,
    );

    Future<void> expectNoDefaultSaved() async {
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.containsKey(preferenceKey), isFalse);
    }

    for (final manualKeyPresent in [false, true]) {
      test(
        'enables and stores the clean Android default ($manualKeyPresent manual key)',
        () async {
          if (manualKeyPresent) {
            SharedPreferences.setMockInitialValues({
              'manualDisconnectRequested': false,
            });
          }
          expect(await loadFresh(), isTrue);
          final prefs = await SharedPreferences.getInstance();
          expect(prefs.getBool(preferenceKey), isTrue);
          expect(calls, ['initializeSmartRouteInstallDefault']);

          final afterUpdate = ProfileStore(secureStorage: secureStorage);
          expect(
            await afterUpdate.loadSmartRouteRuDirect(
              installTime: installTime,
              updateTime: later,
            ),
            isTrue,
          );
          expect(calls, hasLength(1));
        },
      );
    }

    test('keeps the implicit setting off on an Android update', () async {
      expect(
        await store.loadSmartRouteRuDirect(
          installTime: installTime,
          updateTime: later,
        ),
        isFalse,
      );
      await expectNoDefaultSaved();
      expect(calls, isEmpty);
    });

    test(
      'does not override an explicit off saved during native seeding',
      () async {
        pendingSeed = Completer<bool>();
        final load = loadFresh();
        await Future<void>.delayed(Duration.zero);
        expect(calls, ['initializeSmartRouteInstallDefault']);
        await store.saveSmartRouteRuDirect(false);
        pendingSeed!.complete(true);
        expect(await load, isFalse);
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getBool(preferenceKey), isFalse);
      },
    );

    for (final enabled in [false, true]) {
      test(
        'preserves an explicit $enabled choice on install and update',
        () async {
          SharedPreferences.setMockInitialValues({preferenceKey: enabled});
          expect(await loadFresh(), enabled);
          expect(
            await store.loadSmartRouteRuDirect(
              installTime: installTime,
              updateTime: later,
            ),
            enabled,
          );
          final prefs = await SharedPreferences.getInstance();
          expect(prefs.getBool(preferenceKey), enabled);
          expect(calls, isEmpty);
        },
      );
    }

    test('keeps the default off for missing or invalid timestamps', () async {
      for (final (installed, updated) in [
        (null, null),
        (installTime, null),
        (null, installTime),
        (epoch, epoch),
        (
          epoch.subtract(const Duration(seconds: 1)),
          epoch.subtract(const Duration(seconds: 1)),
        ),
        (later, installTime),
      ]) {
        expect(
          await store.loadSmartRouteRuDirect(
            installTime: installed,
            updateTime: updated,
          ),
          isFalse,
        );
      }
      await expectNoDefaultSaved();
      expect(calls, isEmpty);
    });

    for (final restoredKey in [
      'selectedProfileId',
      'profiles',
      'manualDisconnectRequested',
    ]) {
      test(
        'does not enable over restored preferences ($restoredKey)',
        () async {
          SharedPreferences.setMockInitialValues({
            restoredKey: switch (restoredKey) {
              'selectedProfileId' => 'restored-profile',
              'profiles' => '[]',
              _ => true,
            },
          });
          expect(await loadFresh(), isFalse);
          await expectNoDefaultSaved();
        },
      );
    }

    for (final (secureKey, value) in [
      ('profiles.v1', '[]'),
      ('deletedProfileIdsBySubscriptionSource.v1', '{}'),
    ]) {
      test('does not enable over restored secure state ($secureKey)', () async {
        await secureStorage.write(secureKey, value);
        expect(await loadFresh(), isFalse);
        await expectNoDefaultSaved();
      });
    }

    test('keeps the default off if secure state cannot be read', () async {
      secureStorage.failReads = true;
      expect(await loadFresh(), isFalse);
      await expectNoDefaultSaved();
    });

    test(
      'keeps the default off when native state is used or unknown',
      () async {
        for (final answer in [false, null, 'unknown']) {
          nativeAnswer = answer;
          expect(await loadFresh(), isFalse);
        }
        nativeError = PlatformException(code: 'NATIVE_STATE_UNAVAILABLE');
        expect(await loadFresh(), isFalse);
        await expectNoDefaultSaved();
        expect(calls, List.filled(4, 'initializeSmartRouteInstallDefault'));
      },
    );

    test('does not infer a clean install on other platforms', () async {
      for (final platform in TargetPlatform.values.where(
        (value) => value != TargetPlatform.android,
      )) {
        debugDefaultTargetPlatformOverride = platform;
        expect(await loadFresh(), isFalse);
      }
      await expectNoDefaultSaved();
      expect(calls, isEmpty);
    });
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

  for (final legacyStorage in [false, true]) {
    test('ignores retired profiles on load (legacy=$legacyStorage)', () async {
      const active = VpnProfile(
        id: 'active',
        name: 'HTTPS',
        kind: VpnProfileKind.naive,
        originalInput: 'naive+https://user:password@example.com:443',
        outbound: {'type': 'naive'},
      );
      final retired = {
        ...active.toJson(),
        'id': 'retired',
        'kind': 'pingTunnelExperimental',
        'outbound': {'type': 'pingtunnel'},
      };
      final encoded = jsonEncode([retired, active.toJson()]);
      if (legacyStorage) {
        SharedPreferences.setMockInitialValues({
          'profiles': encoded,
          'selectedProfileId': 'retired',
        });
      } else {
        await secureStorage.write('profiles.v1', encoded);
        await store.saveSelectedProfileId('retired');
      }

      final loaded = await store.loadProfiles();
      expect(loaded.map((profile) => profile.toJson()), [active.toJson()]);
      expect(
        const ProfileAutoSelector()
            .choose(
              loaded,
              selectedProfileId: await store.loadSelectedProfileId(),
            )
            ?.id,
        active.id,
      );
      // Loading must not rewrite the encrypted archive or lose other data.
      expect(await secureStorage.read('profiles.v1'), encoded);
      expect((await store.loadProfiles()).single.id, active.id);
      expect(() => VpnProfile.fromJson(retired), throwsFormatException);
    });
  }

  test('a store containing only retired profiles loads as empty', () async {
    await secureStorage.write(
      'profiles.v1',
      jsonEncode([
        {'id': 'old-kind', 'kind': 'pingTunnelExperimental'},
        {
          'id': 'old-outbound',
          'outbound': {'type': 'PingTunnel'},
        },
      ]),
    );
    expect(await store.loadProfiles(), isEmpty);
    expect(
      VpnProfileKind.values.map((kind) => kind.name),
      isNot(contains('pingTunnelExperimental')),
    );
    expect(
      () => VpnProfile.fromJson({
        'id': 'old-outbound',
        'outbound': {'type': 'pingtunnel'},
      }),
      throwsFormatException,
    );
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
  bool failReads = false;

  @override
  Future<void> delete(String key) async {
    _values.remove(key);
  }

  @override
  Future<String?> read(String key) async {
    if (failReads) throw StateError('Secure profile storage unavailable');
    return _values[key];
  }

  @override
  Future<void> write(String key, String value) async {
    _values[key] = value;
  }
}
