import 'dart:convert';

import 'package:aurum_vpn/src/services/tls_pin_policy.dart';
import 'package:flutter_test/flutter_test.dart';

const _profile = 'hy2://fixture-only@edge.example.invalid:443/';
const _pinned = '$_profile?pinSHA256=fixture-digest';

void main() {
  test('invalid UTF-8 in a preceding TLS key does not hide a declared pin', () {
    expect(
      TlsPinPolicy.outboundError({
        'type': 'hysteria2',
        'tls': {
          'enabled': true,
          'fixture%FF': 'metadata',
          'pin_sha256': 'fixture-digest',
        },
      }),
      TlsPinPolicy.unsupportedPinMessage,
    );
  });

  test('inspects URI strings in nested JSON configuration arrays', () {
    String wrap(List<String> links) => jsonEncode({
      'profiles': [
        {'links': links},
      ],
    });

    expect(TlsPinPolicy.inputError(wrap([_profile])), isNull);
    expect(
      TlsPinPolicy.inputError(wrap([_profile, _pinned])),
      TlsPinPolicy.unsupportedPinMessage,
    );
  });

  for (final malformed in ['{"outbounds": [', '["fixture",']) {
    test('malformed JSON beginning with ${malformed[0]} fails closed', () {
      expect(
        TlsPinPolicy.inputError(malformed),
        TlsPinPolicy.unsupportedPinMessage,
      );
    });
  }

  test('checks pins on embedded HTML links after decoding ampersands', () {
    const ordinary = '<a href="$_profile?obfs=fixture">regular</a>';
    const pinned =
        '<a href="$_profile?obfs=fixture&amp;pinSHA256=fixture-digest">pinned</a>';

    expect(TlsPinPolicy.inputError(ordinary), isNull);
    expect(
      TlsPinPolicy.inputError('<nav>$ordinary$pinned</nav>'),
      TlsPinPolicy.unsupportedPinMessage,
    );
  });

  test('a URI-like string in the fragment remains a display name', () {
    expect(TlsPinPolicy.inputError('$_profile#display-$_pinned'), isNull);
  });

  test('Base64 and nested unpadded Base64URL retain pin rejection', () {
    for (final payload in [_encode(_pinned), _encodeUrl(_encodeUrl(_pinned))]) {
      expect(
        TlsPinPolicy.inputError(payload),
        TlsPinPolicy.unsupportedPinMessage,
      );
    }
    expect(
      TlsPinPolicy.inputError(_encode('Note: pinSHA256 is mentioned in docs.')),
      isNull,
    );
  });

  test('encoded input fails closed beyond the recursion limit', () {
    var payload = _profile;
    for (var level = 0; level < 6; level++) {
      payload = _encode(payload);
    }

    expect(TlsPinPolicy.inputError(payload), isNull);
    expect(
      TlsPinPolicy.inputError(_encode(payload)),
      TlsPinPolicy.unsupportedPinMessage,
    );
  });
}

String _encode(String text) => base64.encode(utf8.encode(text));

String _encodeUrl(String text) =>
    base64Url.encode(utf8.encode(text)).replaceAll('=', '');
