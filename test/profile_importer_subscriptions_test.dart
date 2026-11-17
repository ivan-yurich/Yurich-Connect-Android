import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:aurum_vpn/src/models/vpn_profile.dart';
import 'package:aurum_vpn/src/services/profile_importer.dart';
import 'package:aurum_vpn/src/services/sing_box_config_builder.dart';
// Use the fake clock already supplied by flutter_test.
// ignore: depend_on_referenced_packages
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

const _source = 'https://subscriptions.example.invalid/plans/start';
const _link =
    'vless://11111111-1111-4111-8111-111111111111@server.example.invalid'
    '?security=tls#Fixture';
const _proxy = 'PROXY 127.0.0.1:${SingBoxConfigBuilder.localMixedProxyPort}';

void main() {
  for (final insecureFlag in ['allowInsecure=1', 'insecure=true']) {
    test(
      'Reality subscription keeps TLS validation with $insecureFlag',
      () async {
        const key = 'fixture-reality-key';
        final link =
            'vless://11111111-1111-4111-8111-111111111111@server.example.invalid'
            '?security=reality&type=tcp&sni=tls.example.invalid&pbk=$key'
            '&$insecureFlag#Fixture';
        final payload = jsonEncode({
          'links': [link],
          'metadata': {'expires_at': '2032-04-10T11:30:00+03:00'},
        });

        await _withTunnelClient(
          (uri) {
            expect(uri, Uri.parse(_source));
            return _Response(HttpStatus.ok, body: payload);
          },
          (client) async {
            final profile = (await _load()).single;
            expect(profile.kind, VpnProfileKind.vlessReality);
            expect(profile.subscriptionSource, _source);
            expect(
              profile.subscriptionExpiresAt,
              DateTime.utc(2032, 4, 10, 8, 30),
            );
            expect(profile.subscriptionExpiresAt?.isUtc, isTrue);
            final tls = profile.outbound?['tls'] as Map<String, dynamic>;
            expect(tls['enabled'], isTrue);
            expect(tls['server_name'], 'tls.example.invalid');
            expect(tls['reality'], {'enabled': true, 'public_key': key});
            expect(tls, isNot(contains('insecure')));
            expect(client.requests, hasLength(1));
          },
        );
      },
    );
  }

  test(
    'follows five validated relative redirects through the tunnel',
    () async {
      final responses = <_Response>[];
      final paths = [
        'start',
        ...List.generate(5, (index) => 'hop${index + 1}'),
      ];
      final statuses = [
        HttpStatus.movedPermanently,
        HttpStatus.found,
        HttpStatus.seeOther,
        HttpStatus.temporaryRedirect,
        HttpStatus.permanentRedirect,
      ];
      await _withTunnelClient(
        (uri) {
          final index = paths.indexOf(uri.pathSegments.last);
          expect(index, greaterThanOrEqualTo(0));
          if (index > 0) expect(responses.last.drains, 1);
          final response = index < statuses.length
              ? _Response(
                  statuses[index],
                  headers: {HttpHeaders.locationHeader: paths[index + 1]},
                )
              : _Response(
                  HttpStatus.ok,
                  body: 'expire=1893456000\n$_link',
                  headers: {
                    'subscription-userinfo':
                        'expire=2031-01-02T10:15:00%2B02:00',
                  },
                );
          responses.add(response);
          return response;
        },
        (client) async {
          final profile = (await _load()).single;
          expect(profile.name, 'Fixture');
          expect(profile.subscriptionSource, _source);
          expect(profile.originalInput, _link);
          expect(
            profile.subscriptionExpiresAt,
            DateTime.utc(2031, 1, 2, 8, 15),
          );
          expect(client.requests.map((request) => request.uri.path), [
            for (final part in paths) '/plans/$part',
          ]);
          final agents = client.requests
              .map(
                (request) => request.headers.value(HttpHeaders.userAgentHeader),
              )
              .toSet();
          expect(agents.single, isNotEmpty);
        },
      );
    },
  );

  test(
    'rejects a remote cleartext redirect before looking up its target',
    () async {
      final responses = <_Response>[];
      await _withTunnelClient(
        (uri) {
          expect(uri, Uri.parse(_source));
          final reply = _Response(
            HttpStatus.temporaryRedirect,
            headers: {
              HttpHeaders.locationHeader:
                  'http://redirect.example.invalid/plain',
            },
          );
          responses.add(reply);
          return reply;
        },
        (client) async {
          await expectLater(_load(), throwsA(_importError('HTTPS')));
          expect(client.requests, hasLength(3));
          expect(responses.map((response) => response.drains), [1, 1, 1]);
        },
      );
    },
  );

  test('redirect budget stops a loop independently for each retry', () async {
    final replies = <_Response>[];
    await _withTunnelClient(
      (uri) {
        final reply = _Response(
          HttpStatus.found,
          headers: {HttpHeaders.locationHeader: 'start'},
        );
        replies.add(reply);
        return reply;
      },
      (client) async {
        await expectLater(
          _load(),
          throwsA(_importError('Слишком много перенаправлений')),
        );
        final countByAgent = <String?, int>{};
        for (final request in client.requests) {
          expect(request.uri, Uri.parse(_source));
          final agent = request.headers.value(HttpHeaders.userAgentHeader);
          countByAgent.update(agent, (count) => count + 1, ifAbsent: () => 1);
        }
        expect(countByAgent.values, [6, 6, 6]);
        expect(replies.map((reply) => reply.drains), everyElement(1));
      },
    );
  });

  for (final (status, expected) in [
    (HttpStatus.found, 'Слишком много перенаправлений'),
    (HttpStatus.serviceUnavailable, 'HTTP 503'),
  ]) {
    test(
      'HTTP $status without a usable reply drains and never imports its body',
      () async {
        final replies = <_Response>[];
        await _withTunnelClient(
          (_) {
            final reply = _Response(status, body: _link);
            replies.add(reply);
            return reply;
          },
          (client) async {
            await expectLater(_load(), throwsA(_importError(expected)));
            expect(client.requests.map((request) => request.uri), [
              for (var i = 0; i < 3; i++) Uri.parse(_source),
            ]);
            expect(replies.map((reply) => reply.drains), [1, 1, 1]);
          },
        );
      },
    );
  }

  test(
    'falls back to the first non-HTML body for a clear parse error',
    () async {
      var attempt = 0;
      await _withTunnelClient(
        (_) => _Response(
          HttpStatus.ok,
          body: attempt++ == 0
              ? 'AAAA====ZZZZ'
              : '<html>Not a subscription</html>',
        ),
        (client) async {
          await expectLater(
            _load(),
            throwsA(_importError('Не нашёл поддерживаемых ссылок')),
          );
          expect(client.requests, hasLength(3));
        },
      );
    },
  );

  test(
    'oversized announced length is rejected even with a parseable body',
    () async {
      final replies = <_Response>[];
      await _withTunnelClient(
        (_) {
          final reply = _Response(
            HttpStatus.ok,
            body: _link,
            announcedLength: ProfileImporter.maxSubscriptionBytes + 1,
          );
          replies.add(reply);
          return reply;
        },
        (client) async {
          await expectLater(_load(), throwsA(_importError('4 MiB')));
          expect(client.requests, hasLength(3));
          expect(replies.map((reply) => reply.drains), [1, 1, 1]);
        },
      );
    },
  );

  test(
    'unknown body length still enforces the cumulative byte limit',
    () async {
      final firstChunk = Uint8List(ProfileImporter.maxSubscriptionBytes);
      final replies = <_Response>[];
      await _withTunnelClient(
        (_) {
          final reply = _Response(
            HttpStatus.ok,
            announcedLength: -1,
            chunks: [firstChunk, utf8.encode(_link)],
          );
          replies.add(reply);
          return reply;
        },
        (client) async {
          await expectLater(_load(), throwsA(_importError('4 MiB')));
          expect(client.requests, hasLength(3));
          expect(replies.map((reply) => reply.readChunks), [2, 2, 2]);
        },
      );
    },
  );

  test('stalled response headers abort the request before a bounded retry', () {
    fakeAsync((clock) {
      final stalled = <Completer<HttpClientResponse>>[];
      late final _ScriptedClient client;
      final outcomes = _observe(
        _withTunnelClient(
          (_) {
            final reply = Completer<HttpClientResponse>();
            stalled.add(reply);
            return reply.future;
          },
          (created) async {
            client = created;
            await expectLater(
              _load(timeout: const Duration(seconds: 21)),
              throwsA(_importError('не ответил вовремя')),
            );
          },
        ),
      );
      clock.flushMicrotasks();
      final request = client.requests.single;
      clock.elapse(const Duration(seconds: 19));
      expect(request.aborts, 0);
      expect(client.requests, hasLength(1));
      expect(outcomes, isEmpty);

      clock.elapse(const Duration(seconds: 1));
      expect(request.aborts, 1);
      expect(client.requests, hasLength(2));
      expect(client.requests.last.aborts, 0);
      expect(outcomes, isEmpty);

      clock.elapse(const Duration(seconds: 1));
      expect(outcomes, [true]);
      for (final reply in stalled) {
        reply.complete(_Response(HttpStatus.serviceUnavailable));
      }
      clock.flushMicrotasks();
      expect(client.requests, hasLength(2));
      expect(client.requestsAfterClose, 0);
    });
  });

  test('global deadline rejects a late reply and does not retry', () {
    fakeAsync((clock) {
      final stalled = Completer<HttpClientResponse>();
      late final _ScriptedClient client;
      final outcomes = _observe(
        _withTunnelClient((_) => stalled.future, (created) async {
          client = created;
          await expectLater(
            _load(timeout: const Duration(seconds: 2)),
            throwsA(_importError('не ответил вовремя')),
          );
        }),
      );
      clock.flushMicrotasks();
      expect(client.requests, hasLength(1));
      clock.elapse(const Duration(seconds: 2));
      expect(outcomes, [true]);
      expect(client.forceClosed, isTrue);
      stalled.complete(_Response(HttpStatus.serviceUnavailable));
      clock.flushMicrotasks();
      expect(client.requests, hasLength(1));
      expect(client.requestsAfterClose, 0);
    });
  });
}

List<Object> _observe(Future<void> future) {
  final outcomes = <Object>[];
  unawaited(
    future.then<void>(
      (_) => outcomes.add(true),
      onError: (Object error, StackTrace _) => outcomes.add(error),
    ),
  );
  return outcomes;
}

Future<List<VpnProfile>> _load({
  Duration timeout = const Duration(seconds: 45),
}) => ProfileImporter(
  subscriptionTimeout: timeout,
).importFromText(_source, currentTunnelOnly: true);

Matcher _importError(String text) => isA<ProfileImportException>().having(
  (error) => error.message,
  'message',
  contains(text),
);

typedef _Script = FutureOr<HttpClientResponse> Function(Uri uri);

Future<void> _withTunnelClient(
  _Script reply,
  Future<void> Function(_ScriptedClient client) scenario,
) async {
  final client = _ScriptedClient(reply);
  var created = 0;
  await HttpOverrides.runZoned(
    () => scenario(client),
    createHttpClient: (_) {
      created++;
      return client;
    },
  );
  expect(created, 1);
  expect(client.forceClosed, isTrue);
  expect(client.requestsAfterClose, 0);
  expect(client.routes, isNotEmpty);
  expect(client.routes, everyElement(_proxy));
  expect(
    client.requests.map((request) => request.followRedirects),
    everyElement(isFalse),
  );
}

final class _ScriptedClient extends Fake implements HttpClient {
  _ScriptedClient(this.reply);

  final _Script reply;
  final requests = <_Request>[];
  final routes = <String?>[];
  var forceClosed = false;
  var requestsAfterClose = 0;

  @override
  Duration? connectionTimeout;

  @override
  String Function(Uri)? findProxy;

  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    if (forceClosed) {
      requestsAfterClose++;
      throw StateError('Fixture client was already closed');
    }
    routes.add(findProxy?.call(url));
    final request = _Request(url, reply);
    requests.add(request);
    return request;
  }

  @override
  void close({bool force = false}) => forceClosed = force;
}

final class _Request extends Fake implements HttpClientRequest {
  _Request(this.uri, this.reply);

  @override
  final Uri uri;
  final _Script reply;
  var aborts = 0;

  @override
  final headers = _Headers();

  @override
  bool followRedirects = true;

  @override
  Future<HttpClientResponse> close() async => reply(uri);

  @override
  void abort([Object? exception, StackTrace? stackTrace]) => aborts++;
}

final class _Headers extends Fake implements HttpHeaders {
  _Headers([Map<String, String> seed = const {}])
    : values = {
        for (final entry in seed.entries)
          entry.key.toLowerCase(): [entry.value],
      };

  final Map<String, List<String>> values;

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {
    values[name.toLowerCase()] = [value.toString()];
  }

  @override
  List<String>? operator [](String name) => values[name.toLowerCase()];

  @override
  String? value(String name) => this[name]?.single;
}

final class _Response extends Stream<List<int>> implements HttpClientResponse {
  _Response(
    this.statusCode, {
    String body = '',
    Map<String, String> headers = const {},
    int? announcedLength,
    List<List<int>>? chunks,
  }) : headers = _Headers(headers),
       _chunks = chunks ?? [utf8.encode(body)],
       _announcedLength = announcedLength;

  @override
  final int statusCode;

  @override
  final HttpHeaders headers;
  final List<List<int>> _chunks;
  final int? _announcedLength;
  var drains = 0;
  var readChunks = 0;
  var _listened = false;

  @override
  int get contentLength =>
      _announcedLength ??
      _chunks.fold(0, (total, chunk) => total + chunk.length);

  @override
  Future<E> drain<E>([E? futureValue]) {
    drains++;
    return super.drain(futureValue);
  }

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    if (_listened) throw StateError('Fixture response was already read');
    _listened = true;
    return Stream<List<int>>.fromIterable(_chunks)
        .map((chunk) {
          readChunks++;
          return chunk;
        })
        .listen(
          onData,
          onError: onError,
          onDone: onDone,
          cancelOnError: cancelOnError,
        );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
