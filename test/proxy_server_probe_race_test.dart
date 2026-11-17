import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:aurum_vpn/src/services/proxy_server_probe.dart';
// Use the fake clock supplied by flutter_test.
// ignore: depend_on_referenced_packages
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

const _port = 20808;
const _target = ServerProbeTarget('upstream.invalid', 443, 'sni.invalid');
const _deadline = Duration(milliseconds: 50);

void main() {
  test(
    'close cancels a connection task that arrives after the probe settles',
    () {
      fakeAsync((clock) {
        final pending = Completer<ConnectionTask<Socket>>();
        final dial = _LoopbackDial(pending.future);
        final probe = ProxyServerProbe(
          proxyPort: _port,
          tlsUpgrade: _unexpectedTls,
        );
        final results = _observe(dial.check(probe));
        clock.flushMicrotasks();
        expect(results, isEmpty);

        probe.close();
        clock.flushMicrotasks();
        expect(results.single.state, ServerProbeState.cancelled);

        var cancellations = 0;
        pending.complete(
          ConnectionTask.fromSocket(
            Completer<Socket>().future,
            () => cancellations++,
          ),
        );
        clock.flushMicrotasks();
        expect(cancellations, 1);
        expect(results.single.state, ServerProbeState.cancelled);
        dial.expectOnlyLoopback();
      });
    },
  );

  test(
    'timeout cancels the task and closes a later TCP socket without CONNECT',
    () {
      fakeAsync((clock) {
        final late = Completer<Socket>();
        final connected = _ProbeSocket();
        var cancellations = 0;
        final dial = _LoopbackDial(
          Future.value(
            ConnectionTask.fromSocket(late.future, () => cancellations++),
          ),
        );
        final probe = ProxyServerProbe(
          proxyPort: _port,
          timeout: _deadline,
          tlsUpgrade: _unexpectedTls,
        );
        final results = _observe(dial.check(probe));
        clock.elapse(_deadline - const Duration(milliseconds: 1));
        expect(results, isEmpty);
        expect(cancellations, 0);

        clock.elapse(const Duration(milliseconds: 1));
        expect(results.single.state, ServerProbeState.noResponse);
        expect(cancellations, 1);

        late.complete(connected);
        clock.flushMicrotasks();
        expect(connected.destroys, 1);
        expect(connected.listens, 0);
        expect(connected.writes, isEmpty);
        expect(results.single.state, ServerProbeState.noResponse);
        dial.expectOnlyLoopback();
        probe.close();
      });
    },
  );

  test(
    'a stream error before CONNECT flush finishes is handled without TLS',
    () {
      fakeAsync((clock) {
        final flush = Completer<void>();
        final socket = _ProbeSocket(flushGate: flush.future);
        final dial = _LoopbackDial.connected(socket);
        var upgrades = 0;
        final probe = ProxyServerProbe(
          proxyPort: _port,
          tlsUpgrade: (socket, name) async {
            upgrades++;
            return socket;
          },
        );
        final results = _observe(dial.check(probe));
        clock.flushMicrotasks();
        expect(socket.listens, 1);
        expect(socket.writes, [
          'CONNECT upstream.invalid:443 HTTP/1.1\r\n'
              'Host: upstream.invalid:443\r\n\r\n',
        ]);

        socket.readError(const SocketException('synthetic fixture'));
        clock.flushMicrotasks();
        expect(results, isEmpty);
        flush.complete();
        clock.flushMicrotasks();

        expect(results.single.state, ServerProbeState.noResponse);
        expect(results.single.milliseconds, isNull);
        expect(upgrades, 0);
        expect(socket.destroys, 1);
        expect(socket.streamCancellations, 1);
        dial.expectOnlyLoopback();
        probe.close();
      });
    },
  );

  for (final cancel in [true, false]) {
    test('closes TLS completing after the probe settles (cancel: $cancel)', () {
      fakeAsync((clock) {
        final tcp = _ProbeSocket();
        final tls = _ProbeSocket();
        final handshake = Completer<Socket>();
        final names = <String>[];
        final dial = _LoopbackDial.connected(tcp);
        final probe = ProxyServerProbe(
          proxyPort: _port,
          timeout: _deadline,
          tlsUpgrade: (socket, name) {
            expect(socket, same(tcp));
            names.add(name);
            return handshake.future;
          },
        );
        final results = _observe(dial.check(probe));
        clock.flushMicrotasks();
        tcp.read('HTTP/1.1 200 OK\r\n\r\n');
        clock.flushMicrotasks();
        expect(names, ['sni.invalid']);
        expect(results, isEmpty);

        if (cancel) {
          probe.close();
        } else {
          clock.elapse(_deadline);
        }
        clock.flushMicrotasks();
        final expected = cancel
            ? ServerProbeState.cancelled
            : ServerProbeState.noResponse;
        expect(results.single.state, expected);
        expect(tcp.destroys, greaterThanOrEqualTo(1));
        expect(tcp.streamCancellations, 1);
        expect(tls.destroys, 0);

        handshake.complete(tls);
        clock.flushMicrotasks();
        expect(tls.destroys, 1);
        expect(results.single.state, expected);
        expect(results.single.milliseconds, isNull);
        dial.expectOnlyLoopback();
        probe.close();
      });
    });
  }
}

Future<Socket> _unexpectedTls(Socket socket, String name) async =>
    fail('TLS must not be attempted');

List<ServerProbeResult> _observe(Future<ServerProbeResult> check) {
  final results = <ServerProbeResult>[];
  unawaited(check.then<void>(results.add));
  return results;
}

class _LoopbackDial {
  _LoopbackDial(this.response);
  _LoopbackDial.connected(Socket socket)
    : this(
        Future.value(ConnectionTask.fromSocket(Future.value(socket), () {})),
      );

  final Future<ConnectionTask<Socket>> response;
  final calls = <(Object?, int)>[];

  Future<ServerProbeResult> check(ProxyServerProbe probe) =>
      IOOverrides.runZoned(
        () => probe.check(_target),
        socketStartConnect: (host, port, {sourceAddress, sourcePort = 0}) {
          calls.add((host, port));
          return response;
        },
        socketConnect:
            (host, port, {sourceAddress, sourcePort = 0, timeout}) async {
              calls.add((host, port));
              fail('Unexpected socket connection');
            },
      );

  void expectOnlyLoopback() {
    expect(calls, [(InternetAddress.loopbackIPv4, _port)]);
  }
}

class _ProbeSocket extends Fake implements Socket {
  _ProbeSocket({this.flushGate}) {
    _input.onCancel = () {
      streamCancellations++;
      // Complete cleanup inside the test zone under the fake clock.
      return Future<void>.value();
    };
  }

  final Future<void>? flushGate;
  final _input = StreamController<Uint8List>();
  final writes = <Object?>[];
  int destroys = 0;
  int listens = 0;
  int streamCancellations = 0;

  void read(String text) => _input.add(Uint8List.fromList(ascii.encode(text)));
  void readError(Object error) => _input.addError(error);

  @override
  void write(Object? object) => writes.add(object);

  @override
  Future<void> flush() => flushGate ?? Future<void>.value();

  @override
  void destroy() => destroys++;

  @override
  StreamSubscription<Uint8List> listen(
    void Function(Uint8List)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    listens++;
    return _input.stream.listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }
}
