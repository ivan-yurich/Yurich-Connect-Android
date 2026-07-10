import '../models/vpn_profile.dart';
import 'profile_store.dart';

class SubscriptionProfileReconcileResult {
  const SubscriptionProfileReconcileResult({
    required this.profiles,
    required this.selectedProfileId,
  });

  final List<VpnProfile> profiles;
  final String? selectedProfileId;
}

class SubscriptionProfileReconciler {
  const SubscriptionProfileReconciler();

  SubscriptionProfileReconcileResult replaceRefreshedSources({
    required List<VpnProfile> existing,
    required List<VpnProfile> imported,
    required Set<String> refreshedSources,
    required String? selectedProfileId,
  }) {
    final normalizedSources = refreshedSources
        .map(ProfileStore.subscriptionSourceKeyFromText)
        .whereType<String>()
        .toSet();
    final retained = existing.where((profile) {
      final source = ProfileStore.subscriptionSourceKeyFor(profile);
      return source == null || !normalizedSources.contains(source);
    });
    final profilesById = <String, VpnProfile>{
      for (final profile in retained) profile.id: profile,
      for (final profile in imported) profile.id: profile,
    };
    final profiles = profilesById.values.toList(growable: false);

    var resolvedSelectedId = selectedProfileId;
    if (resolvedSelectedId == null ||
        !profilesById.containsKey(resolvedSelectedId)) {
      final previous = _byId(existing, selectedProfileId);
      final replacement = previous == null
          ? null
          : findLogicalMatch(previous, imported);
      resolvedSelectedId = replacement?.id;
    }
    resolvedSelectedId ??= profiles.isEmpty ? null : profiles.first.id;

    return SubscriptionProfileReconcileResult(
      profiles: profiles,
      selectedProfileId: resolvedSelectedId,
    );
  }

  VpnProfile? findLogicalMatch(
    VpnProfile profile,
    Iterable<VpnProfile> candidates,
  ) {
    final source = ProfileStore.subscriptionSourceKeyFor(profile);
    final matches = candidates
        .where((candidate) {
          return ProfileStore.subscriptionSourceKeyFor(candidate) == source &&
              candidate.kind == profile.kind &&
              _normalizedServer(candidate.server) ==
                  _normalizedServer(profile.server) &&
              candidate.port == profile.port;
        })
        .toList(growable: false);
    if (matches.isEmpty) {
      return null;
    }

    for (final candidate in matches) {
      if (candidate.name == profile.name) {
        return candidate;
      }
    }
    return matches.first;
  }

  VpnProfile? _byId(List<VpnProfile> profiles, String? id) {
    if (id == null) {
      return null;
    }
    for (final profile in profiles) {
      if (profile.id == id) {
        return profile;
      }
    }
    return null;
  }

  String? _normalizedServer(String? value) => value?.trim().toLowerCase();
}
