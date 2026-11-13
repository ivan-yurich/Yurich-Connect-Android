import 'package:flutter/services.dart';

import '../models/vpn_profile.dart';

enum SmartRouteAppAvailability {
  installed,
  missing,
  sharedUid,
  disabled,
  unknown,
}

enum SmartRouteAppRoute {
  applied,
  protected,
  missing,
  unavailable,
  unselected,
  smartRouteOff,
  rawProfile,
  otherAppMode,
  nextConnection,
  unconfirmed,
  notApplied,
}

final class SmartRouteAppCandidate {
  const SmartRouteAppCandidate(this.packageId, this.name, this.availability);

  final String packageId;
  final String name;
  final SmartRouteAppAvailability availability;
}

final class SmartRouteAppsSnapshot {
  const SmartRouteAppsSnapshot({
    this.candidates = const [],
    this.selected = const {},
    this.applied,
    this.protected = false,
    this.protectionKnown = false,
    this.supported = false,
    this.legacyAppMode = false,
  });

  static const maxCandidates = 128;
  static const _maxReportedExclusions = 192;
  static final _packagePattern = RegExp(
    r'^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$',
  );

  static bool _validPackage(String id) =>
      id.length <= 255 && _packagePattern.hasMatch(id);

  factory SmartRouteAppsSnapshot.fromMap(Map<Object?, Object?> data) {
    final candidates = <String, SmartRouteAppCandidate>{};
    final rows = data['candidates'];
    if (rows is List && rows.length <= maxCandidates) {
      for (final row in rows.whereType<Map>()) {
        final id = row['packageId'];
        final name = row['name'];
        if (id is! String ||
            name is! String ||
            name.isEmpty ||
            name.length > 120 ||
            !_validPackage(id)) {
          continue;
        }
        candidates[id] = SmartRouteAppCandidate(
          id,
          name,
          switch (row['availability']) {
            'installed' => SmartRouteAppAvailability.installed,
            'missing' => SmartRouteAppAvailability.missing,
            'shared_uid' => SmartRouteAppAvailability.sharedUid,
            'disabled' => SmartRouteAppAvailability.disabled,
            _ => SmartRouteAppAvailability.unknown,
          },
        );
      }
    }
    final selected = data['selected'];
    final applied = data['applied'];
    return SmartRouteAppsSnapshot(
      candidates: List.unmodifiable(candidates.values),
      selected: selected is List && selected.length <= maxCandidates
          ? Set.unmodifiable(
              selected.whereType<String>().where(candidates.containsKey),
            )
          : const {},
      applied:
          applied is List &&
              applied.length <= _maxReportedExclusions &&
              applied.every((id) => id is String && _validPackage(id))
          ? Set.unmodifiable(applied.cast<String>())
          : null,
      protected: data['protected'] == true,
      protectionKnown: data['protectionKnown'] == true,
      supported: data['supported'] == true,
      legacyAppMode: data['legacyAppMode'] == true,
    );
  }

  final List<SmartRouteAppCandidate> candidates;
  final Set<String> selected;
  final Set<String>? applied;
  final bool protected;
  final bool protectionKnown;
  final bool supported;
  final bool legacyAppMode;

  SmartRouteAppRoute routeFor(
    String packageId, {
    required bool builtIn,
    required bool smartRouteEnabled,
    required bool managedProfile,
    required bool vpnActive,
    SmartRouteAppAvailability? availability,
  }) {
    if (protected) return SmartRouteAppRoute.protected;
    if (availability == SmartRouteAppAvailability.missing) {
      return SmartRouteAppRoute.missing;
    }
    if (vpnActive && protectionKnown && applied?.contains(packageId) == true) {
      return SmartRouteAppRoute.applied;
    }
    if (!builtIn && !selected.contains(packageId)) {
      return SmartRouteAppRoute.unselected;
    }
    if (!smartRouteEnabled) return SmartRouteAppRoute.smartRouteOff;
    if (!managedProfile) return SmartRouteAppRoute.rawProfile;
    if (!builtIn &&
        (!supported ||
            availability == SmartRouteAppAvailability.disabled ||
            availability == SmartRouteAppAvailability.sharedUid ||
            availability == SmartRouteAppAvailability.unknown)) {
      return SmartRouteAppRoute.unavailable;
    }
    if (!builtIn && legacyAppMode) return SmartRouteAppRoute.otherAppMode;
    if (!vpnActive) return SmartRouteAppRoute.nextConnection;
    if (!protectionKnown || applied == null) {
      return SmartRouteAppRoute.unconfirmed;
    }
    return SmartRouteAppRoute.notApplied;
  }
}

/// Private, local Android channel. Neither package state nor selections use HTTP.
final class SmartRouteAppsService {
  const SmartRouteAppsService();

  static const _channel = MethodChannel('com.tecclub.flutter_singbox/methods');
  static const _timeout = Duration(seconds: 5);

  static bool managedProfile(VpnProfile profile) =>
      profile.kind.isClientSupported && profile.rawConfig == null;

  Future<bool> initializeInstallDefault() async {
    try {
      return await _channel
              .invokeMethod<bool>('initializeSmartRouteInstallDefault')
              .timeout(const Duration(seconds: 2)) ==
          true;
    } on Object {
      return false;
    }
  }

  Future<SmartRouteAppsSnapshot> read() async {
    try {
      final result = await _channel
          .invokeMapMethod<Object?, Object?>('getSmartRouteApps')
          .timeout(_timeout);
      return result == null
          ? const SmartRouteAppsSnapshot()
          : SmartRouteAppsSnapshot.fromMap(result);
    } on Object {
      return const SmartRouteAppsSnapshot();
    }
  }

  Future<void> saveSelection(Set<String> selected) async {
    final saved = await _channel
        .invokeMethod<bool>('saveSmartRouteApps', {
          'packages': selected.toList()..sort(),
        })
        .timeout(_timeout);
    if (saved != true) throw StateError('Smart Route selection was not saved');
  }

  Future<void> clearBinding() async {
    final saved = await _channel
        .invokeMethod<bool>('clearSmartRouteAppBinding')
        .timeout(_timeout);
    if (saved != true) throw StateError('Smart Route routing was not revoked');
  }

  /// Same config bytes and save path; the opt-in is separate from raw JSON.
  Future<bool> saveManagedConfig(
    String config, {
    bool smartRouteApps = true,
    bool hermesManagedXhttp = false,
  }) async =>
      await _channel.invokeMethod<bool>('saveConfig', {
        'config': config,
        if (smartRouteApps) 'smartRouteApps': true,
        if (hermesManagedXhttp) 'hermesManagedXhttp': true,
      }) ??
      false;
}
