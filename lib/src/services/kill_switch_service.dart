import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class KillSwitchState {
  const KillSwitchState({
    this.supported = true,
    this.known = false,
    this.requested = false,
    this.runtimeKnown = false,
    this.alwaysOn = false,
    this.lockdown = false,
    this.strictRuntime = false,
    this.vpnActive = false,
  });

  factory KillSwitchState.fromMap(Map<dynamic, dynamic> value) =>
      KillSwitchState(
        supported: value['supported'] != false,
        known: value['known'] == true,
        requested: value['requested'] == true,
        runtimeKnown: value['runtimeKnown'] == true,
        alwaysOn: value['alwaysOn'] == true,
        lockdown: value['lockdown'] == true,
        strictRuntime: value['strictRuntime'] == true,
        vpnActive: value['vpnActive'] == true,
      );

  final bool supported;
  final bool known;

  /// Persistent routing intent, never evidence of the Android firewall state.
  final bool requested;
  final bool runtimeKnown;
  final bool alwaysOn;
  final bool lockdown;
  final bool strictRuntime;
  final bool vpnActive;
  bool get systemEnforced => supported && known && alwaysOn && lockdown;
  bool get fullyConfigured =>
      systemEnforced && runtimeKnown && vpnActive && strictRuntime;
}

/// Separates persistent routing intent from live OS/runtime confirmation.
class KillSwitchService {
  const KillSwitchService();
  static const _channel = MethodChannel('com.tecclub.flutter_singbox/methods');
  static Future<KillSwitchState>? _pendingRead;
  static Future<void>? _intentWrite;
  static int _intentRevision = 0;

  Future<KillSwitchState> read() {
    final write = _intentWrite;
    if (write != null) return write.then((_) => read());
    final pending = _pendingRead;
    if (pending != null) return pending;
    final revision = _intentRevision;
    late Future<KillSwitchState> query;
    query = _readNative()
        .then<KillSwitchState>((state) {
          if (revision == _intentRevision) return state;
          // A pre-mutation answer must not reopen direct control-plane traffic.
          if (identical(_pendingRead, query)) _pendingRead = null;
          return read();
        })
        .whenComplete(() {
          if (identical(_pendingRead, query)) _pendingRead = null;
        });
    _pendingRead = query;
    return query;
  }

  Future<void> setRequested(bool enabled) async {
    final previous = _intentWrite;
    final gate = Completer<void>();
    _intentWrite = gate.future;
    _intentRevision++;
    _pendingRead = null;
    try {
      if (previous != null) await previous;
      final saved = await _channel.invokeMethod<bool>(
        'setKillSwitchRequested',
        {'enabled': enabled},
      );
      if (saved != true) throw StateError('Protection intent was not saved');
    } finally {
      if (identical(_intentWrite, gate.future)) _intentWrite = null;
      _intentRevision++;
      _pendingRead = null;
      gate.complete();
    }
  }

  Future<KillSwitchState> _readNative() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return const KillSwitchState(supported: false);
    }
    try {
      final value = await _channel
          .invokeMapMethod<dynamic, dynamic>('getKillSwitchState')
          .timeout(const Duration(seconds: 3));
      return value == null
          ? const KillSwitchState()
          : KillSwitchState.fromMap(value);
    } on Object {
      return const KillSwitchState();
    }
  }

  Future<void> openSettings() => _channel.invokeMethod<void>('openVpnSettings');
}
