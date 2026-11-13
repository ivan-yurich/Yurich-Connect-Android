import '../models/profile_stability.dart';
import '../models/profile_network_stability.dart';
import '../models/vpn_profile.dart';

class ProfileAutoSelector {
  const ProfileAutoSelector();

  /// Separate from the legacy preference-first picker: this mode includes
  /// UDP profiles and never treats an unmeasured profile as the closest.
  /// [preferCurrentNetwork] demotes recent failures on this network rather
  /// than excluding candidates based on failures on another network.
  List<VpnProfile> rankForLatency(
    List<VpnProfile> profiles, {
    Map<String, int> directLatencyMs = const {},
    Set<String> offlineProfileIds = const {},
    Map<String, ProfileStabilityStats> stabilityStats = const {},
    Map<String, ProfileNetworkStabilityStats> networkStats = const {},
    String? lastProfileId,
    DateTime? now,
    bool preferCurrentNetwork = false,
  }) {
    final current = now ?? DateTime.now();
    const failureCooldown = Duration(minutes: 3);
    final candidates = profiles.where((profile) {
      if (!profile.kind.isClientSupported ||
          profile.rawConfig != null ||
          offlineProfileIds.contains(profile.id) ||
          (profile.subscriptionExpiresAt?.isBefore(current) ?? false)) {
        return false;
      }
      if (preferCurrentNetwork) return true;
      final stats = stabilityStats[profile.id];
      final lastFailure = stats?.lastFailureAt;
      final lastSuccess = stats?.lastHealthyAt ?? stats?.lastStartedAt;
      final recentFailure =
          lastFailure != null &&
          (lastSuccess == null || lastFailure.isAfter(lastSuccess)) &&
          current.difference(lastFailure) < failureCooldown;
      return stats?.isTemporarilyUnstable(now: current) != true &&
          !recentFailure;
    }).toList();

    int currentNetworkPenalty(VpnProfile profile) {
      final stats = networkStats[profile.id];
      final lastFailure = stats?.lastFailureAt;
      if (lastFailure == null) return 0;
      final lastSuccess = stats?.lastHealthyAt;
      final age = current.difference(lastFailure);
      return !age.isNegative &&
              age < failureCooldown &&
              (lastSuccess == null || lastFailure.isAfter(lastSuccess))
          ? 1
          : 0;
    }

    int? validLatency(VpnProfile profile) {
      final value = directLatencyMs[profile.id];
      return value != null && value > 0 ? value : null;
    }

    candidates.sort((a, b) {
      if (a.id == b.id) return 0;
      if (preferCurrentNetwork) {
        final recentFailure = currentNetworkPenalty(
          a,
        ).compareTo(currentNetworkPenalty(b));
        if (recentFailure != 0) return recentFailure;
      }
      final aLatency = validLatency(a), bLatency = validLatency(b);
      if (aLatency != null || bLatency != null) {
        if (aLatency == null) return 1;
        if (bLatency == null) return -1;
        final measured = aLatency.compareTo(bLatency);
        if (measured != 0) return measured;
      }
      final aNetwork = networkStats[a.id], bNetwork = networkStats[b.id];
      final networkSuccess = (bNetwork?.successfulStarts ?? 0).compareTo(
        aNetwork?.successfulStarts ?? 0,
      );
      if (networkSuccess != 0) return networkSuccess;
      final aStats = stabilityStats[a.id], bStats = stabilityStats[b.id];
      final successful = (bStats?.successfulStarts ?? 0).compareTo(
        aStats?.successfulStarts ?? 0,
      );
      if (successful != 0) return successful;
      if (!preferCurrentNetwork) {
        final reliability = (aStats?.autoSelectPenalty(now: current) ?? 0)
            .compareTo(bStats?.autoSelectPenalty(now: current) ?? 0);
        if (reliability != 0) return reliability;
      }
      if (a.id == lastProfileId) return -1;
      if (b.id == lastProfileId) return 1;
      return a.id.compareTo(b.id);
    });
    return candidates;
  }

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
