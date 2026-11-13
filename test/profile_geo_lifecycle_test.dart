import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:aurum_vpn/src/models/vpn_profile.dart';
import 'package:aurum_vpn/src/services/profile_geo_service.dart';
import 'package:aurum_vpn/src/services/vpn_session_controller.dart';
import 'package:flutter_test/flutter_test.dart';

class _Headers extends Fake implements HttpHeaders {
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {}
}

class _Response extends Fake implements HttpClientResponse {
  _Response(this.statusCode, String body, {int? length})
    : contentLength = length ?? utf8.encode(body).length,
      body = Stream.value(utf8.encode(body));
  _Response.chunks(List<List<int>> chunks)
    : statusCode = 200,
      contentLength = -1,
      body = Stream.fromIterable(chunks);
  @override
  final int statusCode;
  @override
  final int contentLength;
  final Stream<List<int>> body;
  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => body.listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );
}

class _Request extends Fake implements HttpClientRequest {
  _Request(this.result);
  final Future<HttpClientResponse> result;
  @override
  final headers = _Headers();
  @override
  bool followRedirects = true;
  @override
  Future<HttpClientResponse> close() => result;
}

class _Client extends Fake implements HttpClient {
  _Client(this.respond);
  final Future<HttpClientResponse> Function(Uri) respond;
  final requested = <Uri>[];
  bool closed = false;
  bool? forced;
  @override
  Duration? connectionTimeout;
  @override
  String Function(Uri)? findProxy;
  @override
  Future<HttpClientRequest> getUrl(Uri uri) async {
    requested.add(uri);
    return _Request(respond(uri));
  }

  @override
  void close({bool force = false}) {
    closed = true;
    forced = force;
  }
}

VpnProfile _profile(
  String server, {
  VpnProfileKind kind = VpnProfileKind.naive,
}) => VpnProfile(
  id: server,
  name: 'Synthetic',
  kind: kind,
  originalInput: '',
  server: server,
);
final _sources = [
  Uri.https('geo.example', '/first'),
  Uri.https('fallback.example', '/second'),
];
Future<HttpClientResponse> _geo(String country) async =>
    _Response(200, jsonEncode({'country_code': country}));

void main() {
  test(
    'same endpoint shares in-flight DNS and result across protocol profiles',
    () async {
      final addresses = Completer<List<InternetAddress>>();
      var lookups = 0;
      var clients = 0;
      final client = _Client((_) => _geo('NL'));
      final service = ProfileGeoService(
        addressLookup: (_) {
          lookups++;
          return addresses.future;
        },
        clientFactory: () {
          clients++;
          return client;
        },
        ipSources: (_) => _sources,
      );
      addTearDown(service.close);
      final a = service.resolveEndpointCountry(_profile('EDGE.example'));
      final b = service.resolveEndpointCountry(
        _profile('edge.example', kind: VpnProfileKind.hysteria2),
      );
      addresses.complete([InternetAddress.loopbackIPv4]);
      expect((await a)?.countryCode, 'NL');
      expect((await b)?.countryCode, 'NL');
      expect(
        (await service.resolveEndpointCountry(
          _profile('edge.example'),
        ))?.countryCode,
        'NL',
      );
      expect(lookups, 1);
      expect(clients, 1);
      expect(client.requested, hasLength(1));
      expect(client.closed, isTrue);
      expect(client.forced, isTrue);
    },
  );

  test(
    'negative cache is bounded in time and clock rollback cannot extend it',
    () async {
      var now = DateTime.utc(2026, 10, 30);
      var requests = 0;
      final service = ProfileGeoService(
        now: () => now,
        addressLookup: (_) async => [InternetAddress.loopbackIPv4],
        ipSources: (_) => [_sources.first],
        clientFactory: () => _Client((_) async {
          requests++;
          return _Response(503, '');
        }),
      );
      addTearDown(service.close);
      final profile = _profile('edge.example');
      expect(await service.resolveEndpointCountry(profile), isNull);
      expect(await service.resolveEndpointCountry(profile), isNull);
      expect(requests, 1);
      now = now.add(const Duration(minutes: 2));
      expect(await service.resolveEndpointCountry(profile), isNull);
      expect(requests, 2);
      now = now.subtract(const Duration(hours: 1));
      expect(await service.resolveEndpointCountry(profile), isNull);
      expect(requests, 3);
    },
  );

  test('endpoint cache has a fixed capacity', () async {
    var lookups = 0;
    final service = ProfileGeoService(
      cacheCapacity: 2,
      addressLookup: (_) async {
        lookups++;
        return [InternetAddress.loopbackIPv4];
      },
      ipSources: (_) => [_sources.first],
      clientFactory: () => _Client((_) => _geo('DE')),
    );
    addTearDown(service.close);
    for (final host in ['a.example', 'b.example', 'c.example', 'a.example']) {
      await service.resolveEndpointCountry(_profile(host));
    }
    expect(lookups, 4);
  });

  test(
    'one deadline bounds DNS and late results cannot open HTTP clients',
    () async {
      final addresses = Completer<List<InternetAddress>>();
      var clients = 0;
      final service = ProfileGeoService(
        lookupTimeout: const Duration(milliseconds: 40),
        addressLookup: (_) => addresses.future,
        clientFactory: () {
          clients++;
          return _Client((_) => _geo('DE'));
        },
      );
      addTearDown(service.close);
      expect(
        await service.resolveEndpointCountry(_profile('edge.example')),
        isNull,
      );
      addresses.complete([InternetAddress.loopbackIPv4]);
      await Future<void>.delayed(Duration.zero);
      expect(clients, 0);
    },
  );

  test(
    'deadline force-closes a stalled request without starting more fallbacks',
    () async {
      final headers = Completer<HttpClientResponse>();
      final client = _Client((_) => headers.future);
      final service = ProfileGeoService(
        clientFactory: () => client,
        exitSources: _sources,
        lookupTimeout: const Duration(milliseconds: 40),
      );
      addTearDown(service.close);
      expect(await service.resolveExitCountryThroughTunnel(), isNull);
      expect(client.closed, isTrue);
      expect(client.forced, isTrue);
      headers.complete(await _geo('DE'));
      await Future<void>.delayed(Duration.zero);
      expect(client.requested, hasLength(1));
    },
  );

  test(
    'oversized declared and chunked responses fall back within one lookup',
    () async {
      for (final response in [
        _Response(200, '{}', length: 1000),
        _Response.chunks([List.filled(80, 65)]),
      ]) {
        final client = _Client(
          (uri) => uri == _sources.first ? Future.value(response) : _geo('PL'),
        );
        final service = ProfileGeoService(
          clientFactory: () => client,
          exitSources: _sources,
          maxResponseBytes: 64,
        );
        expect(
          (await service.resolveExitCountryThroughTunnel())?.countryCode,
          'PL',
        );
        expect(client.requested, hasLength(2));
        expect(client.closed, isTrue);
        service.close();
      }
    },
  );

  test('cancelling one profile cannot close another profile lookup', () async {
    final aResponse = Completer<HttpClientResponse>();
    final bResponse = Completer<HttpClientResponse>();
    final a = _Client((_) => aResponse.future);
    final b = _Client((_) => bResponse.future);
    final clients = [a, b];
    var index = 0;
    final service = ProfileGeoService(
      clientFactory: () => clients[index++],
      exitSources: [_sources.first],
    );
    addTearDown(service.close);
    final cancelA = ProfileGeoCancellation();
    final first = service.resolveExitCountryThroughTunnel(
      cancellation: cancelA,
    );
    final second = service.resolveExitCountryThroughTunnel();
    cancelA.cancel();
    expect(await first, isNull);
    expect(a.closed, isTrue);
    expect(b.closed, isFalse);
    aResponse.complete(await _geo('DE'));
    bResponse.complete(await _geo('FR'));
    expect((await second)?.countryCode, 'FR');
    expect(b.closed, isTrue);
  });

  test(
    'exit country is never reused from a previous tunnel and remains proxied',
    () async {
      final clients = <_Client>[];
      final service = ProfileGeoService(
        exitSources: [_sources.first],
        clientFactory: () {
          final country = clients.isEmpty ? 'NL' : 'FR';
          final client = _Client((_) => _geo(country));
          clients.add(client);
          return client;
        },
      );
      addTearDown(service.close);
      expect(
        (await service.resolveExitCountryThroughTunnel())?.countryCode,
        'NL',
      );
      expect(
        (await service.resolveExitCountryThroughTunnel())?.countryCode,
        'FR',
      );
      expect(clients, hasLength(2));
      for (final client in clients) {
        expect(client.findProxy!(_sources.first), 'PROXY 127.0.0.1:20808');
      }
    },
  );

  test(
    'service disposal closes all active lookups and refuses new work',
    () async {
      final pending = Completer<HttpClientResponse>();
      final client = _Client((_) => pending.future);
      final service = ProfileGeoService(
        clientFactory: () => client,
        exitSources: [_sources.first],
      );
      final result = service.resolveExitCountryThroughTunnel();
      service.close();
      expect(await result, isNull);
      expect(client.forced, isTrue);
      expect(await service.resolveExitCountryThroughTunnel(), isNull);
      pending.complete(await _geo('NL'));
      expect(client.requested, hasLength(1));
    },
  );

  test(
    'session supersession cancels its lookup instead of applying stale geo',
    () async {
      final sessions = VpnSessionController();
      addTearDown(sessions.dispose);
      final pending = Completer<HttpClientResponse>();
      final client = _Client((_) => pending.future);
      final service = ProfileGeoService(
        clientFactory: () => client,
        exitSources: [_sources.first],
      );
      addTearDown(service.close);
      final cancellation = ProfileGeoCancellation();
      final operation = sessions.beginConnect();
      var applied = false;
      final work = () async {
        try {
          await sessions.cancelWhenSuperseded(
            operation,
            service.resolveExitCountryThroughTunnel(cancellation: cancellation),
          );
          applied = true;
        } on VpnSessionCancelled {
          /* Superseded is not a network failure. */
        } finally {
          cancellation.cancel();
        }
      }();
      sessions.beginProfileSwitch();
      await work;
      expect(applied, isFalse);
      expect(client.closed, isTrue);
      pending.complete(await _geo('DE'));
    },
  );

  test(
    'malformed and unsuccessful geo responses cannot become countries',
    () async {
      for (final json in [
        {'country_code': '11'},
        {'success': false, 'country_code': 'DE'},
        {'country': 'Germany'},
      ]) {
        final service = ProfileGeoService(
          exitSources: [_sources.first],
          clientFactory: () =>
              _Client((_) async => _Response(200, jsonEncode(json))),
        );
        expect(await service.resolveExitCountryThroughTunnel(), isNull);
        service.close();
      }
    },
  );
}
