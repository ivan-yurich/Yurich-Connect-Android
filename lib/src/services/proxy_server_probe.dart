import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models/vpn_profile.dart';

enum ServerProbeState {
  tlsReachable,
  tunnelHealthy,
  noResponse,
  certificateUnverified,
  needsVpn,
  needsConnection,
  unsupported,
  offlineMarked,
  cancelled,
}

final class ServerProbeResult {
  const ServerProbeResult(this.state, [this.milliseconds]);

  final ServerProbeState state;
  final int? milliseconds;

  String label({required bool russian}) => switch (state) {
    ServerProbeState.tlsReachable =>
      russian ? 'TLS $milliseconds мс · VPN' : 'TLS $milliseconds ms · VPN',
    ServerProbeState.tunnelHealthy =>
      russian ? 'HTTPS $milliseconds мс · VPN' : 'HTTPS $milliseconds ms · VPN',
    ServerProbeState.needsVpn => russian ? 'Нужен VPN' : 'VPN required',
    ServerProbeState.needsConnection =>
      russian ? 'UDP: подключитесь' : 'UDP: connect to test',
    ServerProbeState.certificateUnverified =>
      russian ? 'TLS не подтверждён' : 'TLS unverified',
    ServerProbeState.unsupported => russian ? 'Нет TLS-пробы' : 'No TLS probe',
    ServerProbeState.offlineMarked => 'offline',
    ServerProbeState.cancelled => russian ? 'Не проверено' : 'Not checked',
    ServerProbeState.noResponse =>
      russian ? 'Нет ответа · VPN' : 'No response · VPN',
  };
}

/// Only a validated TLS handshake is positive evidence. CONNECT 200 alone is not.
/// This measures a TLS frontend through the current tunnel, not protocol auth,
/// ICMP RTT, direct reachability, or the performance of an inactive VPN profile.
final class ServerProbeTarget {
  const ServerProbeTarget(this.host, this.port, this.tlsName);

  final String host;
  final int port;
  final String tlsName;

  static bool usesUdp(VpnProfile profile) =>
      profile.kind == VpnProfileKind.hysteria ||
      profile.kind == VpnProfileKind.hysteria2 ||
      const {
        'hysteria',
        'hysteria2',
        'hy2',
      }.contains(profile.outbound?['type']?.toString().toLowerCase());

  static ServerProbeTarget? fromProfile(VpnProfile profile) {
    if (usesUdp(profile) || !profile.kind.isClientSupported) return null;
    final host = profile.server?.trim() ?? '';
    final port = profile.port ?? 443;
    final tls = profile.outbound?['tls'];
    final name = tls is Map ? tls['server_name']?.toString().trim() : null;
    final tlsName = name == null || name.isEmpty ? host : name;
    if (!_validHost(host) || !_validHost(tlsName) || port < 1 || port > 65535) {
      return null;
    }
    return ServerProbeTarget(host, port, tlsName);
  }

  static bool _validHost(String value) {
    if (value.isEmpty || value.length > 253) return false;
    if (InternetAddress.tryParse(value) != null) return true;
    // No CRLF, userinfo, ports, paths or arbitrary CONNECT headers.
    return RegExp(
      r'^[a-zA-Z0-9](?:[a-zA-Z0-9.-]*[a-zA-Z0-9])?$',
    ).hasMatch(value);
  }

  String get authority => '${host.contains(':') ? '[$host]' : host}:$port';

  @override
  String toString() => 'ServerProbeTarget(redacted)';
}

typedef ProbeTlsUpgrade =
    Future<Socket> Function(Socket socket, String tlsName);

final class ProxyServerProbe {
  ProxyServerProbe({
    required int proxyPort,
    this.timeout = const Duration(seconds: 8),
    ProbeTlsUpgrade? tlsUpgrade,
  }) : _proxyPort = RangeError.checkValueInInterval(proxyPort, 1, 65535),
       _tlsUpgrade = tlsUpgrade ?? _validatedTls;

  final int _proxyPort;
  final Duration timeout;
  final ProbeTlsUpgrade _tlsUpgrade;
  final _cancel = Completer<void>();
  final _active = <void Function()>{};

  static Future<Socket> _validatedTls(Socket socket, String name) =>
      SecureSocket.secure(
        socket,
        host: name,
        supportedProtocols: const ['h2', 'http/1.1'],
      );

  void close() {
    if (_cancel.isCompleted) return;
    _cancel.complete();
    for (final cancel in _active.toList(growable: false)) {
      cancel();
    }
  }

  Future<ServerProbeResult> check(ServerProbeTarget target) async {
    if (_cancel.isCompleted) {
      return const ServerProbeResult(ServerProbeState.cancelled);
    }
    // Validate even callers that construct a target directly.
    if (!ServerProbeTarget._validHost(target.host) ||
        !ServerProbeTarget._validHost(target.tlsName) ||
        target.port < 1 ||
        target.port > 65535) {
      return const ServerProbeResult(ServerProbeState.unsupported);
    }
    final watch = Stopwatch()..start();
    Socket? socket;
    ConnectionTask<Socket>? connection;
    StreamSubscription<List<int>>? subscription;
    var settled = false;

    void cancelSocket() {
      connection?.cancel();
      socket?.destroy();
    }

    _active.add(cancelSocket);
    Future<ServerProbeResult> run() async {
      try {
        // Numeric loopback is the only socket destination. DNS and the remote
        // TCP connection belong to the current proxy, never the VPN-owner UID.
        final task = await Socket.startConnect(
          InternetAddress.loopbackIPv4,
          _proxyPort,
        );
        connection = task;
        if (settled) {
          task.cancel();
          return const ServerProbeResult(ServerProbeState.cancelled);
        }
        final connected = await task.socket;
        socket = connected;
        if (settled) {
          connected.destroy();
          return const ServerProbeResult(ServerProbeState.cancelled);
        }
        final header = Completer<void>();
        // Cancellation may close the peer while flush() is still pending.
        // Keep an error listener installed before awaiting any socket work.
        header.future.ignore();
        final bytes = <int>[];
        subscription = connected.listen(
          (chunk) {
            if (header.isCompleted) return;
            if (bytes.length + chunk.length > 8192) {
              header.completeError(const FormatException('Proxy header limit'));
              return;
            }
            bytes.addAll(chunk);
            final text = latin1.decode(bytes);
            final end = text.indexOf('\r\n\r\n');
            if (end < 0) return;
            subscription?.pause();
            final firstLine = text.split('\r\n').first;
            if (end + 4 != bytes.length ||
                !RegExp(r'^HTTP/1\.[01] 200(?: |$)').hasMatch(firstLine)) {
              header.completeError(
                const FormatException('Proxy CONNECT failed'),
              );
            } else {
              header.complete();
            }
          },
          onError: (Object error) {
            if (!header.isCompleted) header.completeError(error);
          },
          onDone: () {
            if (!header.isCompleted) {
              header.completeError(const SocketException('Proxy closed'));
            }
          },
          cancelOnError: true,
        );
        connected.write(
          'CONNECT ${target.authority} HTTP/1.1\r\n'
          'Host: ${target.authority}\r\n\r\n',
        );
        await connected.flush();
        await header.future;
        if (settled) return const ServerProbeResult(ServerProbeState.cancelled);
        final tls = await _tlsUpgrade(connected, target.tlsName);
        socket = tls;
        if (settled) {
          tls.destroy();
          return const ServerProbeResult(ServerProbeState.cancelled);
        }
        return ServerProbeResult(
          ServerProbeState.tlsReachable,
          watch.elapsedMilliseconds,
        );
      } on HandshakeException {
        return const ServerProbeResult(ServerProbeState.certificateUnverified);
      } on Object {
        // Do not persist exception text: it can contain the endpoint/SNI.
        return const ServerProbeResult(ServerProbeState.noResponse);
      }
    }

    try {
      return await Future.any([
        run(),
        _cancel.future.then(
          (_) => const ServerProbeResult(ServerProbeState.cancelled),
        ),
      ]).timeout(
        timeout,
        onTimeout: () => const ServerProbeResult(ServerProbeState.noResponse),
      );
    } finally {
      settled = true;
      _active.remove(cancelSocket);
      cancelSocket();
      await subscription?.cancel();
    }
  }
}
