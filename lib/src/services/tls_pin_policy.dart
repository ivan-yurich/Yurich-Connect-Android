import 'dart:convert';

import '../models/vpn_profile.dart';

/// Never turn a declared, unsupported server pin into an unpinned connection.
/// Full certificate hashes and SPKI public-key hashes are not interchangeable.
abstract final class TlsPinPolicy {
  static const unsupportedPinMessage =
      'Профиль содержит неподдерживаемое закрепление TLS-сертификата. '
      'Подключение остановлено: проверка не будет пропущена. '
      'Получите совместимый профиль или сертификат у провайдера.';
  static const invalidPublicKeyPinMessage =
      'Некорректный SHA-256 публичного ключа TLS-сертификата.';
  static const _unsupportedKeys = {
    'pinsha256',
    'certificatesha256',
    'pinnedpeercertificatechainsha256',
    'pinnedpeercertificatesha256',
    'peerfingerprint',
  };
  static final _links = RegExp(
    "(?:vless://|naive\\+https://|naive://|hy2://|hysteria2://|hysteria://)[^\\s<>\"']+",
    caseSensitive: false,
  );

  static String _key(String key) {
    var value = key;
    for (var i = 0; i < 2 && value.contains('%'); i++) {
      try {
        final decoded = Uri.decodeComponent(value);
        if (decoded == value) break;
        value = decoded;
      } on FormatException {
        break;
      }
    }
    return value.toLowerCase().replaceAll(RegExp('[-_]'), '');
  }

  static String? uriError(Uri uri) {
    for (final name in uri.queryParametersAll.keys) {
      final key = _key(name);
      if (_unsupportedKeys.contains(key) ||
          key == 'certificatepublickeysha256') {
        // Presence matters, including empty or repeated values. No URI parser
        // in this app currently implements certificate/SPKI pin parameters.
        return unsupportedPinMessage;
      }
    }
    return null;
  }

  static String? profileError(VpnProfile profile) {
    final sourceError = inputError(profile.originalInput);
    if (sourceError != null) return sourceError;
    final outbound = profile.outbound;
    if (outbound != null) {
      final error = outboundError(
        outbound,
        disallowPublicKeyPin:
            profile.kind == VpnProfileKind.naive ||
            profile.kind == VpnProfileKind.vlessXhttp ||
            profile.kind == VpnProfileKind.vlessReality,
      );
      if (error != null) return error;
    }
    final raw = profile.rawConfig;
    return raw == null ? null : inputError(raw);
  }

  static void requireProfile(VpnProfile profile) {
    final error = profileError(profile);
    if (error != null) throw UnsupportedError(error);
  }

  static String? outboundError(
    Map<dynamic, dynamic> outbound, {
    bool disallowPublicKeyPin = false,
  }) {
    final tls = outbound['tls'];
    final type = outbound['type']?.toString().toLowerCase();
    if (tls is Map) {
      final reality = tls['reality'];
      final error = _tlsError(
        tls,
        disallowPublicKeyPin:
            disallowPublicKeyPin ||
            type == 'naive' ||
            (reality is Map && reality['enabled'] == true) ||
            (outbound['transport'] is Map &&
                outbound['transport']['type'] == 'xhttp'),
      );
      if (error != null) return error;
    }
    final stream = outbound['streamSettings'];
    if (stream is Map) {
      for (final key in ['tlsSettings', 'realitySettings']) {
        final settings = stream[key];
        if (settings is Map) {
          final error = _tlsError(settings, disallowPublicKeyPin: true);
          if (error != null) return error;
        }
      }
    }
    return null;
  }

  static String? _tlsError(Map tls, {required bool disallowPublicKeyPin}) {
    for (final entry in tls.entries) {
      final key = _key(entry.key.toString());
      if (_unsupportedKeys.contains(key)) return unsupportedPinMessage;
      if (key != 'certificatepublickeysha256') continue;
      // Only this exact JSON field is implemented by the current Go TLS core.
      if (entry.key != 'certificate_public_key_sha256') {
        return unsupportedPinMessage;
      }
      final value = entry.value;
      if (value == null || (value is List && value.isEmpty)) continue;
      final values = value is String ? [value] : value;
      if (values is! List || values.isEmpty) return invalidPublicKeyPinMessage;
      for (final pin in values) {
        if (pin is! String) return invalidPublicKeyPinMessage;
        try {
          final bytes = base64.decode(pin);
          if (bytes.length != 32 || base64.encode(bytes) != pin) {
            return invalidPublicKeyPinMessage;
          }
        } on FormatException {
          return invalidPublicKeyPinMessage;
        }
      }
      if (disallowPublicKeyPin) return unsupportedPinMessage;
    }
    return null;
  }

  static String? documentError(Object? document, {int depth = 0}) {
    if (depth > 6) return unsupportedPinMessage;
    if (document is List) {
      for (final item in document) {
        final error = item is String
            ? inputError(item, depth: depth + 1)
            : documentError(item, depth: depth + 1);
        if (error != null) return error;
      }
    } else if (document is Map) {
      final error = outboundError(document);
      if (error != null) return error;
      // Inspect structural config/profile wrappers, not arbitrary remarks,
      // headers or text that merely mentions a pin parameter.
      for (final key in [
        'outbounds',
        'outbound',
        'xray',
        'links',
        'profiles',
      ]) {
        if (!document.containsKey(key)) continue;
        final error = documentError(document[key], depth: depth + 1);
        if (error != null) return error;
      }
    }
    return null;
  }

  static String? inputError(String input, {int depth = 0}) {
    if (depth > 6 || input.length > 2 * 1024 * 1024) {
      return unsupportedPinMessage;
    }
    final text = input
        .trim()
        .replaceAll('&amp;', '&')
        .replaceAll('&#38;', '&')
        .replaceAll(r'\u0026', '&');
    if (text.isEmpty) return null;
    if (text.startsWith('{') || text.startsWith('[')) {
      try {
        return documentError(jsonDecode(text), depth: depth + 1);
      } on FormatException {
        return unsupportedPinMessage;
      }
    }
    // An actual URI is checked as a whole: URI-looking text inside its fragment
    // is a display name, not another connection or query string.
    final uri = Uri.tryParse(text);
    if (uri != null &&
        const {
          'vless',
          'hy2',
          'hysteria2',
          'hysteria',
          'naive',
          'naive+https',
        }.contains(uri.scheme.toLowerCase())) {
      return uriError(uri);
    }
    for (final match in _links.allMatches(text)) {
      final link = Uri.tryParse(match.group(0)!);
      if (link == null) return unsupportedPinMessage;
      final error = uriError(link);
      if (error != null) return error;
    }
    if (text.length >= 16 && RegExp(r'^[A-Za-z0-9+/=_\s-]+$').hasMatch(text)) {
      try {
        final decoded = utf8.decode(
          base64.decode(base64.normalize(text.replaceAll(RegExp(r'\s'), ''))),
        );
        if (decoded != text) return inputError(decoded, depth: depth + 1);
      } on FormatException {
        // A label that is not encoded profile data has no TLS semantics.
      }
    }
    return null;
  }
}
