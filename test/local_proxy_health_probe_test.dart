import 'dart:async';
import 'dart:io';

import 'package:aurum_vpn/src/services/local_proxy_health_probe.dart';
import 'package:flutter_test/flutter_test.dart';

final class _Headers extends Fake implements HttpHeaders {
  final values = <String, Object>{};

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {
    values[name] = value;
  }
}

final class _Response extends Fake implements HttpClientResponse {
  _Response(this.statusCode);

  @override
  final int statusCode;

  @override
  Future<E> drain<E>([E? futureValue]) => Completer<E>().future;
}

final class _Request extends Fake implements HttpClientRequest {
  final response = Completer<HttpClientResponse>();
  bool closeCalled = false;

  @override
  final _Headers headers = _Headers();

  @override
  bool followRedirects = true;

  @override
  Future<HttpClientResponse> close() {
    closeCalled = true;
    return response.future;
  }
}

final class _Client extends Fake implements HttpClient {
  _Client({this.stallOpen = false});

  final bool stallOpen;
  final pendingOpen = Completer<HttpClientRequest>();
  final request = _Request();
  bool closed = false;
  bool? forceClosed;
  Uri? uri;

  @override
  Duration? connectionTimeout;

  @override
  String Function(Uri)? findProxy;

  @override
  Future<HttpClientRequest> getUrl(Uri value) {
    uri = value;
    return stallOpen ? pendingOpen.future : Future.value(request);
  }

  @override
  void close({bool force = false}) {
    closed = true;
    forceClosed = force;
    if (stallOpen && !pendingOpen.isCompleted) {
      pendingOpen.completeError(const SocketException('closed by owner'));
    }
    if (request.closeCalled && !request.response.isCompleted) {
      request.response.completeError(const SocketException('closed by owner'));
    }
  }

  void respond(int code) => request.response.complete(_Response(code));
}

LocalProxyHealthProbe _probe(
  List<_Client> clients, {
  List<String>? failures,
  Duration connectTimeout = const Duration(seconds: 1),
  Duration responseTimeout = const Duration(seconds: 1),
  int? endpointCount,
}) {
  var index = 0;
  return LocalProxyHealthProbe(
    proxyPort: 20808,
    userAgent: 'YurichConnect/Test',
    clientFactory: () => clients[index++],
    connectTimeout: connectTimeout,
    responseTimeout: responseTimeout,
    onFailure: failures?.add,
    endpoints: [
      for (var i = 0; i < (endpointCount ?? clients.length); i++)
        (uri: Uri.https('probe-$i.example.com', '/check'), expectedStatus: 204),
    ],
  );
}

void main() {
  test('first success closes response and stalled losing clients', () async {
    final winner = _Client();
    final stalledHeaders = _Client();
    final stalledOpen = _Client(stallOpen: true);
    final failures = <String>[];
    final result = _probe([
      winner,
      stalledHeaders,
      stalledOpen,
    ], failures: failures).check();
    winner.respond(204);
    expect(await result.timeout(const Duration(seconds: 1)), isTrue);
    await Future<void>.delayed(Duration.zero);
    for (final client in [winner, stalledHeaders, stalledOpen]) {
      expect(client.closed, isTrue);
      expect(client.forceClosed, isTrue);
    }
    expect(
      failures,
      isEmpty,
      reason: 'Race cancellation is not a network failure',
    );
    expect(winner.findProxy!(winner.uri!), 'PROXY 127.0.0.1:20808');
    expect(
      winner.request.headers.values[HttpHeaders.userAgentHeader],
      'YurichConnect/Test',
    );
    expect(winner.request.followRedirects, isFalse);
  });

  test(
    'response headers succeed without waiting for a body to finish',
    () async {
      final client = _Client();
      final result = _probe([client]).check();
      client.respond(204);
      expect(await result.timeout(const Duration(milliseconds: 500)), isTrue);
      expect(client.closed, isTrue);
    },
  );

  test(
    'one failed candidate does not cancel a slower successful candidate',
    () async {
      final first = _Client();
      final second = _Client();
      final result = _probe([first, second]).check();
      first.respond(500);
      await Future<void>.delayed(Duration.zero);
      expect(second.closed, isFalse);
      second.respond(204);
      expect(await result, isTrue);
    },
  );

  test('all failed candidates return false and close every client', () async {
    final clients = [_Client(), _Client()];
    final failures = <String>[];
    final result = _probe(clients, failures: failures).check();
    clients[0].respond(500);
    clients[1].respond(302);
    expect(await result, isFalse);
    expect(clients.every((client) => client.closed), isTrue);
    expect(failures, hasLength(2));
  });

  test(
    'connect timeout closes even a client whose request never opened',
    () async {
      final client = _Client(stallOpen: true);
      final result = await _probe([
        client,
      ], connectTimeout: const Duration(milliseconds: 20)).check();
      expect(result, isFalse);
      expect(client.forceClosed, isTrue);
    },
  );

  test('response timeout closes a connection waiting for headers', () async {
    final client = _Client();
    final result = await _probe([
      client,
    ], responseTimeout: const Duration(milliseconds: 20)).check();
    expect(result, isFalse);
    expect(client.forceClosed, isTrue);
  });

  test('independent races do not cancel each other', () async {
    final clients = List.generate(4, (_) => _Client());
    final probe = _probe(clients, endpointCount: 2);
    final first = probe.check();
    final second = probe.check();
    clients[0].respond(204);
    expect(await first, isTrue);
    expect(clients[2].closed, isFalse);
    expect(clients[3].closed, isFalse);
    clients[2].respond(204);
    expect(await second, isTrue);
    await Future<void>.delayed(Duration.zero);
    expect(clients.every((client) => client.closed), isTrue);
  });

  test('empty endpoint list opens no clients and reports false', () async {
    expect(await _probe(const []).check(), isFalse);
  });

  test(
    'overall deadline closes pending sockets rather than only timing out UI',
    () async {
      final clients = [_Client(), _Client(stallOpen: true)];
      final failures = <String>[];
      final probe = _probe(clients, failures: failures);
      expect(
        await probe.check(timeout: const Duration(milliseconds: 20)),
        isFalse,
      );
      expect(clients.every((client) => client.closed), isTrue);
      await Future<void>.delayed(Duration.zero);
      expect(failures, isEmpty);
    },
  );

  test(
    'owner cancellation synchronously closes clients and consumes late failures',
    () async {
      final clients = [_Client(), _Client(stallOpen: true)];
      final failures = <String>[];
      final probe = _probe(clients, failures: failures);
      final result = probe.check();
      await Future<void>.delayed(Duration.zero);
      probe.close();
      expect(clients.every((client) => client.closed), isTrue);
      expect(await result, isFalse);
      probe.close();
      expect(await probe.check(), isFalse);
      expect(failures, isEmpty);
    },
  );

  test('expired budget does not open new connections', () async {
    final client = _Client();
    expect(await _probe([client]).check(timeout: Duration.zero), isFalse);
    expect(client.uri, isNull);
  });

  test('real loopback proxy leaves no connections after success', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final sockets = <Socket>{};
    addTearDown(() async {
      for (final socket in sockets.toList()) {
        socket.destroy();
      }
      await server.close();
    });
    server.listen((socket) {
      sockets.add(socket);
      var request = '';
      var responded = false;
      void closed() {
        sockets.remove(socket);
        socket.destroy();
      }

      socket.listen(
        (bytes) {
          request += String.fromCharCodes(bytes);
          if (!responded &&
              request.contains('\r\n\r\n') &&
              request.contains('healthy.example.com')) {
            responded = true;
            // Send headers but deliberately leave the response body unfinished.
            socket.write(
              'HTTP/1.1 200 OK\r\nContent-Length: 9999\r\nConnection: keep-alive\r\n\r\nx',
            );
          }
        },
        onDone: closed,
        onError: (Object _) => closed(),
      );
    });
    final probe = LocalProxyHealthProbe(
      proxyPort: server.port,
      userAgent: 'YurichConnect/Test',
      endpoints: [
        (uri: Uri.http('healthy.example.com', '/check'), expectedStatus: 200),
        (uri: Uri.http('stalled.example.com', '/check'), expectedStatus: 200),
      ],
    );
    expect(await probe.check().timeout(const Duration(seconds: 2)), isTrue);
    final deadline = Stopwatch()..start();
    while (sockets.isNotEmpty && deadline.elapsedMilliseconds < 2000) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(sockets, isEmpty);
  });

  test('unexpected successful HTTP status is not a healthy probe', () async {
    final client = _Client();
    final result = _probe([client]).check();
    client.respond(200);
    expect(await result, isFalse);
  });
}
