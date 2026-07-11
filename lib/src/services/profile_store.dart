import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/dns_protection_mode.dart';
import '../models/profile_stability.dart';
import '../models/profile_network_stability.dart';
import '../models/vpn_profile.dart';
import 'secure_profile_storage.dart';

class ProfileStore {
  static const _profilesKey = 'profiles';
  static const _secureProfilesKey = 'profiles.v1';
  static const _selectedProfileKey = 'selectedProfileId';
  static const _languageKey = 'languageCode';
  static const _autoConnectKey = 'autoConnect';
  static const _manualDisconnectKey = 'manualDisconnectRequested';
  static const _smartRouteRuDirectKey = 'smartRouteRuDirect';
  static const _dnsProtectionModeKey = 'dnsProtectionMode';
  static const _subscriptionReminderStampKey = 'subscriptionReminderStamp';
  static const _vpnDisclosureVersionKey = 'vpnDisclosureVersion';
  static const _deletedProfileIdsBySubscriptionSourceKey =
      'deletedProfileIdsBySubscriptionSource';
  static const _secureDeletedProfilesKey =
      'deletedProfileIdsBySubscriptionSource.v1';
  static const _splitTunnelExcludedProcessesKey =
      'splitTunnelExcludedProcesses';
  static const _profileStabilityKey = 'profileStabilityStats';
  static const _profileNetworkStabilityKey = 'profileNetworkStabilityStats';

  ProfileStore({SecureProfileStorage? secureStorage})
    : _secureStorage = secureStorage ?? FlutterSecureProfileStorage();

  final SecureProfileStorage _secureStorage;

  Future<List<VpnProfile>> loadProfiles() async {
    final encoded = await _readSecureOrMigrate(
      secureKey: _secureProfilesKey,
      legacyKey: _profilesKey,
    );
    if (encoded == null || encoded.isEmpty) {
      return const [];
    }

    final decoded = jsonDecode(encoded) as List<dynamic>;
    return decoded
        .whereType<Map>()
        .map((json) => VpnProfile.fromJson(json.cast<String, dynamic>()))
        .toList();
  }

  Future<void> saveProfiles(List<VpnProfile> profiles) async {
    final encoded = jsonEncode(
      profiles.map((profile) => profile.toJson()).toList(),
    );
    await _secureStorage.write(_secureProfilesKey, encoded);
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_profilesKey);
  }

  Future<Map<String, Set<String>>>
  loadDeletedProfileIdsBySubscriptionSource() async {
    final encoded = await _readSecureOrMigrate(
      secureKey: _secureDeletedProfilesKey,
      legacyKey: _deletedProfileIdsBySubscriptionSourceKey,
    );
    if (encoded == null || encoded.isEmpty) {
      return const {};
    }

    final decoded = jsonDecode(encoded);
    if (decoded is! Map) {
      return const {};
    }

    return decoded.map((key, value) {
      final ids = value is List
          ? value.whereType<String>().where((id) => id.isNotEmpty).toSet()
          : <String>{};
      return MapEntry('$key', ids);
    })..removeWhere((key, value) => key.isEmpty || value.isEmpty);
  }

  Future<void> rememberDeletedSubscriptionProfile(VpnProfile profile) async {
    final source = subscriptionSourceKeyFor(profile);
    if (source == null || profile.id.isEmpty) {
      return;
    }

    final deletedBySource = Map<String, Set<String>>.from(
      await loadDeletedProfileIdsBySubscriptionSource(),
    );
    final deletedIds = deletedBySource.putIfAbsent(source, () => <String>{});
    deletedIds.add(profile.id);
    await _saveDeletedProfileIdsBySubscriptionSource(deletedBySource);
  }

  Future<void> clearDeletedProfilesForSubscriptionSource(String source) async {
    final sourceKey = subscriptionSourceKeyFromText(source);
    if (sourceKey == null) {
      return;
    }

    final deletedBySource = Map<String, Set<String>>.from(
      await loadDeletedProfileIdsBySubscriptionSource(),
    );
    if (deletedBySource.remove(sourceKey) == null) {
      return;
    }
    await _saveDeletedProfileIdsBySubscriptionSource(deletedBySource);
  }

  Future<void> _saveDeletedProfileIdsBySubscriptionSource(
    Map<String, Set<String>> deletedBySource,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final normalized = <String, List<String>>{};
    for (final entry in deletedBySource.entries) {
      final source = subscriptionSourceKeyFromText(entry.key);
      if (source == null) {
        continue;
      }
      final ids = entry.value.where((id) => id.isNotEmpty).toSet().toList()
        ..sort();
      if (ids.isNotEmpty) {
        normalized[source] = ids;
      }
    }

    if (normalized.isEmpty) {
      await _secureStorage.delete(_secureDeletedProfilesKey);
      await prefs.remove(_deletedProfileIdsBySubscriptionSourceKey);
      return;
    }

    await _secureStorage.write(
      _secureDeletedProfilesKey,
      jsonEncode(normalized),
    );
    await prefs.remove(_deletedProfileIdsBySubscriptionSourceKey);
  }

  Future<String?> _readSecureOrMigrate({
    required String secureKey,
    required String legacyKey,
  }) async {
    final secured = await _secureStorage.read(secureKey);
    if (secured != null && secured.isNotEmpty) {
      return secured;
    }

    final prefs = await SharedPreferences.getInstance();
    final legacy = prefs.getString(legacyKey);
    if (legacy == null || legacy.isEmpty) {
      return null;
    }
    await _secureStorage.write(secureKey, legacy);
    await prefs.remove(legacyKey);
    return legacy;
  }

  static String? subscriptionSourceKeyFor(VpnProfile profile) {
    return subscriptionSourceKeyFromText(
      profile.subscriptionSource ?? profile.originalInput,
    );
  }

  static String? subscriptionSourceKeyFromText(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      return null;
    }

    final uri = Uri.tryParse(trimmed);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      return null;
    }
    return trimmed;
  }

  Future<String?> loadSelectedProfileId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_selectedProfileKey);
  }

  Future<void> saveSelectedProfileId(String? id) async {
    final prefs = await SharedPreferences.getInstance();
    if (id == null) {
      await prefs.remove(_selectedProfileKey);
    } else {
      await prefs.setString(_selectedProfileKey, id);
    }
  }

  Future<String?> loadLanguageCode() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_languageKey);
  }

  Future<void> saveLanguageCode(String code) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_languageKey, code);
  }

  Future<bool> loadAutoConnect() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_autoConnectKey) ?? false;
  }

  Future<void> saveAutoConnect(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_autoConnectKey, enabled);
  }

  Future<bool> loadManualDisconnectRequested() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_manualDisconnectKey) ?? false;
  }

  Future<void> saveManualDisconnectRequested(bool requested) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_manualDisconnectKey, requested);
  }

  Future<bool> loadSmartRouteRuDirect() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_smartRouteRuDirectKey) ?? false;
  }

  Future<void> saveSmartRouteRuDirect(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_smartRouteRuDirectKey, enabled);
  }

  Future<DnsProtectionMode> loadDnsProtectionMode() async {
    final prefs = await SharedPreferences.getInstance();
    return DnsProtectionMode.fromStorageValue(
      prefs.getString(_dnsProtectionModeKey),
    );
  }

  Future<void> saveDnsProtectionMode(DnsProtectionMode mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_dnsProtectionModeKey, mode.storageValue);
  }

  Future<String?> loadSubscriptionReminderStamp() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_subscriptionReminderStampKey);
  }

  Future<void> saveSubscriptionReminderStamp(String stamp) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_subscriptionReminderStampKey, stamp);
  }

  Future<int> loadVpnDisclosureVersion() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_vpnDisclosureVersionKey) ?? 0;
  }

  Future<void> saveVpnDisclosureVersion(int version) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_vpnDisclosureVersionKey, version);
  }

  Future<List<String>> loadSplitTunnelExcludedProcesses() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(_splitTunnelExcludedProcessesKey) ?? const [];
  }

  Future<void> saveSplitTunnelExcludedProcesses(List<String> processes) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_splitTunnelExcludedProcessesKey, processes);
  }

  Future<Map<String, ProfileStabilityStats>> loadProfileStabilityStats() async {
    final prefs = await SharedPreferences.getInstance();
    final encoded = prefs.getString(_profileStabilityKey);
    if (encoded == null || encoded.isEmpty) {
      return const {};
    }

    final decoded = jsonDecode(encoded);
    if (decoded is! Map) {
      return const {};
    }

    final stats = <String, ProfileStabilityStats>{};
    for (final entry in decoded.entries) {
      final profileId = '${entry.key}'.trim();
      final value = entry.value;
      if (profileId.isEmpty || value is! Map) {
        continue;
      }
      stats[profileId] = ProfileStabilityStats.fromJson(
        value.cast<String, dynamic>(),
      );
    }
    return stats;
  }

  Future<void> saveProfileStabilityStats(
    Map<String, ProfileStabilityStats> stats,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final normalized = <String, Map<String, dynamic>>{};
    for (final entry in stats.entries) {
      final profileId = entry.key.trim();
      if (profileId.isEmpty) {
        continue;
      }
      normalized[profileId] = entry.value.toJson();
    }

    if (normalized.isEmpty) {
      await prefs.remove(_profileStabilityKey);
      return;
    }

    await prefs.setString(_profileStabilityKey, jsonEncode(normalized));
  }

  Future<Map<String, Map<String, ProfileNetworkStabilityStats>>>
  loadProfileNetworkStabilityStats() async {
    final prefs = await SharedPreferences.getInstance();
    final encoded = prefs.getString(_profileNetworkStabilityKey);
    if (encoded == null || encoded.isEmpty) {
      return const {};
    }

    final decoded = jsonDecode(encoded);
    if (decoded is! Map) {
      return const {};
    }

    final stats = <String, Map<String, ProfileNetworkStabilityStats>>{};
    for (final profileEntry in decoded.entries) {
      final profileId = '${profileEntry.key}'.trim();
      final networkMap = profileEntry.value;
      if (profileId.isEmpty || networkMap is! Map) {
        continue;
      }

      final profileStats = <String, ProfileNetworkStabilityStats>{};
      for (final networkEntry in networkMap.entries) {
        final networkType = '${networkEntry.key}'.trim();
        final value = networkEntry.value;
        if (networkType.isEmpty || value is! Map) {
          continue;
        }
        profileStats[networkType] = ProfileNetworkStabilityStats.fromJson(
          value.cast<String, dynamic>(),
        );
      }
      if (profileStats.isNotEmpty) {
        stats[profileId] = profileStats;
      }
    }
    return stats;
  }

  Future<void> saveProfileNetworkStabilityStats(
    Map<String, Map<String, ProfileNetworkStabilityStats>> stats,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final normalized = <String, Map<String, Map<String, dynamic>>>{};
    for (final profileEntry in stats.entries) {
      final profileId = profileEntry.key.trim();
      if (profileId.isEmpty || profileEntry.value.isEmpty) {
        continue;
      }

      final networkStats = <String, Map<String, dynamic>>{};
      for (final networkEntry in profileEntry.value.entries) {
        final networkType = networkEntry.key.trim();
        if (networkType.isEmpty) {
          continue;
        }
        networkStats[networkType] = networkEntry.value.toJson();
      }
      if (networkStats.isNotEmpty) {
        normalized[profileId] = networkStats;
      }
    }

    if (normalized.isEmpty) {
      await prefs.remove(_profileNetworkStabilityKey);
      return;
    }

    await prefs.setString(_profileNetworkStabilityKey, jsonEncode(normalized));
  }
}
