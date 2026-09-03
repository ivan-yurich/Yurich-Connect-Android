import 'dart:async';

/// Returns as soon as one candidate succeeds, or false after every candidate
/// either fails or completes with false.
Future<bool> firstSuccessfulFuture(Iterable<Future<bool>> candidates) {
  final pending = candidates.toList(growable: false);
  if (pending.isEmpty) {
    return Future<bool>.value(false);
  }

  final completer = Completer<bool>();
  var remaining = pending.length;

  void completeCandidate(bool successful) {
    if (completer.isCompleted) {
      return;
    }
    if (successful) {
      completer.complete(true);
      return;
    }
    remaining -= 1;
    if (remaining == 0) {
      completer.complete(false);
    }
  }

  for (final candidate in pending) {
    candidate.then(
      completeCandidate,
      onError: (Object _, StackTrace _) => completeCandidate(false),
    );
  }
  return completer.future;
}
