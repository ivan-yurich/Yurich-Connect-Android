final class SoakCounterPublishCadence {
  SoakCounterPublishCadence({
    this.minimumInterval = const Duration(seconds: 55),
  });

  final Duration minimumInterval;

  DateTime? _lastSuccessfulPublishAt;
  int? _activeAttempt;
  int _nextAttempt = 0;

  int? tryBegin(DateTime now) {
    if (_activeAttempt != null) {
      return null;
    }

    final lastSuccessfulPublishAt = _lastSuccessfulPublishAt;
    if (lastSuccessfulPublishAt != null) {
      final elapsed = now.difference(lastSuccessfulPublishAt);
      if (!elapsed.isNegative && elapsed < minimumInterval) {
        return null;
      }
    }

    _nextAttempt += 1;
    _activeAttempt = _nextAttempt;
    return _activeAttempt;
  }

  void complete({
    required int attempt,
    required bool succeeded,
    required DateTime at,
  }) {
    if (_activeAttempt != attempt) {
      return;
    }
    if (succeeded) {
      _lastSuccessfulPublishAt = at;
    }
    _activeAttempt = null;
  }

  void reset() {
    _lastSuccessfulPublishAt = null;
    _activeAttempt = null;
  }
}
