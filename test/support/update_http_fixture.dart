import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

typedef UpdateReply =
    FutureOr<HttpClientResponse> Function(UpdateHttpRequest request);

/// No socket, DNS, TLS callback or real redirect handling.
final class UpdateHttpClient extends Fake implements HttpClient {
  UpdateHttpClient(this.reply, {this.beforeOpen});

  final UpdateReply reply;
  final FutureOr<void> Function(UpdateHttpRequest request)? beforeOpen;
  final requests = <UpdateHttpRequest>[];
  final closeCalls = <bool>[];

  @override
  Duration? connectionTimeout;

  @override
  String Function(Uri uri)? findProxy;

  @override
  void close({bool force = false}) => closeCalls.add(force);

  @override
  Future<HttpClientRequest> getUrl(Uri url) => _open('GET', url);

  @override
  Future<HttpClientRequest> headUrl(Uri url) => _open('HEAD', url);

  Future<HttpClientRequest> _open(String method, Uri uri) async {
    if (closeCalls.isNotEmpty) throw StateError('HTTP fixture is closed');
    final request = UpdateHttpRequest(method, uri, reply);
    requests.add(request);
    await beforeOpen?.call(request);
    return request;
  }
}

final class UpdateHttpRequest extends Fake implements HttpClientRequest {
  UpdateHttpRequest(this.method, this.uri, this._reply);

  @override
  final String method;

  @override
  final Uri uri;

  final UpdateReply _reply;
  var aborts = 0;
  var closes = 0;

  @override
  final headers = _Headers();

  @override
  bool followRedirects = true;

  @override
  Future<HttpClientResponse> close() async {
    closes++;
    return _reply(this);
  }

  @override
  void abort([Object? exception, StackTrace? stackTrace]) => aborts++;
}

final class _Headers extends Fake implements HttpHeaders {
  _Headers([Map<String, String> initial = const {}])
    : _values = {
        for (final entry in initial.entries)
          entry.key.toLowerCase(): entry.value,
      };

  final Map<String, String> _values;

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) =>
      _values[name.toLowerCase()] = value.toString();

  @override
  String? value(String name) => _values[name.toLowerCase()];
}

final class UpdateHttpResponse extends Stream<List<int>>
    implements HttpClientResponse {
  UpdateHttpResponse({
    this.statusCode = HttpStatus.ok,
    this.contentLength = -1,
    List<List<int>> chunks = const [],
    Map<String, String> headers = const {},
    List<Uri> redirectLocations = const [],
  }) : _chunks = chunks,
       headers = _Headers(headers),
       redirects = [
         for (final location in redirectLocations) _Redirect(location),
       ];

  UpdateHttpResponse.json(Object? value)
    : this(chunks: [utf8.encode(jsonEncode(value))]);

  @override
  final int statusCode;

  @override
  final int contentLength;

  @override
  final HttpHeaders headers;

  @override
  final List<RedirectInfo> redirects;

  final List<List<int>> _chunks;
  var drains = 0;
  var readChunks = 0;
  var _listened = false;

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
    if (_listened) throw StateError('Fixture response was read twice');
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

final class _Redirect extends Fake implements RedirectInfo {
  _Redirect(this.location);

  @override
  final Uri location;
}
