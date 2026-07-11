final class SensitiveDataRedactor {
  const SensitiveDataRedactor._();

  static final _httpUrl = RegExp(
    r'''https?://[^\s<>"']+''',
    caseSensitive: false,
  );
  static final _sensitiveQueryKey = RegExp(
    r'^(?:access_?token|api_?key|auth|authorization|key|password|secret|token|uuid)$',
    caseSensitive: false,
  );
  static final _bearerToken = RegExp(
    r'bearer\s+[A-Za-z0-9._~+/-]+=*',
    caseSensitive: false,
  );
  static const _secretPathParents = {'s', 'sub', 'subscribe', 'subscription'};

  static String redact(String value) {
    var result = value
        .replaceAllMapped(
          RegExp(
            r'(naive(?:\+https)?://)[^:@\s]+:[^@\s]+@',
            caseSensitive: false,
          ),
          (match) => '${match[1]}***:***@',
        )
        .replaceAllMapped(
          RegExp(r'(vless://)[^@\s]+@', caseSensitive: false),
          (match) => '${match[1]}***@',
        )
        .replaceAllMapped(
          RegExp(
            r'((?:hy2|hysteria2|hysteria|pingtunnel)://)[^@\s]+@',
            caseSensitive: false,
          ),
          (match) => '${match[1]}***@',
        )
        .replaceAllMapped(
          RegExp(
            r'("(?:password|uuid|public_?key|short_?id|auth|auth_str|token|secret)"\s*:\s*")[^"]+',
            caseSensitive: false,
          ),
          (match) => '${match[1]}***',
        )
        .replaceAllMapped(_bearerToken, (_) => 'Bearer ***');

    result = result.replaceAllMapped(_httpUrl, (match) {
      final raw = match.group(0)!;
      return _redactHttpUrl(raw);
    });
    return result;
  }

  static String _redactHttpUrl(String raw) {
    final trailingMatch = RegExp(r'[),.;\]]+$').firstMatch(raw);
    final trailing = trailingMatch?.group(0) ?? '';
    final candidate = trailing.isEmpty
        ? raw
        : raw.substring(0, raw.length - trailing.length);
    final uri = Uri.tryParse(candidate);
    if (uri == null || !uri.hasAuthority) {
      return raw;
    }

    final segments = [...uri.pathSegments];
    for (var index = 1; index < segments.length; index += 1) {
      if (_secretPathParents.contains(segments[index - 1].toLowerCase())) {
        segments[index] = '***';
      }
    }
    final query = <String, String>{};
    for (final entry in uri.queryParameters.entries) {
      query[entry.key] = _sensitiveQueryKey.hasMatch(entry.key)
          ? '***'
          : entry.value;
    }

    final redacted = uri.replace(
      userInfo: uri.userInfo.isEmpty ? '' : '***:***',
      pathSegments: segments,
      queryParameters: uri.hasQuery ? query : null,
      fragment: uri.hasFragment ? '***' : null,
    );
    return '$redacted$trailing';
  }
}
