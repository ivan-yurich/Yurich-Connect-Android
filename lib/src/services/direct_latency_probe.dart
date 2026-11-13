import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import '../models/vpn_profile.dart';
import 'proxy_server_probe.dart';

enum DirectLatencyKind { tcp, icmp }

final class DirectLatencyReading {
  const DirectLatencyReading(this.kind, this.milliseconds);

  final DirectLatencyKind kind;
  final int milliseconds;
}

/// Does not bind to a physical network or protect sockets from a VPN.
/// A caller must obtain a fresh Android gate and close this batch on any
/// session/protection/network change, including when leaving the foreground.
final class DirectLatencyProbe {
  static const _channel = MethodChannel('com.tecclub.flutter_singbox/methods');
  static const _dnsTimeout = Duration(milliseconds: 1500);
  static const _probeTimeout = Duration(milliseconds: 1450);
  static final _host = RegExp(
    r'^(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z](?:[a-z0-9-]{0,61}[a-z0-9])?$',
    caseSensitive: false,
  );
  static final _icmpTime = RegExp(r'\btime[=<]\s*(\d+(?:\.\d+)?)\s*ms\b');
  static const _localSuffixes = {
    'local',
    'localhost',
    'lan',
    'home',
    'internal',
    'test',
    'invalid',
    'onion',
  };
  static int _nextDnsRequest = 0;

  final _abort = <void Function()>{};
  Future<String?>? _pendingGate;
  bool _closed = false;

  Future<String?> network() {
    if (_closed) return Future.value();
    return _pendingGate ??= _readNetwork().whenComplete(() {
      _pendingGate = null;
    });
  }

  Future<String?> _readNetwork() async {
    try {
      return await _channel
          .invokeMethod<String>('getDirectProbeNetwork')
          .timeout(const Duration(seconds: 2));
    } on Object {
      return null;
    }
  }

  void close() {
    _closed = true;
    for (final cancel in _abort.toList(growable: false)) {
      cancel();
    }
    _abort.clear();
  }

  static bool eligible(VpnProfile profile) {
    final host = profile.server?.trim().toLowerCase();
    if (!profile.kind.isClientSupported ||
        profile.rawConfig != null ||
        host == null ||
        host.isEmpty ||
        host.length > 253 ||
        host.contains('%') ||
        (profile.port ?? 443) < 1 ||
        (profile.port ?? 443) > 65535) {
      return false;
    }
    final literal = InternetAddress.tryParse(host);
    return literal != null
        ? isPublicAddress(literal)
        : _host.hasMatch(host) &&
              !_localSuffixes.contains(host.split('.').last);
  }

  static bool isPublicAddress(InternetAddress address) {
    final bytes = address.rawAddress;
    if (address.type == InternetAddressType.IPv4) {
      final a = bytes[0], b = bytes[1], c = bytes[2];
      return a != 0 &&
          a != 10 &&
          a != 127 &&
          a < 224 &&
          !(a == 100 && b >= 64 && b <= 127) &&
          !(a == 169 && b == 254) &&
          !(a == 172 && b >= 16 && b <= 31) &&
          !(a == 192 && (b == 168 || b == 0 && (c == 0 || c == 2))) &&
          !(a == 198 && (b == 18 || b == 19 || b == 51 && c == 100)) &&
          !(a == 203 && b == 0 && c == 113);
    }
    // Public global unicast only. Refuse mapped, local, and transition forms.
    return (bytes[0] & 0xe0) == 0x20 &&
        !(bytes[0] == 0x20 && bytes[1] == 0x02) &&
        !(bytes[0] == 0x20 &&
            bytes[1] == 0x01 &&
            ((bytes[2] == 0x0d && bytes[3] == 0xb8) ||
                (bytes[2] == 0 && bytes[3] == 0)));
  }

  Future<DirectLatencyReading?> check(
    VpnProfile profile, {
    required String networkKey,
    required bool Function() stillAllowed,
  }) async {
    bool permitted() => !_closed && stillAllowed();
    if (!permitted() ||
        !eligible(profile) ||
        await network() != networkKey ||
        !permitted()) {
      return null;
    }
    try {
      final host = profile.server!.trim();
      final literal = InternetAddress.tryParse(host);
      final addresses = literal == null
          ? await _resolveHost(host, networkKey)
          : [literal];
      // No name is passed to connect/ping: validate the resolved address too.
      final public = addresses.where(isPublicAddress).firstOrNull;
      if (public == null ||
          !permitted() ||
          await network() != networkKey ||
          !permitted()) {
        return null;
      }
      final measurement = ServerProbeTarget.usesUdp(profile)
          ? await _icmp(public)
          : await _tcp(public, profile.port ?? 443);
      return permitted() ? measurement : null;
    } on Object {
      // No addresses, process output or DNS/socket errors go into UI logs.
      return null;
    }
  }

  Future<List<InternetAddress>> _resolveHost(
    String host,
    String network,
  ) async {
    if (_closed) return const [];
    final request = ++_nextDnsRequest;
    var done = false;
    void cancel() {
      if (done) return;
      done = true;
      unawaited(_cancelDns(request));
    }

    _abort.add(cancel);
    try {
      final resolved = await _channel
          .invokeListMethod<String>('resolveDirectProbeHost', {
            'request': request,
            'host': host,
            'network': network,
          })
          .timeout(_dnsTimeout);
      if (done || _closed) return const [];
      done = true;
      return [
        for (final value in resolved ?? const <String>[])
          if (!value.contains('%')) ?InternetAddress.tryParse(value),
      ];
    } finally {
      _abort.remove(cancel);
      cancel();
    }
  }

  Future<void> _cancelDns(int request) async {
    try {
      await _channel.invokeMethod<void>('cancelDirectProbeDns', {
        'request': request,
      });
    } on Object {
      // The Android request also has a short independent timeout.
    }
  }

  Future<DirectLatencyReading?> _tcp(InternetAddress address, int port) async {
    final watch = Stopwatch()..start();
    final task = await Socket.startConnect(address, port);
    Socket? socket;
    var cancelled = false;
    void cancel() {
      if (cancelled) return;
      cancelled = true;
      socket?.destroy();
      task.cancel();
    }

    _abort.add(cancel);
    try {
      if (_closed) {
        cancel();
        return null;
      }
      socket = await task.socket
          .then((connected) {
            if (cancelled || _closed) connected.destroy();
            return connected;
          })
          .timeout(_probeTimeout);
      return cancelled || _closed
          ? null
          : DirectLatencyReading(
              DirectLatencyKind.tcp,
              (watch.elapsedMicroseconds / 1000).ceil().clamp(1, 5000).toInt(),
            );
    } finally {
      _abort.remove(cancel);
      cancel();
    }
  }

  Future<DirectLatencyReading?> _icmp(InternetAddress address) async {
    if (!Platform.isAndroid || _closed) return null;
    final executable = address.type == InternetAddressType.IPv4
        ? '/system/bin/ping'
        : '/system/bin/ping6';
    final process = await Process.start(executable, [
      '-n',
      '-c',
      '1',
      '-W',
      '1',
      address.address,
    ]);
    void cancel() => process.kill();
    _abort.add(cancel);
    final errors = process.stderr.drain<void>();
    try {
      if (_closed) return null;
      final output = process.stdout.transform(utf8.decoder).join();
      final result = await Future.wait<Object>([
        output,
        process.exitCode,
        errors.then((_) => true),
      ]).timeout(_probeTimeout);
      if (_closed || result[1] != 0) return null;
      final match = _icmpTime.firstMatch(result[0] as String);
      final ms = double.tryParse(match?.group(1) ?? '');
      return ms == null || !ms.isFinite
          ? null
          : DirectLatencyReading(
              DirectLatencyKind.icmp,
              ms.ceil().clamp(1, 5000).toInt(),
            );
    } finally {
      _abort.remove(cancel);
      cancel();
    }
  }
}
