import 'dart:async';
import 'dart:io';

import 'first_successful_future.dart';

typedef HealthProbeEndpoint = ({Uri uri, int expectedStatus});

/// Owns every client in one race, including candidates that finish after it.
final class LocalProxyHealthProbe {
  LocalProxyHealthProbe({
    required int proxyPort,
    required String userAgent,
    this.onFailure,
    HttpClient Function()? clientFactory,
    List<HealthProbeEndpoint>? endpoints,
    this.connectTimeout = const Duration(seconds: 5),
    this.responseTimeout = const Duration(seconds: 7),
  }) : _proxyPort = RangeError.checkValueInInterval(proxyPort, 1, 65535),
       _userAgent = userAgent,
       _clientFactory = clientFactory ?? HttpClient.new,
       _endpoints = List.unmodifiable(endpoints ?? _defaultEndpoints);

  static final _defaultEndpoints = <HealthProbeEndpoint>[
    (
      uri: Uri.https('www.cloudflare.com', '/cdn-cgi/trace'),
      expectedStatus: 200,
    ),
    (
      uri: Uri.https('connectivitycheck.gstatic.com', '/generate_204'),
      expectedStatus: 204,
    ),
    (uri: Uri.https('www.google.com', '/generate_204'), expectedStatus: 204),
  ];

  final int _proxyPort;
  final String _userAgent;
  final HttpClient Function() _clientFactory;
  final List<HealthProbeEndpoint> _endpoints;
  final void Function(String message)? onFailure;
  final Duration connectTimeout;
  final Duration responseTimeout;
  final _closed = Completer<void>();
  final _activeChecks = <void Function()>{};

  /// Cancels only this probe owner's work, including open sockets, immediately.
  void close() {
    if (_closed.isCompleted) return;
    _closed.complete();
    for (final cancel in _activeChecks.toList(growable: false)) {
      cancel();
    }
  }

  Future<bool> check({Duration? timeout}) async {
    if (_closed.isCompleted || (timeout != null && timeout <= Duration.zero)) {
      return false;
    }
    final activeClients = <HttpClient>{};
    var settled = false;

    void cancelClients() {
      settled = true;
      for (final client in activeClients.toList(growable: false)) {
        client.close(force: true);
      }
    }

    _activeChecks.add(cancelClients);

    Future<bool> probe(HealthProbeEndpoint endpoint) async {
      if (settled) return false;
      final client = _clientFactory();
      activeClients.add(client);
      try {
        client
          ..connectionTimeout = connectTimeout
          ..findProxy = (_) => 'PROXY 127.0.0.1:$_proxyPort';
        final request = await client
            .getUrl(endpoint.uri)
            .timeout(connectTimeout);
        request.headers.set(HttpHeaders.userAgentHeader, _userAgent);
        request.followRedirects = false;
        final response = await request.close().timeout(responseTimeout);
        if (response.statusCode == endpoint.expectedStatus) {
          // TLS and the expected HTTP status are enough. No response body is
          // used, so do not keep a socket open to drain a possibly stalled body.
          return true;
        }
        if (!settled) {
          onFailure?.call(
            'VPN health probe HTTP ${response.statusCode}: ${endpoint.uri}',
          );
        }
      } on Object catch (error) {
        if (!settled) onFailure?.call('VPN health probe failed: $error');
      } finally {
        activeClients.remove(client);
        client.close(force: true);
      }
      return false;
    }

    try {
      final result = Future.any<bool>([
        firstSuccessfulFuture(_endpoints.map(probe)),
        _closed.future.then((_) => false),
      ]);
      return timeout == null
          ? await result
          : await result.timeout(timeout, onTimeout: () => false);
    } finally {
      // Future.any-style success does not cancel losing futures by itself.
      _activeChecks.remove(cancelClients);
      cancelClients();
    }
  }
}
