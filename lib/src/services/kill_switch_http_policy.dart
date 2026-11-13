import 'dart:io';
import 'kill_switch_service.dart';
import 'sing_box_config_builder.dart';

/// Android exempts the VPN owner UID from lockdown so its transport can work.
/// Do not use that exemption for subscriptions, updates or geolocation requests.
class KillSwitchHttpPolicy {
  static final _directClients = <HttpClient>{};
  static final _revoked = Expando<bool>();
  static final _policyProxied = Expando<bool>();

  static bool requiresProxy(KillSwitchState state) =>
      state.requested ||
      (state.supported &&
          (!state.known ||
              state.alwaysOn ||
              state.lockdown ||
              state.vpnActive));

  static bool isRevoked(HttpClient client) => _revoked[client] == true;

  static void cancelDirectRequests() {
    for (final client in _directClients.toList(growable: false)) {
      _revoked[client] = true;
      client.close(force: true);
    }
    _directClients.clear();
  }

  static void forget(HttpClient client) => _directClients.remove(client);

  static Future<void> protect(
    HttpClient client, {
    bool alwaysProxy = false,
  }) async {
    if (!Platform.isAndroid) return;
    final state = await const KillSwitchService().read();
    if (requiresProxy(state) || alwaysProxy) {
      if (requiresProxy(state)) cancelDirectRequests();
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

  static Future<bool> allowEndpointDiagnostics() async {
    if (!Platform.isAndroid) return true;
    final state = await const KillSwitchService().read();
    if (state.requested) return false;
    return state.supported
        ? state.known && !state.alwaysOn && !state.lockdown
        : true;
  }
}
