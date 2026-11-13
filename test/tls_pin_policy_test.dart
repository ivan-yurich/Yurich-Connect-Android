import 'dart:convert';

import 'package:aurum_vpn/src/models/vpn_profile.dart';
import 'package:aurum_vpn/src/services/profile_importer.dart';
import 'package:aurum_vpn/src/services/sing_box_config_builder.dart';
import 'package:aurum_vpn/src/services/tls_pin_policy.dart';
import 'package:aurum_vpn/src/services/xray_config_builder.dart';
import 'package:flutter_test/flutter_test.dart';

const _hy2 = 'hy2://synthetic-test-only@edge.example.com:443/';
const _vless =
    'vless://11111111-1111-4111-8111-111111111111@edge.example.com:443';
final _pin = List.filled(32, '11').join();
final _spki = base64.encode(List.filled(32, 1));

Map<String, Object> _outbound({Map<String, Object?>? tls}) => {
  'type': 'hysteria2',
  'server': 'edge.example.com',
  'server_port': 443,
  'password': 'synthetic-test-only',
  'tls': tls ?? {'enabled': true, 'server_name': 'edge.example.com'},
};

Future<void> _reject(String text) async {
  await expectLater(
    ProfileImporter().importFromText(text),
    throwsA(
      isA<ProfileImportException>().having(
        (error) => error.message,
        'safe error',
        allOf(
          contains('TLS'),
          isNot(contains('synthetic-test-only')),
          isNot(contains(_pin)),
        ),
      ),
    ),
  );
}

void main() {
  for (final key in [
    'pinSHA256',
    'pin_sha256',
    'PIN-SHA256',
    '%70inSHA256',
    '%2570inSHA256',
    'certificate_public_key_sha256',
  ]) {
    test(
      'rejects unsupported URI pin key $key, even with TLS verification enabled',
      () async {
        await _reject('$_hy2?$key=$_pin');
        await _reject('$_hy2?insecure=1&$key=$_pin');
      },
    );
  }

  for (final query in [
    'pinSHA256=',
    'pinSHA256=bad-value',
    'pinSHA256=&pinSHA256=$_pin',
    'pinSHA256=$_pin&pinSHA256=',
  ]) {
    test('unsupported pin is never silently discarded: $query', () async {
      await _reject('$_hy2?insecure=1&$query');
    });
  }

  for (final scheme in [
    'hy2',
    'hysteria2',
    'hysteria',
    'naive',
    'naive+https',
  ]) {
    test('same pin invariant applies to $scheme', () async {
      await _reject(
        '$scheme://user:synthetic-test-only@edge.example.com:443/?insecure=1&pinSHA256=$_pin',
      );
    });
  }

  for (final transport in ['tcp', 'xhttp']) {
    test(
      'VLESS $transport does not turn a pinned URI into unpinned TLS',
      () async {
        await _reject(
          '$_vless?security=tls&type=$transport&insecure=1&pinSHA256=$_pin',
        );
      },
    );
  }

  test(
    'encoded subscriptions, JSON wrappers and HTML preserve pin rejection',
    () async {
      final bad = '$_hy2?insecure=1&pinSHA256=$_pin';
      for (final payload in [
        bad,
        base64.encode(utf8.encode(bad)),
        base64Url.encode(utf8.encode(bad)).replaceAll('=', ''),
        jsonEncode([bad]),
        jsonEncode({
          'links': [bad],
        }),
        '<a href="${bad.replaceAll('&', '&amp;')}">profile</a>',
      ]) {
        await _reject(payload);
      }
    },
  );

  test('one unsupported profile cannot contaminate a valid sibling', () async {
    final profiles = await ProfileImporter().importFromText(
      '$_hy2?insecure=1&pinSHA256=$_pin\n$_hy2',
    );
    expect(profiles, hasLength(1));
    expect(profiles.single.outbound!['tls'], isNot(contains('insecure')));
  });

  test(
    'JSON certificate aliases, including unicode-escaped keys, are rejected',
    () async {
      for (final key in [
        'pinSHA256',
        'certificate_sha256',
        'pinnedPeerCertificateChainSha256',
      ]) {
        final payload = jsonEncode(
          _outbound(
            tls: {
              'enabled': true,
              'insecure': true,
              key: [_pin],
            },
          ),
        );
        await _reject(payload);
        await _reject(payload.replaceAll('pinSHA256', r'\u0070inSHA256'));
        await _reject(
          jsonEncode({
            'inbounds': [],
            'outbounds': [jsonDecode(payload)],
          }),
        );
      }
    },
  );

  test(
    'Xray JSON is checked before conversion to a synthetic VLESS URI',
    () async {
      final payload = jsonEncode({
        'outbounds': [
          {
            'protocol': 'vless',
            'settings': {
              'vnext': [
                {
                  'address': 'edge.example.com',
                  'port': 443,
                  'users': [
                    {'id': '11111111-1111-4111-8111-111111111111'},
                  ],
                },
              ],
            },
            'streamSettings': {
              'network': 'xhttp',
              'security': 'tls',
              'tlsSettings': {
                'allowInsecure': true,
                'pinnedPeerCertificateChainSha256': [_pin],
              },
            },
          },
        ],
      });
      await _reject(payload);
    },
  );

  test(
    'old stored profile is blocked even when outbound already lost its pin',
    () {
      final profile = VpnProfile.fromJson({
        'id': 'legacy',
        'name': 'legacy',
        'kind': 'hysteria2',
        'originalInput': '$_hy2?insecure=1&pinSHA256=$_pin',
        'server': 'edge.example.com',
        'port': 443,
        'outbound': _outbound(tls: {'enabled': true, 'insecure': true}),
      });
      expect(
        () => SingBoxConfigBuilder().build(profile),
        throwsUnsupportedError,
      );
      expect(
        TlsPinPolicy.profileError(profile),
        TlsPinPolicy.unsupportedPinMessage,
      );
    },
  );

  test(
    'raw config and direct profile construction cannot bypass the builder gate',
    () {
      final raw = jsonEncode({
        'inbounds': [],
        'outbounds': [
          _outbound(
            tls: {'enabled': true, 'insecure': true, 'pinSHA256': _pin},
          ),
        ],
      });
      final profile = VpnProfile(
        id: 'raw',
        name: 'raw',
        kind: VpnProfileKind.singBoxConfig,
        originalInput: '',
        rawConfig: raw,
      );
      expect(
        () => SingBoxConfigBuilder().build(profile),
        throwsUnsupportedError,
      );
    },
  );

  test(
    'both Naive plans explicitly refuse a pin that normalization cannot preserve',
    () {
      final profile = VpnProfile(
        id: 'naive',
        name: 'naive',
        kind: VpnProfileKind.naive,
        originalInput: '',
        server: 'edge.example.com',
        outbound: {
          ..._outbound(
            tls: {
              'enabled': true,
              'certificate_public_key_sha256': [_spki],
            },
          ),
          'type': 'naive',
        },
      );
      for (final mode in NaiveOutboundMode.values) {
        expect(
          () => SingBoxConfigBuilder().build(profile, naiveMode: mode),
          throwsUnsupportedError,
        );
      }
    },
  );

  test('Xray builder refuses a persisted sing-box pin it cannot translate', () {
    final profile = VpnProfile(
      id: 'xray',
      name: 'xray',
      kind: VpnProfileKind.vlessXhttp,
      originalInput: '',
      server: 'edge.example.com',
      outbound: {
        ..._outbound(
          tls: {
            'enabled': true,
            'certificate_public_key_sha256': [_spki],
          },
        ),
        'type': 'vless',
        'uuid': '11111111-1111-4111-8111-111111111111',
        'transport': {'type': 'xhttp'},
      },
    );
    expect(() => XrayConfigBuilder().build(profile), throwsUnsupportedError);
  });

  test('supported Go TLS SPKI pin reaches runtime without modification', () {
    final outbound = _outbound(
      tls: {
        'enabled': true,
        'insecure': true,
        'certificate_public_key_sha256': [_spki],
      },
    );
    final profile = VpnProfile(
      id: 'spki',
      name: 'spki',
      kind: VpnProfileKind.hysteria2,
      originalInput: jsonEncode(outbound),
      server: 'edge.example.com',
      outbound: outbound,
    );
    final config = jsonDecode(SingBoxConfigBuilder().build(profile)) as Map;
    expect(config['outbounds'].first['tls']['certificate_public_key_sha256'], [
      _spki,
    ]);
    expect(outbound['tls'], {
      'enabled': true,
      'insecure': true,
      'certificate_public_key_sha256': [_spki],
    });
  });

  test('malformed SPKI values fail explicitly instead of being removed', () {
    for (final value in [
      '',
      ['bad'],
      [123],
    ]) {
      expect(
        TlsPinPolicy.outboundError(
          _outbound(
            tls: {'enabled': true, 'certificate_public_key_sha256': value},
          ),
        ),
        TlsPinPolicy.invalidPublicKeyPinMessage,
      );
    }
  });

  test(
    'ordinary WebPKI and deliberate insecure-only inputs retain compatibility',
    () async {
      for (final link in [_hy2, '$_hy2?insecure=1']) {
        final profile = (await ProfileImporter().importFromText(link)).single;
        expect(() => SingBoxConfigBuilder().build(profile), returnsNormally);
      }
    },
  );

  test(
    'Reality, uTLS, custom CA and pin-like display names are not certificate-pin aliases',
    () async {
      final reality = (await ProfileImporter().importFromText(
        '$_vless?security=reality&type=tcp&sni=edge.example.com&pbk=public-key&sid=01&fp=chrome#pinSHA256',
      )).single;
      expect(() => SingBoxConfigBuilder().build(reality), returnsNormally);
      final profile = (await ProfileImporter().importFromText(
        '$_hy2#pinSHA256=display-name',
      )).single;
      expect(TlsPinPolicy.profileError(profile), isNull);
      expect(
        TlsPinPolicy.outboundError(
          _outbound(
            tls: {
              'enabled': true,
              'certificate': ['test CA'],
              'certificate_path': '/test/ca.pem',
              'utls': {'fingerprint': 'chrome'},
            },
          ),
        ),
        isNull,
      );
    },
  );
}
