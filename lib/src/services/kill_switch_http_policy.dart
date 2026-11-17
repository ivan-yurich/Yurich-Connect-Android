import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;

import 'kill_switch_service.dart';
import 'sing_box_config_builder.dart';

/// Android exempts the VPN owner UID from lockdown so its transport can work.
/// Do not use that exemption for subscriptions, updates or geolocation requests.
class KillSwitchHttpPolicy {
  static final _routes = KillSwitchHttpRoutes();
  static final _systemRoutes = Platform.isAndroid ? _routes : null;

  static bool requiresProxy(KillSwitchState state) =>
      state.requested ||
      (state.supported &&
          (!state.known ||
              state.alwaysOn ||
              state.lockdown ||
              state.vpnActive));

  static bool isRevoked(HttpClient client) => _routes.isRevoked(client);

  static void cancelDirectRequests() => _routes.cancelDirectRequests();

  static void forget(HttpClient client) => _routes.forget(client);

  static Future<void> protect(HttpClient client, {bool alwaysProxy = false}) =>
      _systemRoutes?.protectFromSystem(client, alwaysProxy: alwaysProxy) ??
      Future<void>.value();

  static Future<bool> allowEndpointDiagnostics() =>
      _systemRoutes?.allowEndpointDiagnosticsFromSystem() ?? Future.value(true);
}

/// Applies protection snapshots and owns the clients it tracks.
/// Runtime callers use the platform-gated [KillSwitchHttpPolicy] facade.
final class KillSwitchHttpRoutes {
  final _directClients = <HttpClient>{};
  final _revoked = Expando<bool>();
  final _policyProxied = Expando<bool>();

  bool isRevoked(HttpClient client) => _revoked[client] == true;

  void cancelDirectRequests() {
    for (final client in _directClients.toList(growable: false)) {
      _revoked[client] = true;
      client.close(force: true);
    }
    _directClients.clear();
  }

  void forget(HttpClient client) => _directClients.remove(client);

  @visibleForTesting
  Future<void> protectFromSystem(
    HttpClient client, {
    bool alwaysProxy = false,
  }) async {
    final state = await const KillSwitchService().read();
    apply(client, state, alwaysProxy: alwaysProxy);
  }

  @visibleForTesting
  Future<bool> allowEndpointDiagnosticsFromSystem() async {
    final state = await const KillSwitchService().read();
    return allowsEndpointDiagnostics(state);
  }

  void apply(
    HttpClient client,
    KillSwitchState state, {
    bool alwaysProxy = false,
  }) {
    final requiresProxy = KillSwitchHttpPolicy.requiresProxy(state);
    if (requiresProxy || alwaysProxy) {
      if (requiresProxy) cancelDirectRequests();
      if (isRevoked(client)) {
        throw StateError(
          'Network policy changed; retry using a new HTTP client',
        );
      }
      // No '; DIRECT' fallback, including while the VPN process is unavailable.
      // Existing direct sockets are revoked; no direct fallback is retained.
      client.findProxy = (_) =>
          'PROXY 127.0.0.1:${SingBoxConfigBuilder.localMixedProxyPort}';
      _directClients.remove(client);
      _policyProxied[client] = !alwaysProxy;
    } else {
      if (isRevoked(client)) {
        throw StateError('HTTP client revoked by network policy');
      }
      // Only undo our own override after a live confirmed non-VPN snapshot.
      if (_policyProxied[client] == true) {
        client.findProxy = null;
        _policyProxied[client] = false;
      }
      _directClients.add(client);
    }
  }

  static bool allowsEndpointDiagnostics(KillSwitchState state) {
    if (state.requested) return false;
    return state.supported
        ? state.known && !state.alwaysOn && !state.lockdown
        : true;
  }
}
