import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models/vpn_profile.dart';
import 'sing_box_config_builder.dart';
import 'kill_switch_http_policy.dart';

class ProfileGeo {
  const ProfileGeo({required this.countryCode, this.countryName, this.ip});

  final String countryCode;
  final String? countryName;
  final String? ip;

  String get flag => countryCodeToFlag(countryCode) ?? '🌐';

  static String? countryCodeToFlag(String? value) {
    final code = value?.trim().toUpperCase();
    if (code == null || code.length != 2) {
      return null;
    }

    final first = code.codeUnitAt(0);
    final second = code.codeUnitAt(1);
    if (first < 0x41 || first > 0x5A || second < 0x41 || second > 0x5A) {
      return null;
    }

    return String.fromCharCodes([
      0x1F1E6 + first - 0x41,
      0x1F1E6 + second - 0x41,
    ]);
  }
}

/// Cancellation owns only one lookup, never another profile's requests.
final class ProfileGeoCancellation {
  final _signal = Completer<void>();
  final _clients = <HttpClient>{};
  bool get isCancelled => _signal.isCompleted;
  void cancel() {
    if (isCancelled) return;
    _signal.complete();
    for (final client in _clients) {
      KillSwitchHttpPolicy.forget(client);
      client.close(force: true);
    }
    _clients.clear();
  }
}

final class _GeoCacheEntry {
  const _GeoCacheEntry(this.result, this.createdAt, this.expiresAt);
  final ProfileGeo? result;
  final DateTime createdAt;
  final DateTime expiresAt;
}

class ProfileGeoService {
  ProfileGeoService({
    HttpClient Function()? clientFactory,
    Future<List<InternetAddress>> Function(String)? addressLookup,
    List<Uri>? exitSources,
    List<Uri> Function(String)? ipSources,
    DateTime Function()? now,
    this.lookupTimeout = const Duration(seconds: 8),
    this.successCacheTtl = const Duration(hours: 1),
    this.failureCacheTtl = const Duration(minutes: 1),
    this.cacheCapacity = 128,
    this.maxResponseBytes = 64 * 1024,
  }) : _clientFactory = clientFactory ?? HttpClient.new,
       _addressLookup = addressLookup ?? InternetAddress.lookup,
       _exitSources = List.unmodifiable(
         exitSources ??
             [
               Uri.https('ipwho.is', '/'),
               Uri.https('ipapi.co', '/json/'),
               Uri.https('api.country.is', '/'),
             ],
       ),
       _ipSources = ipSources ?? _defaultIpSources,
       _now = now ?? DateTime.now;
  final HttpClient Function() _clientFactory;
  final Future<List<InternetAddress>> Function(String) _addressLookup;
  final List<Uri> _exitSources;
  final List<Uri> Function(String) _ipSources;
  final DateTime Function() _now;
  final Duration lookupTimeout;
  final Duration successCacheTtl;
  final Duration failureCacheTtl;
  final int cacheCapacity;
  final int maxResponseBytes;
  final _cache = <String, _GeoCacheEntry>{};
  final _inFlight = <String, Future<ProfileGeo?>>{};
  final _active = <ProfileGeoCancellation>{};
  bool _closed = false;

  /// Shared by profiles using the same endpoint, including a short failure TTL.
  Future<ProfileGeo?> resolveEndpointCountry(VpnProfile profile) {
    final server = profile.server?.trim().toLowerCase();
    if (_closed || server == null || server.isEmpty) return Future.value();
    final now = _now();
    final cached = _cache[server];
    if (cached != null &&
        !now.isBefore(cached.createdAt) &&
        now.isBefore(cached.expiresAt)) {
      return Future.value(cached.result);
    }
    _cache.remove(server);
    final pending = _inFlight[server];
    if (pending != null) return pending;
    final future =
        _lookup((cancel) async {
              if (!await KillSwitchHttpPolicy.allowEndpointDiagnostics()) {
                return null;
              }
              final literal = InternetAddress.tryParse(server);
              final addresses = literal == null
                  ? await _addressLookup(
                      server,
                    ).timeout(const Duration(seconds: 4))
                  : [literal];
              if (cancel.isCancelled) return null;
              final sorted = addresses.toList()
                ..sort(
                  (a, b) => a.type == b.type
                      ? 0
                      : a.type == InternetAddressType.IPv4
                      ? -1
                      : 1,
                );
              final client = _client(cancel, throughTunnel: false);
              for (final address in sorted.take(2)) {
                for (final uri in _ipSources(address.address)) {
                  if (cancel.isCancelled) return null;
                  final result = await _fetchGeo(client, uri, cancel);
                  if (result != null) return result;
                }
              }
              return null;
            })
            .then((result) {
              if (!_closed && cacheCapacity > 0) {
                final at = _now();
                final ttl = result == null ? failureCacheTtl : successCacheTtl;
                while (_cache.length >= cacheCapacity) {
                  _cache.remove(_cache.keys.first);
                }
                _cache[server] = _GeoCacheEntry(result, at, at.add(ttl));
              }
              return result;
            })
            .whenComplete(() {
              _inFlight.remove(server);
            });
    _inFlight[server] = future;
    return future;
  }

  /// Exit observations are never cached across sessions or VPN profiles.
  Future<ProfileGeo?> resolveExitCountryThroughTunnel({
    ProfileGeoCancellation? cancellation,
  }) => _lookup((cancel) async {
    final client = _client(cancel, throughTunnel: true);
    for (final uri in _exitSources) {
      if (cancel.isCancelled) return null;
      final result = await _fetchGeo(client, uri, cancel, alwaysProxy: true);
      if (result != null) return result;
    }
    return null;
  }, cancellation: cancellation);

  void close() {
    if (_closed) return;
    _closed = true;
    for (final cancel in _active.toList(growable: false)) {
      cancel.cancel();
    }
    _cache.clear();
  }

  Future<ProfileGeo?> _lookup(
    Future<ProfileGeo?> Function(ProfileGeoCancellation) action, {
    ProfileGeoCancellation? cancellation,
  }) async {
    final cancel = cancellation ?? ProfileGeoCancellation();
    if (_closed || cancel.isCancelled || lookupTimeout <= Duration.zero) {
      return null;
    }
    _active.add(cancel);
    try {
      return await Future.any<ProfileGeo?>([
        action(cancel),
        cancel._signal.future.then((_) => null),
      ]).timeout(lookupTimeout, onTimeout: () => null);
    } on Object {
      return null;
    } finally {
      _active.remove(cancel);
      cancel.cancel();
    }
  }

  HttpClient _client(
    ProfileGeoCancellation cancel, {
    required bool throughTunnel,
  }) {
    final client = _clientFactory()
      ..connectionTimeout = const Duration(seconds: 5)
      ..findProxy = throughTunnel
          ? (_) => 'PROXY 127.0.0.1:${SingBoxConfigBuilder.localMixedProxyPort}'
          : null;
    cancel._clients.add(client);
    return client;
  }

  static List<Uri> _defaultIpSources(String ip) => [
    Uri.https('ipwho.is', '/$ip'),
    Uri.https('ipapi.co', '/$ip/json/'),
    Uri.https('api.country.is', '/$ip'),
  ];

  Future<ProfileGeo?> _fetchGeo(
    HttpClient client,
    Uri uri,
    ProfileGeoCancellation cancel, {
    bool alwaysProxy = false,
  }) async {
    try {
      await KillSwitchHttpPolicy.protect(client, alwaysProxy: alwaysProxy);
      final request = await client.getUrl(uri);
      if (cancel.isCancelled) return null;
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      request.headers.set(HttpHeaders.userAgentHeader, 'YurichConnect-Geo');
      request.followRedirects = false;
      final response = await request.close();
      if (response.statusCode < 200 ||
          response.statusCode >= 300 ||
          response.contentLength > maxResponseBytes) {
        return null;
      }
      final bytes = <int>[];
      await for (final chunk in response) {
        if (cancel.isCancelled ||
            bytes.length + chunk.length > maxResponseBytes) {
          return null;
        }
        bytes.addAll(chunk);
      }
      if (cancel.isCancelled) return null;
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map || decoded['success'] == false) return null;
      final code =
          (decoded['country_code'] ??
                  decoded['countryCode'] ??
                  decoded['country_code2'] ??
                  decoded['country'])
              ?.toString()
              .trim()
              .toUpperCase();
      if (ProfileGeo.countryCodeToFlag(code) == null) return null;
      final name =
          (decoded['country_name'] ??
                  decoded['countryName'] ??
                  decoded['country'])
              ?.toString()
              .trim();
      return ProfileGeo(
        countryCode: code!,
        countryName: name == code ? null : name,
        ip: (decoded['ip'] ?? decoded['query'])?.toString(),
      );
    } on Object {
      return null;
    }
  }
}
