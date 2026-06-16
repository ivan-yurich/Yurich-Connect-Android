import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/vpn_profile.dart';

class ProfileStore {
  static const _profilesKey = 'profiles';
  static const _selectedProfileKey = 'selectedProfileId';
  static const _languageKey = 'languageCode';
  static const _autoConnectKey = 'autoConnect';
  static const _subscriptionReminderStampKey = 'subscriptionReminderStamp';
  static const _deletedProfileIdsBySubscriptionSourceKey =
      'deletedProfileIdsBySubscriptionSource';
  static const _splitTunnelExcludedProcessesKey =
      'splitTunnelExcludedProcesses';

  Future<List<VpnProfile>> loadProfiles() async {
    final prefs = await SharedPreferences.getInstance();
    final encoded = prefs.getString(_profilesKey);
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
    final prefs = await SharedPreferences.getInstance();
    final encoded = jsonEncode(
      profiles.map((profile) => profile.toJson()).toList(),
    );
    await prefs.setString(_profilesKey, encoded);
  }

  Future<Map<String, Set<String>>>
  loadDeletedProfileIdsBySubscriptionSource() async {
    final prefs = await SharedPreferences.getInstance();
    final encoded = prefs.getString(_deletedProfileIdsBySubscriptionSourceKey);
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
      await prefs.remove(_deletedProfileIdsBySubscriptionSourceKey);
      return;
    }

    await prefs.setString(
      _deletedProfileIdsBySubscriptionSourceKey,
      jsonEncode(normalized),
    );
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

  Future<String?> loadSubscriptionReminderStamp() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_subscriptionReminderStampKey);
  }

  Future<void> saveSubscriptionReminderStamp(String stamp) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_subscriptionReminderStampKey, stamp);
  }

  Future<List<String>> loadSplitTunnelExcludedProcesses() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(_splitTunnelExcludedProcessesKey) ?? const [];
  }

  Future<void> saveSplitTunnelExcludedProcesses(List<String> processes) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_splitTunnelExcludedProcessesKey, processes);
  }
}
