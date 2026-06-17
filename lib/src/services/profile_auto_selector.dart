import '../models/vpn_profile.dart';

class ProfileAutoSelector {
  const ProfileAutoSelector();

  VpnProfile? choose(
    List<VpnProfile> profiles, {
    String? selectedProfileId,
    Map<String, int> pingMs = const {},
    Set<String> offlineProfileIds = const {},
  }) {
    final selected = _findSelected(profiles, selectedProfileId);
    if (selected != null && _isAutoCandidate(selected, offlineProfileIds)) {
      return selected;
    }

    final candidates = profiles
        .where((profile) => _isAutoCandidate(profile, offlineProfileIds))
        .toList(growable: false);
    if (candidates.isEmpty) {
      return null;
    }

    final sorted = [...candidates]
      ..sort((a, b) => _score(a, pingMs).compareTo(_score(b, pingMs)));
    return sorted.first;
  }

  VpnProfile? _findSelected(List<VpnProfile> profiles, String? selectedId) {
    if (selectedId == null) {
      return null;
    }
    for (final profile in profiles) {
      if (profile.id == selectedId) {
        return profile;
      }
    }
    return null;
  }

  bool _isAutoCandidate(VpnProfile profile, Set<String> offlineProfileIds) {
    if (!profile.kind.isClientSupported) {
      return false;
    }
    if (profile.kind == VpnProfileKind.hysteria ||
        profile.kind == VpnProfileKind.hysteria2) {
      return false;
    }
    if (offlineProfileIds.contains(profile.id)) {
      return false;
    }

    final expiresAt = profile.subscriptionExpiresAt;
    if (expiresAt != null &&
        expiresAt.toUtc().isBefore(DateTime.now().toUtc())) {
      return false;
    }

    return true;
  }

  int _score(VpnProfile profile, Map<String, int> pingMs) {
    final kindScore = switch (profile.kind) {
      VpnProfileKind.vlessReality => 0,
      VpnProfileKind.naive => 160,
      _ => 10000,
    };
    final pingScore = pingMs[profile.id] ?? 900;
    final expiryScore = _expiryScore(profile.subscriptionExpiresAt);
    return kindScore + pingScore + expiryScore;
  }

  int _expiryScore(DateTime? expiresAt) {
    if (expiresAt == null) {
      return 40;
    }
    final remaining = expiresAt.toUtc().difference(DateTime.now().toUtc());
    if (remaining.inDays < 5) {
      return 220;
    }
    return 0;
  }
}
