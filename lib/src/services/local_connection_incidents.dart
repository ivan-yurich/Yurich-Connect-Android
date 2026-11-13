import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../models/vpn_profile.dart';
import 'protocol_display_mapper.dart';

enum IncidentSignal {
  unknown('unknown', 'unknown'),
  startFailed('vpn_start', 'start_failed'),
  startTimeout('vpn_start', 'timeout'),
  stopTimeout('vpn_start', 'stop_timeout'),
  trafficCheckFailed('traffic', 'unknown');

  const IncidentSignal(this.stage, this.code);
  final String stage;
  final String code;
}

/// One user command, including all core retries and the Auto fallback.
/// No profile object, name, error string, address, or local attempt ID is kept.
final class LocalConnectionIncidentAttempt {
  LocalConnectionIncidentAttempt(this.epoch);

  final String epoch;
  String? _protocol;
  String _network = 'unknown';
  IncidentSignal signal = IncidentSignal.unknown;
  bool _cancelled = false;
  bool _succeeded = false;
  bool _consumed = false;

  void observedSuccess() => _succeeded = true;

  void nextCandidate() {
    _protocol = null;
    _network = 'unknown';
    signal = IncidentSignal.unknown;
  }

  void observedStart(VpnProfile profile, String network) {
    _protocol = switch (ProtocolDisplayMapper.mapProfile(profile)) {
      'NaiveProxy' => 'naive',
      'Hysteria2' => 'hysteria2',
      'Reality' || 'Reality (gRPC)' => 'reality',
      'XHTTP' || 'XHTTP (REALITY)' || 'XHTTP (TLS)' => 'xhttp',
      _ => 'unknown',
    };
    _network = switch (network) {
      'wifi' || 'cellular' => network,
      'ethernet' || 'bluetooth' || 'other' => 'other',
      _ => 'unknown',
    };
    signal = IncidentSignal.unknown;
  }

  void observedStartError(Object error) {
    if (error is TimeoutException) {
      signal = IncidentSignal.startTimeout;
    } else if (error is PlatformException) {
      switch (error.code) {
        // Android returns one result for denial and closing the dialog.
        case 'VPN_PERMISSION_DENIED':
        case 'START_CANCELLED':
          _cancelled = true;
        case 'START_VPN_ERROR':
          signal = IncidentSignal.startFailed;
      }
    }
  }

  Map<String, String>? takeTerminal({
    required bool current,
    required String? consentEpoch,
  }) {
    if (_consumed) return null;
    _consumed = true;
    final protocol = _protocol;
    if (!current ||
        _cancelled ||
        _succeeded ||
        consentEpoch != epoch ||
        protocol == null) {
      return null;
    }
    return {
      'epoch': epoch,
      'protocol': protocol,
      'network': _network,
      'stage': signal.stage,
      'code': signal.code,
    };
  }
}

final class LocalIncidentState {
  const LocalIncidentState.disabled() : epoch = null, queued = 0;
  const LocalIncidentState._(this.epoch, this.queued);

  final String? epoch;
  final int queued;

  bool get enabled => epoch != null;

  static LocalIncidentState? parse(Map<String, Object?>? data) {
    if (data == null) return null;
    if (data['enabled'] == false) return const LocalIncidentState.disabled();
    final epoch = data['epoch'];
    final queued = data['queued'];
    if (data['enabled'] != true ||
        epoch is! String ||
        epoch.isEmpty ||
        epoch.length > 80 ||
        queued is! int ||
        queued < 0 ||
        queued > 50) {
      return null;
    }
    return LocalIncidentState._(epoch, queued);
  }
}

/// Only non-sensitive status is returned from native Android. The bearer is
/// write-only and is never stored in Flutter preferences or returned here.
final class HermesDeliveryState {
  const HermesDeliveryState._({
    required this.enabled,
    required this.tokenConfigured,
    required this.authorizationBlocked,
    required this.routeReady,
  });

  final bool enabled;
  final bool tokenConfigured;
  final bool authorizationBlocked;
  final bool routeReady;

  static HermesDeliveryState? parse(Map<String, Object?>? data) {
    if (data == null) return null;
    final enabled = data['enabled'];
    final tokenConfigured = data['tokenConfigured'];
    if (enabled is! bool || tokenConfigured is! bool) return null;
    return HermesDeliveryState._(
      enabled: enabled,
      tokenConfigured: tokenConfigured,
      authorizationBlocked: data['authorizationBlocked'] == true,
      routeReady: data['routeReady'] == true,
    );
  }
}

/// Native Android pilot bridge. The separate delivery flag keeps network
/// controls out of local-only previews and ordinary builds.
final class LocalConnectionIncidentsService {
  const LocalConnectionIncidentsService();

  static const pilotBuild = bool.fromEnvironment('YURICH_LOCAL_INCIDENT_PILOT');
  static const hermesPilotBuild = bool.fromEnvironment('YURICH_HERMES_PILOT');
  static const hermesDeliveryPilotBuild = bool.fromEnvironment(
    'YURICH_HERMES_DELIVERY_PILOT',
  );
  static const maxBearerLength = 512;
  static final _bearerPattern = RegExp(r'[A-Za-z0-9._~+/-]+={0,8}');
  static const _channel = MethodChannel('online.dnsai.ivanvpn/local_incidents');

  bool get available =>
      pilotBuild && !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  bool get hermesPreviewAvailable => available && hermesPilotBuild;
  bool get hermesDeliveryAvailable =>
      hermesPreviewAvailable && hermesDeliveryPilotBuild;

  static bool isValidHermesBearer(String value) =>
      value.isNotEmpty &&
      value.length <= maxBearerLength &&
      _bearerPattern.matchAsPrefix(value)?.end == value.length;

  Future<String?> hermesPreview() async {
    if (!hermesPreviewAvailable) return null;
    try {
      return await _channel
          .invokeMethod<String>('hermesPreview')
          .timeout(const Duration(seconds: 3));
    } on Object {
      return null;
    }
  }

  Future<LocalIncidentState?> state() => _call('state');

  Future<LocalIncidentState?> setEnabled(bool enabled) =>
      _call('setEnabled', {'enabled': enabled});

  Future<LocalIncidentState?> record(Map<String, String> incident) =>
      _call('record', incident);

  Future<HermesDeliveryState?> hermesDeliveryState() =>
      _deliveryCall('hermesDeliveryState');

  Future<HermesDeliveryState?> configureHermesDelivery({
    required bool enabled,
    String? bearer,
  }) async {
    if (enabled && (bearer == null || !isValidHermesBearer(bearer))) {
      return null;
    }
    return _deliveryCall('configureHermesDelivery', {
      'enabled': enabled,
      if (enabled) 'bearer': bearer,
    });
  }

  Future<bool> setHermesSecretScreen(bool enabled) async {
    if (!hermesDeliveryAvailable) return false;
    try {
      return await _channel
              .invokeMethod<bool>('setHermesSecretScreen', {'enabled': enabled})
              .timeout(const Duration(seconds: 3)) ==
          true;
    } on Object {
      return false;
    }
  }

  Future<HermesDeliveryState?> _deliveryCall(
    String method, [
    Map<String, Object?>? args,
  ]) async {
    if (!hermesDeliveryAvailable) return null;
    try {
      final value = await _channel
          .invokeMapMethod<String, Object?>(method, args)
          .timeout(const Duration(seconds: 5));
      return HermesDeliveryState.parse(value);
    } on Object {
      return null;
    }
  }

  Future<LocalIncidentState?> _call(
    String method, [
    Map<String, Object?>? args,
  ]) async {
    if (!available) return null;
    try {
      final value = await _channel
          .invokeMapMethod<String, Object?>(method, args)
          .timeout(const Duration(seconds: 3));
      return LocalIncidentState.parse(value);
    } on Object {
      // Optional diagnostics must not alter VPN operation or log raw errors.
      return null;
    }
  }
}
