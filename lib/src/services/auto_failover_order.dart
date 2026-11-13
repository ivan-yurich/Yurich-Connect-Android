import '../models/vpn_profile.dart';

/// Keep the preferred server first, then try one server per known location
/// before the remaining servers. An unknown location proves no diversity.
List<VpnProfile> orderAutoFailoverCandidates(
  Iterable<VpnProfile> ranked, {
  required String? Function(VpnProfile) locationOf,
}) {
  final seenIds = <String>{};
  final seenLocations = <String>{};
  final preferred = <VpnProfile>[];
  final remaining = <VpnProfile>[];
  for (final profile in ranked) {
    if (!seenIds.add(profile.id)) continue;
    final location = locationOf(profile)?.trim().toUpperCase();
    final newLocation =
        location != null && location.isNotEmpty && seenLocations.add(location);
    if (preferred.isEmpty || newLocation) {
      preferred.add(profile);
    } else {
      remaining.add(profile);
    }
  }
  return [...preferred, ...remaining];
}
