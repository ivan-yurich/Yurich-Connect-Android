import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:aurum_vpn/src/services/direct_latency_probe.dart';
// Use the fake clock already supplied by flutter_test.
// ignore: depend_on_referenced_packages
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

const _ipv4 = '1.1.1.1';
const _ipv6 = '2606:4700::1111';

void main() {
  for (final (address, executable, message, milliseconds) in [
    (_ipv4, '/system/bin/ping', 'ttl=55 time=23.45 ms', 24),
    (_ipv6, '/system/bin/ping6', 'hlim=59 time<1 ms', 1),
  ]) {
    test(
      'ICMP uses $executable with a numeric address and fixed flags',
      () async {
        final probe = DirectLatencyProbe();
        final process = _PingProcess();
        final target = InternetAddress(address);
        var launches = 0;
        final result = probe.runIcmpWithStarter(
          target,
          startProcess: (binary, arguments) async {
            launches++;
            expect(binary, executable);
            expect(arguments, ['-n', '-c', '1', '-W', '1', target.address]);
            return process;
          },
        );
        process.finish(message);

        _expectReading(await result, milliseconds);
        expect(launches, 1);
        probe.close();
        expect(process.signals, [ProcessSignal.sigterm]);
      },
    );
  }

  for (final (label, output, status, expected) in [
    ('minimum is 1 ms', 'time=0.0 ms', 0, 1),
    ('maximum is 5000 ms', 'time=5001.1 ms', 0, 5000),
    ('ignores missing RTT', '1 packets transmitted, 0 received', 0, null),
    ('ignores malformed RTT', 'time=not-a-number ms', 0, null),
    ('ignores overflow', 'time=${List.filled(400, '9').join()} ms', 0, null),
    ('ignores RTT on failed exit', 'time=4 ms', 1, null),
  ]) {
    test('ICMP $label', () async {
      final probe = DirectLatencyProbe();
      final process = _PingProcess();
      final result = _run(probe, process);
      process.finish(output, status: status);

      final reading = await result;
      if (expected == null) {
        expect(reading, isNull);
      } else {
        _expectReading(reading, expected);
      }
      probe.close();
      expect(process.signals, [ProcessSignal.sigterm]);
    });
  }

  test('ICMP requires a starter, a public address and an open batch', () async {
    final probe = DirectLatencyProbe();
    Future<Process> forbidden(String _, List<String> _) async =>
        fail('Unexpected process launch');

    expect(
      await probe.runIcmpWithStarter(
        InternetAddress(_ipv4),
        startProcess: null,
      ),
      isNull,
    );
    for (final literal in ['127.0.0.1', '::1']) {
      expect(
        await probe.runIcmpWithStarter(
          InternetAddress(literal),
          startProcess: forbidden,
        ),
        isNull,
      );
    }
    probe.close();
    expect(
      await probe.runIcmpWithStarter(
        InternetAddress(_ipv4),
        startProcess: forbidden,
      ),
      isNull,
    );
  });

  test('ICMP timeout cleans up once and ignores late process events', () {
    fakeAsync((clock) {
      final probe = DirectLatencyProbe();
      final process = _PingProcess();
      final outcomes = _observe(_run(probe, process));
      clock.elapse(const Duration(milliseconds: 1449));
      expect(process.output.hasListener, isTrue);
      expect(process.errors.hasListener, isTrue);
      expect(outcomes, isEmpty);
      expect(process.signals, isEmpty);

      clock.elapse(const Duration(milliseconds: 1));
      expect(outcomes, [isA<TimeoutException>()]);
      expect(process.signals, [ProcessSignal.sigterm]);

      process.errors.addError(StateError('late stderr failure'));
      process.finish('time=3 ms');
      clock.flushMicrotasks();
      probe.close();
      expect(outcomes, [isA<TimeoutException>()]);
      expect(process.signals, [ProcessSignal.sigterm]);
      expect(clock.nonPeriodicTimerCount, 0);
    });
  });

  for (final rejectFirst in [false, true]) {
    test(
      'ICMP close ignores valid late output (retry signal: $rejectFirst)',
      () {
        fakeAsync((clock) {
          final probe = DirectLatencyProbe();
          final process = _PingProcess(rejectFirstSignal: rejectFirst);
          final outcomes = _observe(_run(probe, process));
          clock.flushMicrotasks();
          expect(process.output.hasListener, isTrue);
          expect(outcomes, isEmpty);

          probe.close();
          expect(process.signals, [ProcessSignal.sigterm]);
          process.finish('time=2.5 ms');
          clock.flushMicrotasks();
          probe.close();
          expect(outcomes, [null]);
          expect(process.signals, [
            ProcessSignal.sigterm,
            if (rejectFirst) ProcessSignal.sigterm,
          ]);
          expect(clock.nonPeriodicTimerCount, 0);
        });
      },
    );
  }

  test('ICMP closes a process arriving after the batch was cancelled', () {
    fakeAsync((clock) {
      final probe = DirectLatencyProbe();
      final process = _PingProcess();
      final startup = Completer<Process>();
      final outcomes = _observe(
        probe.runIcmpWithStarter(
          InternetAddress(_ipv4),
          startProcess: (_, _) => startup.future,
        ),
      );
      clock.flushMicrotasks();
      expect(outcomes, isEmpty);

      probe.close();
      startup.complete(process);
      clock.flushMicrotasks();
      probe.close();
      expect(outcomes, [null]);
      expect(process.signals, [ProcessSignal.sigterm]);
      expect(process.output.hasListener, isFalse);
      expect(process.errors.hasListener, isFalse);
      expect(clock.nonPeriodicTimerCount, 0);
    });
  });

  test('ICMP releases the process if opening stderr throws', () async {
    final error = StateError('stderr is unavailable');
    final probe = DirectLatencyProbe();
    final process = _PingProcess(stderrAccessError: error);

    await expectLater(_run(probe, process), throwsA(same(error)));
    expect(process.signals, [ProcessSignal.sigterm]);
    probe.close();
    expect(process.signals, [ProcessSignal.sigterm]);
  });

  test('ICMP releases the process if stdout cannot be decoded', () async {
    final probe = DirectLatencyProbe();
    final process = _PingProcess();
    final result = _run(probe, process);
    process.output.add([0xff]);
    process.finish('');

    await expectLater(result, throwsFormatException);
    expect(process.signals, [ProcessSignal.sigterm]);
    probe.close();
    expect(process.signals, [ProcessSignal.sigterm]);
  });
}

Future<DirectLatencyReading?> _run(DirectLatencyProbe probe, Process process) =>
    probe.runIcmpWithStarter(
      InternetAddress(_ipv4),
      startProcess: (_, _) async => process,
    );

void _expectReading(DirectLatencyReading? reading, int milliseconds) {
  expect(reading?.kind, DirectLatencyKind.icmp);
  expect(reading?.milliseconds, milliseconds);
}

List<Object?> _observe(Future<DirectLatencyReading?> future) {
  final outcomes = <Object?>[];
  unawaited(
    future.then<void>(
      outcomes.add,
      onError: (Object error, StackTrace _) => outcomes.add(error),
    ),
  );
  return outcomes;
}

class _PingProcess implements Process {
  _PingProcess({this.rejectFirstSignal = false, this.stderrAccessError});

  final bool rejectFirstSignal;
  final Object? stderrAccessError;
  final output = StreamController<List<int>>();
  final errors = StreamController<List<int>>();
  final signals = <ProcessSignal>[];
  final _exit = Completer<int>();

  @override
  Stream<List<int>> get stdout => output.stream;

  @override
  Stream<List<int>> get stderr {
    if (stderrAccessError case final Object error) throw error;
    return errors.stream;
  }

  @override
  Future<int> get exitCode => _exit.future;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    signals.add(signal);
    return !rejectFirstSignal || signals.length > 1;
  }

  void finish(String message, {int status = 0}) {
    output.add(utf8.encode(message));
    unawaited(output.close());
    unawaited(errors.close());
    _exit.complete(status);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
