/// Classifies timestamp evidence after the caller has checked whether it owns
/// tunnel health. Confirmed health outranks traffic and the session start time.
abstract final class TunnelStalenessPolicy {
  static bool isStale({
    required DateTime now,
    required Duration grace,
    required DateTime? lastHealthyAt,
    required DateTime? lastTrafficAt,
    required DateTime? connectedSince,
  }) {
    if (lastHealthyAt != null) {
      return now.difference(lastHealthyAt) > grace;
    }

    if (lastTrafficAt != null) {
      return now.difference(lastTrafficAt) > grace;
    }

    if (connectedSince == null) {
      return true;
    }
    return now.difference(connectedSince) > grace;
  }
}
