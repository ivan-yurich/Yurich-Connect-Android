import 'dart:async';
import 'dart:io';

import 'package:aurum_vpn/src/models/profile_network_stability.dart';
import 'package:aurum_vpn/src/models/profile_stability.dart';
import 'package:aurum_vpn/src/models/vpn_profile.dart';
import 'package:aurum_vpn/src/services/direct_latency_probe.dart';
import 'package:aurum_vpn/src/services/profile_auto_selector.dart';
// Use the fake clock already supplied by flutter_test.
// ignore: depend_on_referenced_packages
import 'package:fake_async/fake_async.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

VpnProfile profile(
  String id, {
  String? host,
  VpnProfileKind? kind,
  DateTime? expiry,
}) => VpnProfile(
  id: id,
  name: id,
  kind: kind ?? VpnProfileKind.vlessReality,
  originalInput: '',
  server: host ?? 'vpn.example.org',
  port: 443,
  subscriptionExpiresAt: expiry,
);

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.tecclub.flutter_singbox/methods');
  test('direct checks never dial local, special or untrusted host syntax', () {
    for (final ip in [
      '127.0.0.1',
      '0.0.0.0',
      '10.1.2.3',
      '192.168.0.1',
      '100.64.0.1',
      '169.254.169.254',
      '172.31.0.1',
      '192.0.2.1',
      '198.51.100.1',
      '203.0.113.1',
      '224.1.2.3',
      '::1',
      'fc00::1',
      'fe80::1',
      '::ffff:127.0.0.1',
      '2001:db8::1',
      '2001::1',
    ]) {
      expect(
        DirectLatencyProbe.isPublicAddress(InternetAddress(ip)),
        isFalse,
        reason: ip,
      );
      expect(DirectLatencyProbe.eligible(profile('local', host: ip)), isFalse);
    }
    for (final host in [
      'http://a.example.org',
      'a.local',
      'localhost',
      '-c',
      'a.example.org:443',
    ]) {
      expect(
        DirectLatencyProbe.eligible(profile('bad', host: host)),
        isFalse,
        reason: host,
      );
    }
    expect(
      DirectLatencyProbe.isPublicAddress(InternetAddress('1.1.1.1')),
      isTrue,
    );
    expect(
      DirectLatencyProbe.isPublicAddress(InternetAddress('2606:4700::1111')),
      isTrue,
    );
    expect(DirectLatencyProbe.eligible(profile('eligible')), isTrue);
  });

  test('absent or changed Android gate stops before DNS', () async {
    final calls = <String>[];
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      calls.add(call.method);
      return 'changed-network';
    });
    addTearDown(
      () => binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
    final probe = DirectLatencyProbe();
    addTearDown(probe.close);
    expect(
      await probe.check(
        profile('candidate'),
        networkKey: 'prior',
        stillAllowed: () => true,
      ),
      isNull,
    );
    expect(calls, ['getDirectProbeNetwork']);
    probe.close();
    expect(
      await probe.check(
        profile('candidate'),
        networkKey: 'changed-network',
        stillAllowed: () => true,
      ),
      isNull,
    );
    expect(calls, hasLength(1));
  });

  test(
    'closing the batch cancels Android DNS and ignores late answers',
    () async {
      final started = Completer<int>();
      final cancelled = Completer<int>();
      final answer = Completer<List<String>>();
      binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        switch (call.method) {
          case 'getDirectProbeNetwork':
            return 'physical';
          case 'resolveDirectProbeHost':
            started.complete(call.arguments['request'] as int);
            return answer.future;
          case 'cancelDirectProbeDns':
            cancelled.complete(call.arguments['request'] as int);
            return null;
          default:
            fail('Unexpected platform call: ${call.method}');
        }
      });
      addTearDown(
        () => binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      final probe = DirectLatencyProbe();
      final result = probe.check(
        profile('candidate'),
        networkKey: 'physical',
        stillAllowed: () => true,
      );
      final request = await started.future;
      probe.close();
      expect(await cancelled.future, request);
      answer.complete(['1.1.1.1']);
      expect(await result, isNull);
    },
  );

  test(
    'DNS answers containing only unsafe addresses never open a socket',
    () async {
      final methods = <String>[];
      binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        methods.add(call.method);
        return switch (call.method) {
          'getDirectProbeNetwork' => 'physical',
          'resolveDirectProbeHost' => [
            '127.0.0.1',
            'fe80::2%scope',
            'not-an-address',
          ],
          _ => fail('Unexpected native call: ${call.method}'),
        };
      });
      addTearDown(
        () => binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      final probe = DirectLatencyProbe();
      addTearDown(probe.close);
      final dialed = <Object?>[];
      await IOOverrides.runZoned(
        () async => expect(
          await probe.check(
            profile('candidate'),
            networkKey: 'physical',
            stillAllowed: () => true,
          ),
          isNull,
        ),
        socketStartConnect:
            (host, port, {sourceAddress, sourcePort = 0}) async {
              dialed.add(host);
              throw StateError('Network is disabled in this test');
            },
      );
      expect(methods, ['getDirectProbeNetwork', 'resolveDirectProbeHost']);
      expect(dialed, isEmpty);
    },
  );

  test(
    'TCP probe uses a validated DNS result and releases its socket',
    () async {
      final socket = _ProbeSocket();
      var cancellations = 0;
      var gates = 0;
      binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        switch (call.method) {
          case 'getDirectProbeNetwork':
            gates++;
            return 'physical';
          case 'resolveDirectProbeHost':
            expect(call.arguments['host'], 'vpn.example.org');
            expect(call.arguments['network'], 'physical');
            return ['10.0.0.3', '2606:4700::1111'];
          default:
            fail('Unexpected native call: ${call.method}');
        }
      });
      addTearDown(
        () => binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      final probe = DirectLatencyProbe();
      addTearDown(probe.close);
      final reading = await IOOverrides.runZoned(
        () => probe.check(
          profile('candidate'),
          networkKey: 'physical',
          stillAllowed: () => true,
        ),
        socketStartConnect:
            (host, port, {sourceAddress, sourcePort = 0}) async {
              expect(host, InternetAddress('2606:4700::1111'));
              expect(port, 443);
              expect(gates, 2);
              return ConnectionTask.fromSocket(
                Future<Socket>.value(socket),
                () => cancellations++,
              );
            },
      );
      expect(reading?.kind, DirectLatencyKind.tcp);
      expect(reading?.milliseconds, inInclusiveRange(1, 5000));
      expect(socket.destroys, 1);
      expect(cancellations, 1);
    },
  );

  test(
    'closing a pending TCP check cancels it and destroys a late socket',
    () async {
      binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        expect(call.method, 'getDirectProbeNetwork');
        return 'physical';
      });
      addTearDown(
        () => binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      final probe = DirectLatencyProbe();
      addTearDown(probe.close);
      final dial = Completer<void>();
      final connection = Completer<Socket>();
      var cancellations = 0;
      final checking = IOOverrides.runZoned(
        () => probe.check(
          profile('literal', host: '2606:4700::1111'),
          networkKey: 'physical',
          stillAllowed: () => true,
        ),
        socketStartConnect:
            (host, port, {sourceAddress, sourcePort = 0}) async {
              dial.complete();
              return ConnectionTask.fromSocket(
                connection.future,
                () => cancellations++,
              );
            },
      );
      await dial.future;
      await Future<void>.delayed(Duration.zero);
      probe.close();
      final socket = _ProbeSocket();
      connection.complete(socket);
      expect(await checking, isNull);
      expect(cancellations, 1);
      expect(socket.destroys, 1);
    },
  );

  group('direct probe lifecycle', () {
    const wifi = 'fixture-wifi';
    const cellular = 'fixture-cellular';
    const literal = '2606:4700::1111';
    const gate = 'getDirectProbeNetwork';
    const resolve = 'resolveDirectProbeHost';
    const cancelDns = 'cancelDirectProbeDns';
    late DirectLatencyProbe probe;
    late List<MethodCall> calls;
    late List<(Object?, int)> dials;
    late FutureOr<Object?> Function(MethodCall) reply;
    Future<ConnectionTask<Socket>> Function()? connect;

    setUp(() {
      probe = DirectLatencyProbe();
      calls = [];
      dials = [];
      connect = null;
      reply = (call) => call.method == gate
          ? wifi
          : fail('Unexpected platform call: ${call.method}');
      binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        calls.add(call);
        return reply(call);
      });
      addTearDown(probe.close);
      addTearDown(
        () => binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
    });

    Iterable<String> methods() => calls.map((call) => call.method);

    List<Object?> check({
      String host = literal,
      VpnProfileKind? kind,
      String network = wifi,
      bool Function()? stillAllowed,
    }) => _observe(
      IOOverrides.runZoned(
        () => probe.check(
          profile('fixture', host: host, kind: kind),
          networkKey: network,
          stillAllowed: stillAllowed ?? () => true,
        ),
        socketStartConnect:
            (host, port, {sourceAddress, sourcePort = 0}) async {
              dials.add((host, port));
              return connect?.call() ??
                  fail('A socket was not expected for this check');
            },
      ),
    );

    test('gate timeout rejects both callers and does not cache a late key', () {
      fakeAsync((clock) {
        final oldGate = Completer<String>();
        reply = (_) => oldGate.future;
        final first = check();
        final second = check();
        clock.elapse(const Duration(milliseconds: 1999));
        expect(methods(), [gate]);
        expect(first, isEmpty);
        expect(second, isEmpty);

        clock.elapse(const Duration(milliseconds: 1));
        expect(first, [null]);
        expect(second, [null]);
        expect(dials, isEmpty);

        final newGate = Completer<String>();
        reply = (_) => newGate.future;
        final next = _observe(probe.network());
        oldGate.complete(wifi);
        clock.flushMicrotasks();
        expect(next, isEmpty);
        expect(methods(), [gate, gate]);

        newGate.complete(cellular);
        clock.flushMicrotasks();
        expect(next, [cellular]);
        expect(dials, isEmpty);
      });
    });

    test('DNS timeout cancels its exact request and ignores a late answer', () {
      fakeAsync((clock) {
        final dns = Completer<List<String>>();
        reply = (call) => switch (call.method) {
          gate => wifi,
          resolve => dns.future,
          cancelDns => null,
          _ => fail('Unexpected platform call: ${call.method}'),
        };
        final result = check(host: 'vpn.example.org');
        clock.elapse(const Duration(milliseconds: 1499));
        expect(methods(), [gate, resolve]);
        expect(result, isEmpty);
        final request = calls.last.arguments['request'] as int;
        expect(calls.last.arguments, {
          'request': request,
          'host': 'vpn.example.org',
          'network': wifi,
        });

        clock.elapse(const Duration(milliseconds: 1));
        expect(result, [null]);
        expect(methods(), [gate, resolve, cancelDns]);
        expect(calls.last.arguments, {'request': request});

        dns.complete([literal]);
        clock.flushMicrotasks();
        expect(result, [null]);
        expect(methods(), [gate, resolve, cancelDns]);
        expect(dials, isEmpty);
        probe.close();
        expect(methods(), [gate, resolve, cancelDns]);
      });
    });

    test('TCP timeout cancels once and destroys a late socket', () {
      fakeAsync((clock) {
        final pending = Completer<Socket>();
        final socket = _ProbeSocket();
        var cancellations = 0;
        connect = () async =>
            ConnectionTask.fromSocket(pending.future, () => cancellations++);
        final result = check();
        clock.elapse(const Duration(milliseconds: 1449));
        expect(methods(), [gate, gate]);
        expect(dials, [(InternetAddress(literal), 443)]);
        expect(result, isEmpty);
        expect(cancellations, 0);

        clock.elapse(const Duration(milliseconds: 1));
        expect(result, [null]);
        expect(cancellations, 1);

        pending.complete(socket);
        clock.flushMicrotasks();
        probe.close();
        expect(socket.destroys, 1);
        expect(cancellations, 1);
      });
    });

    test('closing before the TCP task arrives cancels it on arrival', () {
      fakeAsync((clock) {
        final pending = Completer<ConnectionTask<Socket>>();
        var cancellations = 0;
        connect = () => pending.future;
        final result = check();
        clock.flushMicrotasks();
        expect(dials, [(InternetAddress(literal), 443)]);
        expect(result, isEmpty);

        probe.close();
        pending.complete(
          ConnectionTask.fromSocket(
            Completer<Socket>().future,
            () => cancellations++,
          ),
        );
        clock.flushMicrotasks();
        probe.close();
        expect(result, [null]);
        expect(cancellations, 1);
        expect(clock.nonPeriodicTimerCount, 0);
      });
    });

    test(
      'a change after DNS rejects Wi-Fi and allows a fresh cellular check',
      () {
        fakeAsync((clock) {
          var network = wifi;
          final dns = Completer<List<String>>();
          reply = (call) => switch (call.method) {
            gate => network,
            resolve => dns.future,
            _ => fail('Unexpected platform call: ${call.method}'),
          };
          final old = check(host: 'vpn.example.org');
          clock.flushMicrotasks();
          expect(methods(), [gate, resolve]);
          expect(calls.last.arguments['network'], wifi);

          network = cellular;
          dns.complete([literal]);
          clock.flushMicrotasks();
          expect(old, [null]);
          expect(methods(), [gate, resolve, gate]);
          expect(dials, isEmpty);

          final socket = _ProbeSocket();
          connect = () async =>
              ConnectionTask.fromSocket(Future<Socket>.value(socket), () {});
          final fresh = check(network: cellular);
          clock.flushMicrotasks();
          expect(fresh, [isA<DirectLatencyReading>()]);
          expect(methods(), [gate, resolve, gate, gate, gate]);
          expect(dials, [(InternetAddress(literal), 443)]);
          expect(socket.destroys, 1);
        });
      },
    );

    test('revoked permission while rechecking the gate prevents TCP', () {
      fakeAsync((clock) {
        final secondGate = Completer<String>();
        reply = (_) => calls.length == 1 ? wifi : secondGate.future;
        var allowed = true;
        final result = check(stillAllowed: () => allowed);
        clock.flushMicrotasks();
        expect(methods(), [gate, gate]);
        expect(result, isEmpty);

        allowed = false;
        secondGate.complete(wifi);
        clock.flushMicrotasks();
        expect(result, [null]);
        expect(dials, isEmpty);
      });
    });

    test(
      'UDP does not fall back to a TCP probe on desktop',
      () {
        fakeAsync((clock) {
          final result = check(kind: VpnProfileKind.hysteria2);
          clock.flushMicrotasks();
          expect(result, [null]);
          expect(methods(), [gate, gate]);
          expect(dials, isEmpty);
        });
      },
      skip: Platform.isAndroid ? 'Checks only the non-Android guard' : false,
    );
  });

  test(
    'auto ranks actual measurements, includes Hysteria and excludes unsafe choices',
    () {
      final now = DateTime.utc(2026, 11, 12);
      final udp = profile('udp', kind: VpnProfileKind.hysteria2);
      final tcp = profile('tcp');
      final failed = profile('failed');
      final ranked = const ProfileAutoSelector().rankForLatency(
        [
          tcp,
          udp,
          failed,
          profile('offline'),
          profile('expired', expiry: now.subtract(const Duration(days: 1))),
        ],
        directLatencyMs: {
          'tcp': 80,
          'udp': 25,
          'offline': 1,
          'expired': 1,
          'failed': 2,
        },
        offlineProfileIds: {'offline'},
        stabilityStats: {
          'failed': ProfileStabilityStats(failedStarts: 1, lastFailureAt: now),
        },
        now: now,
      );
      expect(ranked.map((item) => item.id), ['udp', 'tcp']);
    },
  );

  test('auto falls back to actual success on the current network', () {
    final ranked = const ProfileAutoSelector().rankForLatency(
      [profile('old'), profile('wifi'), profile('unmeasured')],
      lastProfileId: 'old',
      stabilityStats: {'old': const ProfileStabilityStats(successfulStarts: 4)},
      networkStats: {
        'wifi': const ProfileNetworkStabilityStats(successfulStarts: 1),
      },
      directLatencyMs: {'unmeasured': 0},
    );
    expect(ranked.map((item) => item.id), ['wifi', 'old', 'unmeasured']);
  });
}

List<Object?> _observe(Future<Object?> future) {
  final result = <Object?>[];
  unawaited(
    future.then<void>(
      result.add,
      onError: (Object error, StackTrace _) => result.add(error),
    ),
  );
  return result;
}

class _ProbeSocket implements Socket {
  int destroys = 0;

  @override
  void destroy() => destroys++;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
