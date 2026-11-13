import 'dart:async';
import 'dart:io';

import 'package:aurum_vpn/src/models/vpn_profile.dart';
import 'package:aurum_vpn/src/services/proxy_server_probe.dart';
import 'package:flutter_test/flutter_test.dart';

VpnProfile _profile({
  VpnProfileKind kind = VpnProfileKind.vlessReality,
  String server = 'upstream.example',
  int port = 443,
  Map<String, dynamic>? outbound,
}) => VpnProfile(
  id: 'fixture',
  name: 'fixture',
  kind: kind,
  originalInput: '',
  server: server,
  port: port,
  outbound: outbound,
);

void main() {
  test('target preserves destination separately from SNI without lookup', () {
    final target = ServerProbeTarget.fromProfile(
      _profile(
        outbound: {
          'tls': {'server_name': 'sni.example'},
        },
      ),
    )!;
    expect(target.authority, 'upstream.example:443');
    expect(target.tlsName, 'sni.example');
    expect(target.toString(), isNot(contains('upstream')));
    expect(
      ServerProbeTarget.fromProfile(_profile(server: '2001:db8::1'))!.authority,
      '[2001:db8::1]:443',
    );
  });

  test('UDP is not declared offline by a TCP diagnostic', () {
    expect(
      ServerProbeTarget.fromProfile(_profile(kind: VpnProfileKind.hysteria2)),
      isNull,
    );
    expect(
      const ServerProbeResult(
        ServerProbeState.needsConnection,
      ).label(russian: true),
      isNot(contains('offline')),
    );
  });

  test('rejects CONNECT header injection, userinfo, invalid port and URI', () {
    for (final host in [
      'safe.example\r\nX-Secret: value',
      'a@b.example',
      'https://a.example',
      'a:443',
    ]) {
      expect(ServerProbeTarget.fromProfile(_profile(server: host)), isNull);
    }
    expect(ServerProbeTarget.fromProfile(_profile(port: 65536)), isNull);
  });

  test('uncertain outcomes never claim protocol offline or direct ping', () {
    for (final state in ServerProbeState.values.where(
      (s) => s != ServerProbeState.offlineMarked,
    )) {
      expect(
        ServerProbeResult(state, 30).label(russian: true),
        isNot(contains('offline')),
      );
    }
    expect(
      const ServerProbeResult(
        ServerProbeState.tlsReachable,
        30,
      ).label(russian: true),
      'TLS 30 мс · VPN',
    );
  });

  Future<({ServerSocket server, List<Socket> peers})> proxy(
    void Function(Socket socket) handler,
  ) async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final peers = <Socket>[];
    server.listen((socket) {
      peers.add(socket);
      handler(socket);
    });
    addTearDown(() async {
      for (final peer in peers) {
        peer.destroy();
      }
      await server.close();
    });
    return (server: server, peers: peers);
  }

  test('CONNECT 200 is not a positive result before TLS completes', () async {
    final received = Completer<String>();
    final p = await proxy((socket) {
      socket.listen((data) {
        if (!received.isCompleted) {
          received.complete(String.fromCharCodes(data));
        }
        socket.write('HTTP/1.1 200 Connection established\r\n\r\n');
      });
    });
    final upgrade = Completer<Socket>();
    final entered = Completer<String>();
    final probe = ProxyServerProbe(
      proxyPort: p.server.port,
      tlsUpgrade: (socket, name) {
        entered.complete(name);
        return upgrade.future;
      },
    );
    addTearDown(probe.close);
    var finished = false;
    final result = probe
        .check(const ServerProbeTarget('private.example', 443, 'tls.example'))
        .then((value) {
          finished = true;
          return value;
        });
    expect(await entered.future, 'tls.example');
    expect(
      await received.future,
      startsWith('CONNECT private.example:443 HTTP/1.1\r\n'),
    );
    expect(finished, isFalse);
    upgrade.completeError(const HandshakeException('private-endpoint marker'));
    expect((await result).state, ServerProbeState.certificateUnverified);
  });

  test('positive TLS result uses only a loopback proxy connection', () async {
    final p = await proxy((socket) {
      socket.listen((_) => socket.write('HTTP/1.1 200 OK\r\n\r\n'));
    });
    var upgraded = false;
    final probe = ProxyServerProbe(
      proxyPort: p.server.port,
      tlsUpgrade: (socket, name) async {
        expect(socket.remoteAddress, InternetAddress.loopbackIPv4);
        expect(name, 'tls.example');
        upgraded = true;
        return socket;
      },
    );
    addTearDown(probe.close);
    final result = await probe.check(
      const ServerProbeTarget('no-local-dns.invalid', 443, 'tls.example'),
    );
    expect(upgraded, isTrue);
    expect(result.state, ServerProbeState.tlsReachable);
    expect(result.milliseconds, isNonNegative);
  });

  test(
    'rejects proxy failure and oversized headers without upgrading',
    () async {
      for (final header in ['HTTP/1.1 502 Bad Gateway\r\n\r\n', 'x' * 8193]) {
        final p = await proxy((socket) {
          socket.listen((_) => socket.write(header));
        });
        var upgraded = false;
        final probe = ProxyServerProbe(
          proxyPort: p.server.port,
          tlsUpgrade: (socket, _) async {
            upgraded = true;
            return socket;
          },
        );
        addTearDown(probe.close);
        expect(
          (await probe.check(
            const ServerProbeTarget(
              'endpoint.invalid',
              443,
              'endpoint.invalid',
            ),
          )).state,
          ServerProbeState.noResponse,
        );
        expect(upgraded, isFalse);
      }
    },
  );

  test(
    'close cancels an in-flight stalled CONNECT without direct fallback',
    () async {
      final accepted = Completer<void>();
      final p = await proxy((socket) {
        socket.listen((_) {
          if (!accepted.isCompleted) accepted.complete();
        });
      });
      final probe = ProxyServerProbe(proxyPort: p.server.port);
      final check = probe.check(
        const ServerProbeTarget(
          'never-resolve.invalid',
          443,
          'never-resolve.invalid',
        ),
      );
      await accepted.future;
      probe.close();
      expect(
        (await check.timeout(const Duration(seconds: 1))).state,
        ServerProbeState.cancelled,
      );
      expect(
        (await probe.check(
          const ServerProbeTarget('x.example', 443, 'x.example'),
        )).state,
        ServerProbeState.cancelled,
      );
    },
  );

  test('total deadline bounds an unresponsive proxy', () async {
    final p = await proxy((socket) {
      socket.listen((_) {});
    });
    final probe = ProxyServerProbe(
      proxyPort: p.server.port,
      timeout: const Duration(milliseconds: 40),
    );
    addTearDown(probe.close);
    expect(
      (await probe.check(
        const ServerProbeTarget(
          'never-resolve.invalid',
          443,
          'never-resolve.invalid',
        ),
      )).state,
      ServerProbeState.noResponse,
    );
  });

  test('real TLS verification rejects a plaintext CONNECT peer', () async {
    final p = await proxy((socket) {
      var first = true;
      socket.listen((_) {
        socket.write(first ? 'HTTP/1.1 200 OK\r\n\r\n' : 'not a TLS server');
        first = false;
      });
    });
    final probe = ProxyServerProbe(
      proxyPort: p.server.port,
      timeout: const Duration(seconds: 1),
    );
    addTearDown(probe.close);
    expect(
      (await probe.check(
        const ServerProbeTarget(
          'never-resolve.invalid',
          443,
          'never-resolve.invalid',
        ),
      )).state,
      isNot(ServerProbeState.tlsReachable),
    );
  });
}
