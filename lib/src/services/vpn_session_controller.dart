import 'dart:async';

enum VpnSessionCommand { connect, switchProfile, disconnect, maintenance }

final class VpnSessionOperation {
  const VpnSessionOperation({required this.generation, required this.command});

  final int generation;
  final VpnSessionCommand command;

  bool get requiresRunningIntent => switch (command) {
    VpnSessionCommand.connect || VpnSessionCommand.switchProfile => true,
    VpnSessionCommand.disconnect || VpnSessionCommand.maintenance => false,
  };
}

final class VpnSessionCancelled implements Exception {
  const VpnSessionCancelled(this.generation);

  final int generation;

  @override
  String toString() => 'VPN session operation $generation was superseded.';
}

final class VpnSessionController {
  Future<void> _tail = Future<void>.value();
  int _generation = 0;
  int _pendingOperations = 0;
  bool _desiredRunning = false;
  bool _disposed = false;
  Completer<void>? _supersededSignal;
  int? _supersededSignalGeneration;

  int get generation => _generation;
  int get pendingOperations => _pendingOperations;
  bool get hasPendingOperations => _pendingOperations > 0;
  bool get desiredRunning => _desiredRunning;

  VpnSessionOperation beginConnect() =>
      _begin(VpnSessionCommand.connect, desiredRunning: true);

  VpnSessionOperation beginProfileSwitch() =>
      _begin(VpnSessionCommand.switchProfile, desiredRunning: true);

  VpnSessionOperation beginDisconnect() =>
      _begin(VpnSessionCommand.disconnect, desiredRunning: false);

  VpnSessionOperation beginMaintenance() {
    return _begin(
      VpnSessionCommand.maintenance,
      desiredRunning: _desiredRunning,
    );
  }

  bool isCurrent(VpnSessionOperation operation) {
    if (_disposed || operation.generation != _generation) {
      return false;
    }
    return !operation.requiresRunningIntent || _desiredRunning;
  }

  void ensureCurrent(VpnSessionOperation operation) {
    if (!isCurrent(operation)) {
      throw VpnSessionCancelled(operation.generation);
    }
  }

  /// Completes with [future] unless a newer session operation supersedes it.
  ///
  /// This is intended for cancellable waits and read-only polling. Native
  /// start/stop mutations must still be awaited so commands cannot overlap.
  Future<T> cancelWhenSuperseded<T>(
    VpnSessionOperation operation,
    Future<T> future,
  ) {
    ensureCurrent(operation);
    final signal = _supersededSignal;
    if (signal == null || _supersededSignalGeneration != operation.generation) {
      return Future<T>.error(VpnSessionCancelled(operation.generation));
    }
    return Future.any<T>(<Future<T>>[
      future,
      signal.future.then<T>((_) {
        throw VpnSessionCancelled(operation.generation);
      }),
    ]);
  }

  Future<T> enqueue<T>(
    VpnSessionOperation operation,
    Future<T> Function() action,
  ) {
    if (_disposed) {
      return Future<T>.error(VpnSessionCancelled(operation.generation));
    }

    final completer = Completer<T>();
    _pendingOperations += 1;
    final scheduled = _tail.catchError((_) {}).then((_) async {
      try {
        ensureCurrent(operation);
        completer.complete(await action());
      } on Object catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      } finally {
        _pendingOperations -= 1;
      }
    });
    _tail = scheduled.catchError((_) {});
    return completer.future;
  }

  void dispose() {
    _disposed = true;
    _generation += 1;
    _desiredRunning = false;
    _completeSupersededSignal();
  }

  VpnSessionOperation _begin(
    VpnSessionCommand command, {
    required bool desiredRunning,
  }) {
    if (_disposed) {
      throw StateError('VPN session controller is disposed.');
    }
    _completeSupersededSignal();
    _generation += 1;
    _desiredRunning = desiredRunning;
    _supersededSignal = Completer<void>();
    _supersededSignalGeneration = _generation;
    return VpnSessionOperation(generation: _generation, command: command);
  }

  void _completeSupersededSignal() {
    final signal = _supersededSignal;
    if (signal != null && !signal.isCompleted) {
      signal.complete();
    }
    _supersededSignal = null;
    _supersededSignalGeneration = null;
  }
}
