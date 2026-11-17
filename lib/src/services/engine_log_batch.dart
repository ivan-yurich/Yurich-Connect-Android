/// Commits a bounded batch of queued engine logs. In the foreground
/// the view publishes the commit synchronously (e.g. via setState).
abstract final class EngineLogBatch {
  static void flush({
    required List<String> pending,
    required List<String> stored,
    required int limit,
    required void Function(void Function())? publish,
    required void Function(String, Object, StackTrace) onError,
  }) {
    try {
      if (pending.isEmpty) return;

      void commit() {
        stored.addAll(pending);
        pending.clear();
        if (stored.length > limit) {
          stored.removeRange(0, stored.length - limit);
        }
      }

      if (publish == null) {
        commit();
      } else {
        publish(commit);
      }
    } on Object catch (error, stackTrace) {
      onError('log-flush', error, stackTrace);
    }
  }
}
