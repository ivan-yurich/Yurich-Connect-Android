import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:aurum_vpn/src/services/vpn_session_controller.dart';

void main() {
  test('manual disconnect invalidates an in-flight connect', () async {
    final controller = VpnSessionController();
    final connect = controller.beginConnect();
    final entered = Completer<void>();
    final release = Completer<void>();

    final connectFuture = controller.enqueue(connect, () async {
      entered.complete();
      await release.future;
      controller.ensureCurrent(connect);
    });
    await entered.future;

    final disconnect = controller.beginDisconnect();
    release.complete();
    await expectLater(connectFuture, throwsA(isA<VpnSessionCancelled>()));
    await controller.enqueue(disconnect, () async {});

    expect(controller.desiredRunning, isFalse);
    expect(controller.hasPendingOperations, isFalse);
  });

  test('latest profile switch supersedes an older switch', () async {
    final controller = VpnSessionController();
    final first = controller.beginProfileSwitch();
    final second = controller.beginProfileSwitch();

    await expectLater(
      controller.enqueue(first, () async {}),
      throwsA(isA<VpnSessionCancelled>()),
    );
    await controller.enqueue(second, () async {});

    expect(controller.generation, second.generation);
    expect(controller.desiredRunning, isTrue);
  });

  test(
    'only the latest queued switch runs after an in-flight switch',
    () async {
      final controller = VpnSessionController();
      final first = controller.beginProfileSwitch();
      final entered = Completer<void>();
      final release = Completer<void>();
      final executed = <int>[];

      final firstFuture = controller.enqueue(first, () async {
        entered.complete();
        await release.future;
        controller.ensureCurrent(first);
        executed.add(first.generation);
      });
      await entered.future;

      final second = controller.beginProfileSwitch();
      final secondFuture = controller.enqueue(
        second,
        () async => executed.add(second.generation),
      );
      final latest = controller.beginProfileSwitch();
      final latestFuture = controller.enqueue(
        latest,
        () async => executed.add(latest.generation),
      );

      release.complete();
      await expectLater(firstFuture, throwsA(isA<VpnSessionCancelled>()));
      await expectLater(secondFuture, throwsA(isA<VpnSessionCancelled>()));
      await latestFuture;

      expect(executed, <int>[latest.generation]);
      expect(controller.hasPendingOperations, isFalse);
    },
  );

  test('queue keeps running after a failed operation', () async {
    final controller = VpnSessionController();
    final first = controller.beginConnect();
    final failure = controller.enqueue<void>(first, () async {
      throw StateError('failed');
    });
    await expectLater(failure, throwsStateError);

    final second = controller.beginProfileSwitch();
    var completed = false;
    await controller.enqueue(second, () async => completed = true);

    expect(completed, isTrue);
    expect(controller.hasPendingOperations, isFalse);
  });

  test('disconnect operation remains current with stopped intent', () {
    final controller = VpnSessionController();
    final disconnect = controller.beginDisconnect();

    expect(controller.isCurrent(disconnect), isTrue);
    expect(controller.desiredRunning, isFalse);
  });

  test('dispose invalidates all operations', () {
    final controller = VpnSessionController();
    final connect = controller.beginConnect();

    controller.dispose();

    expect(controller.isCurrent(connect), isFalse);
    expect(() => controller.beginConnect(), throwsStateError);
  });

  test('superseding an operation cancels its active wait', () async {
    final controller = VpnSessionController();
    final first = controller.beginProfileSwitch();
    final neverCompletes = Completer<void>();

    final waiting = controller.cancelWhenSuperseded(
      first,
      neverCompletes.future,
    );
    final latest = controller.beginProfileSwitch();

    await expectLater(waiting, throwsA(isA<VpnSessionCancelled>()));
    expect(controller.isCurrent(latest), isTrue);
  });

  test('disposing the controller cancels an active wait', () async {
    final controller = VpnSessionController();
    final connect = controller.beginConnect();
    final neverCompletes = Completer<void>();

    final waiting = controller.cancelWhenSuperseded(
      connect,
      neverCompletes.future,
    );
    controller.dispose();

    await expectLater(waiting, throwsA(isA<VpnSessionCancelled>()));
  });
}
