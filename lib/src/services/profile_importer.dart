import 'dart:convert';
import 'dart:io';

import '../models/vpn_profile.dart';
import 'sing_box_config_builder.dart';

class ProfileImportException implements Exception {
  const ProfileImportException(this.message);

  final String message;

  @override
  String toString() => message;
}

class _FetchedSubscription {
  const _FetchedSubscription({required this.body, this.expiresAt});

  final String body;
  final DateTime? expiresAt;
}

class ProfileImporter {
  static final _linkPattern = RegExp(
    "(?:vless://|naive\\+https://|naive://|hy2://|hysteria2://|hysteria://)[^\\s<>\"']+",
    caseSensitive: false,
  );

  Future<List<VpnProfile>> importFromText(String input) async {
    final text = input.trim();
    if (text.isEmpty) {
      throw const ProfileImportException('Вставь ссылку, подписку или JSON.');
    }

    final uri = Uri.tryParse(text);
    if (uri != null && (uri.scheme == 'http' || uri.scheme == 'https')) {
      final fetched = await _fetchSubscription(uri);
      return _parsePayload(
        fetched.body,
        source: text,
        subscriptionExpiresAt: fetched.expiresAt,
      );
    }

    return _parsePayload(text, source: text);
  }

  Future<_FetchedSubscription> _fetchSubscription(Uri uri) async {
    final clients = [
      'sing-box/1.13.11 (Android; YurichConnect)',
      'HiddifyNext/2.5.7',
      'v2rayNG/1.10.5',
    ];

    Object? lastError;
    final uris = _subscriptionCandidates(uri);
    final candidates = <String>[];
    for (final userAgent in clients) {
      for (final candidateUri in uris) {
        for (final viaLocalProxy in const [false, true]) {
          try {
            final fetched = await _get(
              candidateUri,
              userAgent: userAgent,
              viaLocalProxy: viaLocalProxy,
            );
            final body = fetched.body;
            if (_canParsePayload(body)) {
              return fetched;
            }
            if (_looksLikeHtml(body)) {
              lastError = ProfileImportException(
                '${_fetchModeLabel(viaLocalProxy)} ${candidateUri.path}: сервер вернул HTML-страницу без поддерживаемых ключей.',
              );
              continue;
            }
            candidates.add(body);
          } on Object catch (error) {
            lastError = ProfileImportException(
              '${_fetchModeLabel(viaLocalProxy)} ${candidateUri.path}: $error',
            );
          }
        }
      }
    }

    if (candidates.isNotEmpty) {
      return _FetchedSubscription(body: candidates.first);
    }

    throw ProfileImportException(
      'Не смог получить raw-подписку. Проверь, что в Remnawave включён Base64/Xray-json/Sing-box template. Деталь: $lastError',
    );
  }

  List<Uri> _subscriptionCandidates(Uri uri) {
    final result = <Uri>[];
    void add(Uri candidate) {
      if (!result.any((item) => item.toString() == candidate.toString())) {
        result.add(candidate);
      }
    }

    add(uri);
    final path = uri.path;
    final lowerPath = path.toLowerCase();
    final looksLikeRootSubscription =
        lowerPath.contains('/s/') && !lowerPath.endsWith('.txt');
    if (looksLikeRootSubscription) {
      final base = path.endsWith('/') ? uri : uri.replace(path: '$path/');
      for (final file in const [
        'links.txt',
        'hiddify.txt',
        'nekobox.txt',
        'v2rayng.txt',
      ]) {
        add(base.resolve(file));
      }
    }
    return result;
  }

  bool _canParsePayload(String body) {
    try {
      return _parsePayload(body, source: '').isNotEmpty;
    } on Object {
      return false;
    }
  }

  Future<_FetchedSubscription> _get(
    Uri uri, {
    required String userAgent,
    bool viaLocalProxy = false,
  }) async {
    final client = HttpClient()
      ..connectionTimeout = Duration(seconds: viaLocalProxy ? 8 : 12);
    if (viaLocalProxy) {
      client.findProxy = (_) =>
          'PROXY 127.0.0.1:${SingBoxConfigBuilder.localMixedProxyPort}';
    }
    try {
      final request = await client.getUrl(uri);
      request.headers.set(HttpHeaders.userAgentHeader, userAgent);
      request.headers.set(
        HttpHeaders.acceptHeader,
        'text/plain, application/json, */*',
      );
      request.followRedirects = true;

      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw ProfileImportException('HTTP ${response.statusCode}: $body');
      }
      return _FetchedSubscription(
        body: body,
        expiresAt: _subscriptionExpiresAtFromHeaders(response.headers),
      );
    } finally {
      client.close(force: true);
    }
  }

  String _fetchModeLabel(bool viaLocalProxy) {
    return viaLocalProxy ? 'fallback через активный VPN' : 'прямой запрос';
  }

  List<VpnProfile> _parsePayload(
    String payload, {
    required String source,
    DateTime? subscriptionExpiresAt,
  }) {
    final text = payload.trim();
    if (text.isEmpty) {
      throw const ProfileImportException('Подписка пустая.');
    }

    final detectedExpiresAt =
        subscriptionExpiresAt ?? _subscriptionExpiresAtFromPayload(text);

    final jsonProfile = _tryParseJsonConfig(text, source: source);
    if (jsonProfile != null) {
      return _withSubscriptionMetadata(
        [jsonProfile],
        detectedExpiresAt,
        source,
      );
    }

    final jsonLinks = _tryParseJsonLinks(text);
    if (jsonLinks.isNotEmpty) {
      return _withSubscriptionMetadata(jsonLinks, detectedExpiresAt, source);
    }

    final xrayProfiles = _tryParseXrayConfigs(text);
    if (xrayProfiles.isNotEmpty) {
      return _withSubscriptionMetadata(xrayProfiles, detectedExpiresAt, source);
    }

    final links = _extractLinks(text);
    if (links.isNotEmpty) {
      return _withSubscriptionMetadata(
        _profilesFromLinks(links),
        detectedExpiresAt,
        source,
      );
    }

    final decoded = _tryDecodeBase64(text);
    if (decoded != null) {
      final decodedExpiresAt =
          detectedExpiresAt ?? _subscriptionExpiresAtFromPayload(decoded);

      final decodedJsonProfile = _tryParseJsonConfig(decoded, source: source);
      if (decodedJsonProfile != null) {
        return _withSubscriptionMetadata(
          [decodedJsonProfile],
          decodedExpiresAt,
          source,
        );
      }

      final decodedJsonLinks = _tryParseJsonLinks(decoded);
      if (decodedJsonLinks.isNotEmpty) {
        return _withSubscriptionMetadata(
          decodedJsonLinks,
          decodedExpiresAt,
          source,
        );
      }

      final decodedXrayProfiles = _tryParseXrayConfigs(decoded);
      if (decodedXrayProfiles.isNotEmpty) {
        return _withSubscriptionMetadata(
          decodedXrayProfiles,
          decodedExpiresAt,
          source,
        );
      }

      final decodedLinks = _extractLinks(decoded);
      if (decodedLinks.isNotEmpty) {
        return _withSubscriptionMetadata(
          _profilesFromLinks(decodedLinks),
          decodedExpiresAt,
          source,
        );
      }
    }

    if (_looksLikeHtml(text)) {
      throw const ProfileImportException(
        'Это HTML-страница подписки. Нужна raw-подписка или включённые raw keys в Remnawave.',
      );
    }

    throw const ProfileImportException(
      'Не нашёл поддерживаемых ссылок. Поддерживаются vless://, naive+https://, hy2://, hysteria://, sing-box JSON и raw-подписки.',
    );
  }

  DateTime? _subscriptionExpiresAtFromHeaders(HttpHeaders headers) {
    final values = <String>[
      ...?headers['subscription-userinfo'],
      ...?headers['subscription-user-info'],
      ...?headers['x-subscription-userinfo'],
    ];

    for (final value in values) {
      final expiresAt = _subscriptionExpiresAtFromText(value);
      if (expiresAt != null) {
        return expiresAt;
      }
    }
    return null;
  }

  DateTime? _subscriptionExpiresAtFromPayload(String text) {
    final direct = _subscriptionExpiresAtFromText(text);
    if (direct != null) {
      return direct;
    }

    try {
      return _subscriptionExpiresAtFromJson(jsonDecode(text));
    } on FormatException {
      return null;
    }
  }

  DateTime? _subscriptionExpiresAtFromJson(Object? value) {
    if (value is Map) {
      for (final entry in value.entries) {
        final key = entry.key.toString().toLowerCase();
        if (const {
          'expire',
          'expires',
          'expiry',
          'expiresat',
          'expires_at',
          'expired_at',
          'subscription_expires_at',
        }.contains(key)) {
          final parsed = _parseSubscriptionDate(entry.value);
          if (parsed != null) {
            return parsed;
          }
        }
      }

      for (final entry in value.entries) {
        final parsed = _subscriptionExpiresAtFromJson(entry.value);
        if (parsed != null) {
          return parsed;
        }
      }
    }

    if (value is List) {
      for (final item in value) {
        final parsed = _subscriptionExpiresAtFromJson(item);
        if (parsed != null) {
          return parsed;
        }
      }
    }

    return null;
  }

  DateTime? _subscriptionExpiresAtFromText(String value) {
    final expireMatch = RegExp(
      r'(?:^|[;,\s&?])(?:expire|expires|expiry|expires_at)=([^;,\s&]+)',
      caseSensitive: false,
    ).firstMatch(value);
    if (expireMatch != null) {
      return _parseSubscriptionDate(Uri.decodeComponent(expireMatch.group(1)!));
    }

    return null;
  }

  DateTime? _parseSubscriptionDate(Object? value) {
    if (value == null) {
      return null;
    }

    if (value is DateTime) {
      return value.toUtc();
    }

    if (value is int) {
      return _dateTimeFromTimestamp(value);
    }

    if (value is double) {
      return _dateTimeFromTimestamp(value.round());
    }

    final text = value.toString().trim();
    if (text.isEmpty || text == '0') {
      return null;
    }

    final numeric = int.tryParse(text);
    if (numeric != null) {
      return _dateTimeFromTimestamp(numeric);
    }

    return DateTime.tryParse(text)?.toUtc();
  }

  DateTime _dateTimeFromTimestamp(int value) {
    final milliseconds = value > 9999999999 ? value : value * 1000;
    return DateTime.fromMillisecondsSinceEpoch(milliseconds, isUtc: true);
  }

  List<VpnProfile> _withSubscriptionMetadata(
    List<VpnProfile> profiles,
    DateTime? expiresAt,
    String source,
  ) {
    final subscriptionSource = _isHttpSource(source) ? source : null;
    final nameExpiresAt = [
      for (final profile in profiles)
        _subscriptionExpiresAtFromName(profile.name),
    ];
    final fallbackExpiresAt =
        expiresAt ?? _fallbackSubscriptionExpiresAt(nameExpiresAt);
    if (fallbackExpiresAt == null && subscriptionSource == null) {
      return profiles;
    }

    return [
      for (var index = 0; index < profiles.length; index += 1)
        profiles[index].copyWith(
          subscriptionExpiresAt:
              expiresAt ?? nameExpiresAt[index] ?? fallbackExpiresAt,
          subscriptionSource: subscriptionSource,
        ),
    ];
  }

  bool _isHttpSource(String source) {
    final uri = Uri.tryParse(source.trim());
    return uri != null && (uri.scheme == 'http' || uri.scheme == 'https');
  }

  DateTime? _subscriptionExpiresAtFromName(String name) {
    final dayFirstMatch = RegExp(
      r'(?:до|until|expire|expires|expiry)\s*[:=\-]?\s*(\d{1,2})[.\-/](\d{1,2})[.\-/](\d{2,4})',
      caseSensitive: false,
    ).firstMatch(name);
    if (dayFirstMatch != null) {
      return _subscriptionDateFromParts(
        day: dayFirstMatch.group(1)!,
        month: dayFirstMatch.group(2)!,
        year: dayFirstMatch.group(3)!,
      );
    }

    final yearFirstMatch = RegExp(
      r'(?:до|until|expire|expires|expiry)\s*[:=\-]?\s*(\d{4})[.\-/](\d{1,2})[.\-/](\d{1,2})',
      caseSensitive: false,
    ).firstMatch(name);
    if (yearFirstMatch == null) {
      return null;
    }

    return _subscriptionDateFromParts(
      day: yearFirstMatch.group(3)!,
      month: yearFirstMatch.group(2)!,
      year: yearFirstMatch.group(1)!,
    );
  }

  DateTime? _fallbackSubscriptionExpiresAt(List<DateTime?> values) {
    final dates = values.whereType<DateTime>().toList();
    if (dates.isEmpty) {
      return null;
    }
    dates.sort();
    return dates.first;
  }

  DateTime? _subscriptionDateFromParts({
    required String day,
    required String month,
    required String year,
  }) {
    final parsedDay = int.tryParse(day);
    final parsedMonth = int.tryParse(month);
    final rawYear = int.tryParse(year);
    if (parsedDay == null || parsedMonth == null || rawYear == null) {
      return null;
    }

    return _subscriptionDateFromNumbers(
      day: parsedDay,
      month: parsedMonth,
      rawYear: rawYear,
    );
  }

  DateTime? _subscriptionDateFromNumbers({
    required int day,
    required int month,
    required int rawYear,
  }) {
    final year = rawYear < 100 ? 2000 + rawYear : rawYear;
    if (month < 1 || month > 12 || day < 1 || day > 31) {
      return null;
    }

    final localEndOfDay = DateTime(year, month, day, 23, 59, 59);
    if (localEndOfDay.day != day || localEndOfDay.month != month) {
      return null;
    }
    return localEndOfDay.toUtc();
  }

  VpnProfile? _tryParseJsonConfig(String text, {required String source}) {
    try {
      final decoded = jsonDecode(text);
      if (decoded is Map<String, dynamic>) {
        if (decoded.containsKey('inbounds') &&
            decoded.containsKey('outbounds')) {
          return VpnProfile(
            id: _stableId(text),
            name: 'Sing-box config',
            kind: VpnProfileKind.singBoxConfig,
            originalInput: source,
            rawConfig: const JsonEncoder.withIndent('  ').convert(decoded),
          );
        }

        final outboundProfile = _profileFromSingBoxOutbound(
          decoded,
          originalText: text,
          source: source,
        );
        if (outboundProfile != null) {
          return outboundProfile;
        }
      }
    } on FormatException {
      return null;
    }

    return null;
  }

  VpnProfile? _profileFromSingBoxOutbound(
    Map<String, dynamic> outbound, {
    required String originalText,
    required String source,
  }) {
    final type = (outbound['type'] as String?)?.toLowerCase();
    final server = outbound['server'] as String?;
    if (type == null || server == null || server.isEmpty) {
      return null;
    }

    final port =
        _asInt(outbound['server_port']) ?? _asInt(outbound['port']) ?? 443;
    final normalized = jsonDecode(jsonEncode(outbound)) as Map<String, dynamic>;
    normalized['server_port'] = port;

    if (type == 'http' || type == 'naive') {
      return VpnProfile(
        id: _stableId(originalText),
        name: _displayName('', fallback: server),
        kind: VpnProfileKind.naive,
        originalInput: source.isEmpty ? originalText : source,
        server: server,
        port: port,
        outbound: normalized,
      );
    }

    if (type == 'vless') {
      final tls = _asMap(normalized['tls']);
      final reality = _asMap(tls?['reality']);
      final hasReality =
          reality != null &&
          (reality['enabled'] == true || _truthy('${reality['enabled']}'));
      final transportType =
          (_asMap(normalized['transport'])?['type'] as String?)?.toLowerCase();
      return VpnProfile(
        id: _stableId(originalText),
        name: _displayName('', fallback: server),
        kind: _vlessKind(
          security: hasReality ? 'reality' : 'tls',
          transportType: transportType,
        ),
        originalInput: source.isEmpty ? originalText : source,
        server: server,
        port: port,
        outbound: normalized,
      );
    }

    if (type == 'hysteria2' || type == 'hysteria') {
      return VpnProfile(
        id: _stableId(originalText),
        name: _displayName('', fallback: server),
        kind: type == 'hysteria2'
            ? VpnProfileKind.hysteria2
            : VpnProfileKind.hysteria,
        originalInput: source.isEmpty ? originalText : source,
        server: server,
        port: port,
        outbound: normalized,
      );
    }

    return null;
  }

  List<VpnProfile> _tryParseJsonLinks(String text) {
    try {
      final decoded = jsonDecode(text);
      if (decoded is Map<String, dynamic>) {
        final links = decoded['links'];
        if (links is List) {
          return _profilesFromLinks(links.whereType<String>().toList());
        }
      }
      if (decoded is List) {
        return _profilesFromLinks(decoded.whereType<String>().toList());
      }
    } on FormatException {
      return const [];
    }
    return const [];
  }

  List<VpnProfile> _tryParseXrayConfigs(String text) {
    try {
      final decoded = jsonDecode(text);
      final configs = switch (decoded) {
        Map() => [decoded.cast<String, dynamic>()],
        List() =>
          decoded
              .whereType<Map>()
              .map((item) => item.cast<String, dynamic>())
              .toList(),
        _ => const <Map<String, dynamic>>[],
      };

      final profiles = <VpnProfile>[];
      for (final config in configs) {
        final outbounds = config['outbounds'];
        if (outbounds is! List) {
          continue;
        }

        for (final item in outbounds.whereType<Map>()) {
          final outbound = item.cast<String, dynamic>();
          if ((outbound['protocol'] as String?)?.toLowerCase() == 'vless') {
            profiles.add(_profileFromXrayVless(config, outbound));
          }
        }
      }
      return profiles;
    } on FormatException {
      return const [];
    } on ProfileImportException {
      return const [];
    }
  }

  VpnProfile _profileFromXrayVless(
    Map<String, dynamic> config,
    Map<String, dynamic> outbound,
  ) {
    final settings = _asMap(outbound['settings']);
    if (settings == null) {
      throw const ProfileImportException('Xray VLESS outbound без settings.');
    }
    final vnext = settings['vnext'];
    final server = vnext is List && vnext.isNotEmpty
        ? _asMap(vnext.first)
        : null;
    if (server == null) {
      throw const ProfileImportException('Xray VLESS outbound без vnext.');
    }

    final users = server['users'];
    final user = users is List && users.isNotEmpty ? _asMap(users.first) : null;
    final uuid = user?['id'] as String?;
    final address = server['address'] as String?;
    final port = _asInt(server['port']) ?? 443;
    if (uuid == null || uuid.isEmpty || address == null || address.isEmpty) {
      throw const ProfileImportException('Xray VLESS outbound без UUID/host.');
    }

    final stream = _asMap(outbound['streamSettings']) ?? const {};
    final network = (stream['network'] as String?) ?? 'tcp';
    final security = (stream['security'] as String?) ?? 'none';
    final reality = _asMap(stream['realitySettings']);
    final tls = _asMap(stream['tlsSettings']);
    final name = (config['remarks'] as String?) ?? address;

    final query = <String, String>{
      'encryption': (user?['encryption'] as String?) ?? 'none',
      'type': network,
      'security': security,
      if ((user?['flow'] as String?)?.isNotEmpty ?? false)
        'flow': user!['flow'] as String,
      if (reality != null &&
          (reality['serverName'] as String?)?.isNotEmpty == true)
        'sni': reality['serverName'] as String,
      if (tls != null && (tls['serverName'] as String?)?.isNotEmpty == true)
        'sni': tls['serverName'] as String,
      if (reality != null &&
          (reality['fingerprint'] as String?)?.isNotEmpty == true)
        'fp': reality['fingerprint'] as String,
      if (reality != null &&
          (reality['publicKey'] as String?)?.isNotEmpty == true)
        'pbk': reality['publicKey'] as String,
      if (reality != null &&
          (reality['shortId'] as String?)?.isNotEmpty == true)
        'sid': reality['shortId'] as String,
      if (_asMap(stream['xhttpSettings'])?['path'] is String)
        'path': _asMap(stream['xhttpSettings'])!['path'] as String,
      if (_asMap(stream['splitHTTPSettings'])?['path'] is String)
        'path': _asMap(stream['splitHTTPSettings'])!['path'] as String,
      if (_asMap(stream['kcpSettings'])?['header'] is Map)
        'headerType':
            ((_asMap(stream['kcpSettings'])!['header'] as Map)['type']
                as String?) ??
            '',
    };

    final alpn = reality?['alpn'] ?? tls?['alpn'];
    final alpnValue = _listOrString(alpn);
    if (alpnValue.isNotEmpty) {
      query['alpn'] = alpnValue;
    }

    final uri = Uri(
      scheme: 'vless',
      userInfo: uuid,
      host: address,
      port: port,
      queryParameters: query,
      fragment: name,
    );
    return _parseVless(uri.toString());
  }

  List<String> _extractLinks(String text) {
    return _linkPattern
        .allMatches(text)
        .map((match) => match.group(0)!)
        .map(_cleanLink)
        .toSet()
        .toList();
  }

  List<VpnProfile> _profilesFromLinks(List<String> links) {
    final profiles = <VpnProfile>[];
    final errors = <String>[];

    for (final link in links) {
      try {
        final lower = link.toLowerCase();
        if (lower.startsWith('vless://')) {
          profiles.add(_parseVless(link));
        } else if (lower.startsWith('naive+https://') ||
            lower.startsWith('naive://')) {
          profiles.add(_parseNaive(link));
        } else if (lower.startsWith('hy2://') ||
            lower.startsWith('hysteria2://')) {
          profiles.add(_parseHysteria2(link));
        } else if (lower.startsWith('hysteria://')) {
          profiles.add(_parseHysteria(link));
        }
      } on Object catch (error) {
        errors.add('$link: $error');
      }
    }

    if (profiles.isEmpty && errors.isNotEmpty) {
      throw ProfileImportException(errors.join('\n'));
    }
    return profiles;
  }

  VpnProfile _parseVless(String link) {
    final uri = Uri.parse(link);
    final uuid = Uri.decodeComponent(uri.userInfo);
    if (uuid.isEmpty || uri.host.isEmpty) {
      throw const ProfileImportException('VLESS ссылка без UUID или host.');
    }

    final query = _query(uri);
    final security = (query['security'] ?? '').toLowerCase();
    final transportType = _vlessTransportType(query);
    final unsupportedTransport = _unsupportedVlessTransport(transportType);
    final port = uri.hasPort ? uri.port : 443;
    final name = _displayName(uri.fragment, fallback: uri.host);
    final tls = <String, dynamic>{};

    if (security == 'reality' || security == 'tls') {
      tls['enabled'] = true;
      final sni = query['sni'] ?? query['peer'] ?? query['host'] ?? uri.host;
      if (sni.isNotEmpty) {
        tls['server_name'] = sni;
      }

      final alpn = _csv(query['alpn']);
      if (alpn.isNotEmpty) {
        tls['alpn'] = alpn;
      }

      if (_truthy(query['allowInsecure']) || _truthy(query['insecure'])) {
        tls['insecure'] = true;
      }

      final fingerprint = query['fp'] ?? query['fingerprint'];
      if (fingerprint != null && fingerprint.isNotEmpty) {
        tls['utls'] = {'enabled': true, 'fingerprint': fingerprint};
      }

      if (security == 'reality') {
        final publicKey = query['pbk'] ?? query['publicKey'];
        if (publicKey == null || publicKey.isEmpty) {
          throw const ProfileImportException(
            'Reality ссылка без pbk/publicKey.',
          );
        }
        tls['reality'] = {
          'enabled': true,
          'public_key': publicKey,
          if ((query['sid'] ?? '').isNotEmpty) 'short_id': query['sid'],
        };
      }
    }

    final outbound = <String, dynamic>{
      'type': 'vless',
      'tag': 'proxy',
      'server': uri.host,
      'server_port': port,
      'uuid': uuid,
      if ((query['flow'] ?? '').isNotEmpty) 'flow': query['flow'],
      'packet_encoding': _vlessPacketEncoding(query),
      if (tls.isNotEmpty) 'tls': tls,
    };

    if (unsupportedTransport != null) {
      outbound['unsupported_transport'] = unsupportedTransport;
      outbound['transport_options'] = _unsupportedTransportOptions(query);
    } else {
      final transport = _v2rayTransport(query);
      if (transport != null) {
        outbound['transport'] = transport;
      }
    }

    return VpnProfile(
      id: _stableId(link),
      name: name,
      kind: _vlessKind(security: security, transportType: transportType),
      originalInput: link,
      server: uri.host,
      port: port,
      outbound: outbound,
    );
  }

  VpnProfile _parseNaive(String link) {
    final normalized = link.toLowerCase().startsWith('naive+')
        ? link.substring('naive+'.length)
        : link;
    final uri = Uri.parse(normalized);
    if (uri.host.isEmpty) {
      throw const ProfileImportException('Naive ссылка без host.');
    }

    final userParts = uri.userInfo.split(':');
    final username = userParts.isNotEmpty
        ? Uri.decodeComponent(userParts.first)
        : '';
    final password = userParts.length > 1
        ? Uri.decodeComponent(userParts.sublist(1).join(':'))
        : '';
    final query = _query(uri);
    final port = uri.hasPort ? uri.port : 443;
    final tls = <String, dynamic>{
      'enabled': true,
      'server_name': query['sni'] ?? uri.host,
    };

    final outbound = <String, dynamic>{
      'type': 'naive',
      'tag': 'proxy',
      'server': uri.host,
      'server_port': port,
      if (username.isNotEmpty) 'username': username,
      if (password.isNotEmpty) 'password': password,
      'tls': tls,
      if (_truthy(query['quic'])) 'quic': true,
      if ((query['quic_congestion_control'] ?? '').isNotEmpty)
        'quic_congestion_control': query['quic_congestion_control'],
    };

    return VpnProfile(
      id: _stableId(link),
      name: _displayName(uri.fragment, fallback: uri.host),
      kind: VpnProfileKind.naive,
      originalInput: link,
      server: uri.host,
      port: port,
      outbound: outbound,
    );
  }

  VpnProfile _parseHysteria2(String link) {
    final uri = Uri.parse(link);
    final query = _query(uri);
    final password =
        query['password'] ??
        query['auth'] ??
        query['auth_str'] ??
        Uri.decodeComponent(uri.userInfo);
    if (password.isEmpty || uri.host.isEmpty) {
      throw const ProfileImportException(
        'Hysteria2 ссылка без пароля или host.',
      );
    }

    final port = uri.hasPort ? uri.port : 443;
    final tls = _tlsFromQuery(query, fallbackServerName: uri.host);
    final outbound = <String, dynamic>{
      'type': 'hysteria2',
      'tag': 'proxy',
      'server': uri.host,
      'server_port': port,
      'password': password,
      if (_positiveInt(query, const ['upmbps', 'up_mbps', 'up']) != null)
        'up_mbps': _positiveInt(query, const ['upmbps', 'up_mbps', 'up']),
      if (_positiveInt(query, const ['downmbps', 'down_mbps', 'down']) != null)
        'down_mbps': _positiveInt(query, const [
          'downmbps',
          'down_mbps',
          'down',
        ]),
      if ((query['network'] ?? '').isNotEmpty) 'network': query['network'],
      if (tls.isNotEmpty) 'tls': tls,
    };

    final obfs = query['obfs'] ?? query['obfsType'] ?? query['obfs_type'];
    final obfsPassword =
        query['obfs-password'] ??
        query['obfs_password'] ??
        query['obfsPassword'];
    if (obfs != null && obfs.isNotEmpty) {
      outbound['obfs'] = {
        'type': obfs,
        if (obfsPassword != null && obfsPassword.isNotEmpty)
          'password': obfsPassword,
      };
    }

    return VpnProfile(
      id: _stableId(link),
      name: _displayName(uri.fragment, fallback: uri.host),
      kind: VpnProfileKind.hysteria2,
      originalInput: link,
      server: uri.host,
      port: port,
      outbound: outbound,
    );
  }

  VpnProfile _parseHysteria(String link) {
    final uri = Uri.parse(link);
    if (uri.host.isEmpty) {
      throw const ProfileImportException('Hysteria ссылка без host.');
    }

    final query = _query(uri);
    final port = uri.hasPort ? uri.port : 443;
    final auth =
        query['auth_str'] ??
        query['authstr'] ??
        query['auth'] ??
        Uri.decodeComponent(uri.userInfo);
    final obfs = query['obfs'];
    final tls = _tlsFromQuery(query, fallbackServerName: uri.host);
    final outbound = <String, dynamic>{
      'type': 'hysteria',
      'tag': 'proxy',
      'server': uri.host,
      'server_port': port,
      'up_mbps': _positiveInt(query, const ['upmbps', 'up_mbps', 'up']) ?? 100,
      'down_mbps':
          _positiveInt(query, const ['downmbps', 'down_mbps', 'down']) ?? 100,
      if (obfs != null && obfs.isNotEmpty) 'obfs': obfs,
      if (auth.isNotEmpty) 'auth_str': auth,
      if ((query['protocol'] ?? query['network'] ?? '').isNotEmpty)
        'network': query['protocol'] ?? query['network'],
      if (tls.isNotEmpty) 'tls': tls,
    };

    return VpnProfile(
      id: _stableId(link),
      name: _displayName(uri.fragment, fallback: uri.host),
      kind: VpnProfileKind.hysteria,
      originalInput: link,
      server: uri.host,
      port: port,
      outbound: outbound,
    );
  }

  Map<String, dynamic> _tlsFromQuery(
    Map<String, String> query, {
    required String fallbackServerName,
  }) {
    final tls = <String, dynamic>{'enabled': true};
    final serverName =
        query['sni'] ?? query['peer'] ?? query['host'] ?? fallbackServerName;
    if (serverName.isNotEmpty) {
      tls['server_name'] = serverName;
    }

    final alpn = _csv(query['alpn']);
    if (alpn.isNotEmpty) {
      tls['alpn'] = alpn;
    }

    if (_truthy(query['allowInsecure']) || _truthy(query['insecure'])) {
      tls['insecure'] = true;
    }
    return tls;
  }

  Map<String, String> _query(Uri uri) {
    return uri.queryParameters.map(
      (key, value) => MapEntry(key, Uri.decodeComponent(value)),
    );
  }

  Map<String, dynamic>? _v2rayTransport(Map<String, String> query) {
    final type = _vlessTransportType(query);
    if (type == 'tcp' || type.isEmpty) {
      return null;
    }

    if (type == 'ws') {
      final headers = <String, String>{};
      final host = query['host'];
      if (host != null && host.isNotEmpty) {
        headers['Host'] = host;
      }
      return {
        'type': 'ws',
        if ((query['path'] ?? '').isNotEmpty) 'path': query['path'],
        if (headers.isNotEmpty) 'headers': headers,
      };
    }

    if (type == 'grpc') {
      return {
        'type': 'grpc',
        if ((query['serviceName'] ?? query['service_name'] ?? '').isNotEmpty)
          'service_name': query['serviceName'] ?? query['service_name'],
      };
    }

    if (type == 'http' || type == 'h2') {
      return {
        'type': 'http',
        if ((query['host'] ?? '').isNotEmpty) 'host': _csv(query['host']),
        if ((query['path'] ?? '').isNotEmpty) 'path': query['path'],
      };
    }

    if (type == 'httpupgrade') {
      final headers = <String, String>{};
      final host = query['host'];
      if (host != null && host.isNotEmpty) {
        headers['Host'] = host;
      }
      return {
        'type': 'httpupgrade',
        if ((query['path'] ?? '').isNotEmpty) 'path': query['path'],
        if (headers.isNotEmpty) 'headers': headers,
      };
    }

    if (type == 'quic') {
      return {'type': 'quic'};
    }

    throw ProfileImportException('Transport "$type" пока не поддержан.');
  }

  VpnProfileKind _vlessKind({
    required String security,
    required String? transportType,
  }) {
    final type = (transportType ?? 'tcp').toLowerCase();
    if (type == 'xhttp' || type == 'splithttp') {
      return VpnProfileKind.vlessXhttp;
    }
    if (type == 'mkcp' || type == 'kcp') {
      return VpnProfileKind.vlessMkcp;
    }
    return security == 'reality'
        ? VpnProfileKind.vlessReality
        : VpnProfileKind.vlessTls;
  }

  String _vlessTransportType(Map<String, String> query) {
    return (query['type'] ?? query['transport'] ?? 'tcp').trim().toLowerCase();
  }

  String? _unsupportedVlessTransport(String type) {
    if (type == 'xhttp' || type == 'splithttp') {
      return 'xhttp';
    }
    if (type == 'mkcp' || type == 'kcp') {
      return 'mkcp';
    }
    return null;
  }

  Map<String, dynamic> _unsupportedTransportOptions(Map<String, String> query) {
    final entries = <String, dynamic>{};
    for (final key in const [
      'type',
      'transport',
      'host',
      'path',
      'mode',
      'headerType',
      'seed',
      'xhttpMode',
      'xmux',
      'extra',
    ]) {
      final value = query[key];
      if (value != null && value.isNotEmpty) {
        entries[key] = value;
      }
    }
    return entries;
  }

  String _vlessPacketEncoding(Map<String, String> query) {
    final value =
        query['packetEncoding'] ??
        query['packet_encoding'] ??
        query['packet'] ??
        query['packet_encoding'];
    if (value == null || value.trim().isEmpty) {
      return 'xudp';
    }
    return value.trim();
  }

  String? _tryDecodeBase64(String text) {
    final compact = text.replaceAll(RegExp(r'\s+'), '');
    if (compact.length < 8 ||
        !RegExp(r'^[A-Za-z0-9+/=_-]+$').hasMatch(compact)) {
      return null;
    }

    var normalized = compact.replaceAll('-', '+').replaceAll('_', '/');
    while (normalized.length % 4 != 0) {
      normalized += '=';
    }

    try {
      return utf8.decode(base64.decode(normalized), allowMalformed: true);
    } on FormatException {
      return null;
    }
  }

  bool _looksLikeHtml(String text) {
    final lower = text.trimLeft().toLowerCase();
    return lower.startsWith('<!doctype html') ||
        lower.startsWith('<html') ||
        lower.contains('<body') ||
        lower.contains('<script');
  }

  String _cleanLink(String link) {
    return link
        .replaceAll('&amp;', '&')
        .replaceAll('&#38;', '&')
        .replaceAll('&quot;', '"')
        .replaceAll('&#34;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll(r'\u0026', '&')
        .replaceAll(RegExp(r'[)\],;]+$'), '');
  }

  String _displayName(String fragment, {required String fallback}) {
    if (fragment.isEmpty) {
      return fallback;
    }
    return Uri.decodeComponent(fragment).trim().isEmpty
        ? fallback
        : Uri.decodeComponent(fragment).trim();
  }

  List<String> _csv(String? value) {
    if (value == null || value.trim().isEmpty) {
      return const [];
    }
    return value
        .split(',')
        .map((part) => part.trim())
        .where((part) => part.isNotEmpty)
        .toList();
  }

  bool _truthy(String? value) {
    if (value == null) {
      return false;
    }
    return const {'1', 'true', 'yes', 'on'}.contains(value.toLowerCase());
  }

  Map<String, dynamic>? _asMap(Object? value) {
    return value is Map ? value.cast<String, dynamic>() : null;
  }

  int? _asInt(Object? value) {
    return switch (value) {
      int() => value,
      String() => int.tryParse(value),
      _ => null,
    };
  }

  int? _positiveInt(Map<String, String> query, List<String> keys) {
    for (final key in keys) {
      final value = int.tryParse(query[key] ?? '');
      if (value != null && value > 0) {
        return value;
      }
    }
    return null;
  }

  String _listOrString(Object? value) {
    return switch (value) {
      String() => value,
      List() => value.whereType<String>().join(','),
      _ => '',
    };
  }

  String _stableId(String value) {
    var hash = 0x811c9dc5;
    for (final codeUnit in value.codeUnits) {
      hash ^= codeUnit;
      hash = (hash * 0x01000193) & 0xffffffff;
    }
    return hash.toRadixString(16).padLeft(8, '0');
  }
}
