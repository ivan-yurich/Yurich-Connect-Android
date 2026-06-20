import '../models/profile_stability.dart';
import '../models/vpn_profile.dart';

class ProfileAutoSelector {
  const ProfileAutoSelector();

  VpnProfile? choose(
    List<VpnProfile> profiles, {
    String? selectedProfileId,
    Map<String, int> pingMs = const {},
    Set<String> offlineProfileIds = const {},
    Map<String, ProfileStabilityStats> stabilityStats = const {},
    DateTime? now,
  }) {
    final selected = _findSelected(profiles, selectedProfileId);
    if (selected != null &&
        _isAutoCandidate(selected, offlineProfileIds, stabilityStats, now)) {
      return selected;
    }

    final candidates = profiles
        .where(
          (profile) =>
              _isAutoCandidate(profile, offlineProfileIds, stabilityStats, now),
        )
        .toList(growable: false);
    if (candidates.isEmpty) {
      return null;
    }

    final sorted = [...candidates]
      ..sort(
        (a, b) => _score(
          a,
          pingMs,
          stabilityStats,
          now,
        ).compareTo(_score(b, pingMs, stabilityStats, now)),
      );
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

  bool _isAutoCandidate(
    VpnProfile profile,
    Set<String> offlineProfileIds,
    Map<String, ProfileStabilityStats> stabilityStats,
    DateTime? now,
  ) {
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
    if (stabilityStats[profile.id]?.isTemporarilyUnstable(now: now) == true) {
      return false;
    }

    final expiresAt = profile.subscriptionExpiresAt;
    final current = (now ?? DateTime.now()).toUtc();
    if (expiresAt != null && expiresAt.toUtc().isBefore(current)) {
      return false;
    }

    return true;
  }

  int _score(
    VpnProfile profile,
    Map<String, int> pingMs,
    Map<String, ProfileStabilityStats> stabilityStats,
    DateTime? now,
  ) {
    final kindScore = switch (profile.kind) {
      VpnProfileKind.vlessReality => 0,
      VpnProfileKind.naive => 120,
      _ => 10000,
    };
    final pingScore = _pingScore(pingMs[profile.id]);
    final expiryScore = _expiryScore(profile.subscriptionExpiresAt, now);
    final stabilityScore =
        stabilityStats[profile.id]?.autoSelectPenalty(now: now) ?? 0;
    return kindScore + pingScore + expiryScore + stabilityScore;
  }

  int _pingScore(int? ping) {
    if (ping == null || ping <= 0) {
      return 900;
    }
    if (ping > 1600) {
      return 1600;
    }
    return ping;
  }

  int _expiryScore(DateTime? expiresAt, DateTime? now) {
    if (expiresAt == null) {
      return 40;
    }
    final remaining = expiresAt.toUtc().difference(
      (now ?? DateTime.now()).toUtc(),
    );
    if (remaining.inDays < 5) {
      return 220;
    }
    return 0;
  }
}
