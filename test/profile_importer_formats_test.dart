import 'dart:convert';

import 'package:aurum_vpn/src/models/vpn_profile.dart';
import 'package:aurum_vpn/src/services/profile_importer.dart';
import 'package:aurum_vpn/src/services/tls_pin_policy.dart';
import 'package:flutter_test/flutter_test.dart';

const _uuid = '11111111-1111-4111-8111-111111111111';
const _edge = 'edge.example.invalid';
const _sni = 'tls.example.invalid';

void main() {
  final importer = ProfileImporter();
  final seconds = DateTime.utc(2030).millisecondsSinceEpoch ~/ 1000;
  for (final (name, value, expected) in [
    ('epoch seconds', seconds, DateTime.utc(2030)),
    (
      'epoch milliseconds',
      seconds * 1000 + 789,
      DateTime.utc(2030, 1, 1, 0, 0, 0, 789),
    ),
    (
      'fractional epoch milliseconds',
      seconds * 1000 + 788.75,
      DateTime.utc(2030, 1, 1, 0, 0, 0, 789),
    ),
    (
      'offset ISO timestamp',
      '2030-07-01T10:15:00+03:00',
      DateTime.utc(2030, 7, 1, 7, 15),
    ),
    ('invalid date', 'not-a-date', null),
  ]) {
    test('decoded JSON normalizes subscription metadata: $name', () async {
      final body = _encoded({
        'type': 'http',
        'server': _edge,
        'server_port': '2443',
        'tls': {'enabled': true, 'server_name': _sni},
        'metadata': {
          'subscriptions': [
            {'expires_at': value},
          ],
        },
      });
      final profile = (await importer.importFromText(body)).single;
      expect(profile.kind, VpnProfileKind.naive);
      expect(profile.port, 2443);
      expect(profile.outbound?['server_port'], 2443);
      expect(profile.subscriptionExpiresAt, expected);
      expect(profile.subscriptionSource, isNull);
      expect(
        VpnProfile.fromJson(profile.toJson()).subscriptionExpiresAt,
        expected,
      );
    });
  }

  test(
    'Base64 Xray split HTTP keeps TLS and transport metadata separate',
    () async {
      final extra = jsonEncode({'fixtureOption': 4});
      final body = _encoded([
        _xray('splithttp', {
          'splitHTTPSettings': {
            'path': '/fixture',
            'host': 'cdn.example.invalid',
            'mode': 'auto',
            'extra': extra,
            'xmux': {'maxConcurrency': 4},
          },
        }),
      ]);

      final profile = (await importer.importFromText(body)).single;
      expect(profile.kind, VpnProfileKind.vlessXhttp);
      expect(profile.name, 'Fixture');
      expect(profile.port, 2443);
      expect(profile.outbound?['tls'], {
        'enabled': true,
        'server_name': _sni,
        'alpn': ['h2', 'http/1.1'],
      });
      expect(profile.outbound?['transport'], {
        'type': 'xhttp',
        'path': '/fixture',
        'host': 'cdn.example.invalid',
        'mode': 'auto',
        'extra': extra,
        'headers': {'Host': 'cdn.example.invalid'},
      });
      final query = Uri.parse(profile.originalInput).queryParameters;
      expect(jsonDecode(query['xmux']!), {'maxConcurrency': 4});
    },
  );

  test(
    'Xray mKCP import keeps header metadata but remains unsupported',
    () async {
      final profile = (await importer.importFromText(
        jsonEncode(
          _xray('kcp', {
            'kcpSettings': {
              'header': {'type': 'none'},
            },
          }),
        ),
      )).single;
      expect(profile.kind, VpnProfileKind.vlessMkcp);
      expect(profile.kind.isClientSupported, isFalse);
      expect(profile.outbound?['unsupported_transport'], 'mkcp');
      expect(
        profile.outbound?['transport_options'],
        containsPair('headerType', 'none'),
      );
      expect(profile.outbound?['tls'], containsPair('enabled', true));
    },
  );

  for (final (transport, options, expected) in [
    (
      'ws',
      {'host': 'cdn.example.invalid', 'path': '/ws'},
      {
        'type': 'ws',
        'path': '/ws',
        'headers': {'Host': 'cdn.example.invalid'},
      },
    ),
    (
      'http',
      {'host': 'one.example.invalid, , two.example.invalid', 'path': '/http'},
      {
        'type': 'http',
        'host': ['one.example.invalid', 'two.example.invalid'],
        'path': '/http',
      },
    ),
    (
      'h2',
      {'host': 'cdn.example.invalid', 'path': '/h2'},
      {
        'type': 'http',
        'host': ['cdn.example.invalid'],
        'path': '/h2',
      },
    ),
    (
      'httpupgrade',
      {'host': 'cdn.example.invalid', 'path': '/upgrade'},
      {
        'type': 'httpupgrade',
        'path': '/upgrade',
        'headers': {'Host': 'cdn.example.invalid'},
      },
    ),
    ('quic', <String, String>{}, {'type': 'quic'}),
  ]) {
    test(
      'VLESS TLS preserves $transport options with verification on',
      () async {
        final link = _vless({
          'type': transport,
          'sni': _sni,
          'alpn': 'h2, http/1.1, ',
          ...options,
        });
        final profile = (await importer.importFromText(link)).single;
        expect(profile.kind, VpnProfileKind.vlessTls);
        expect(profile.outbound?['transport'], expected);
        expect(profile.outbound?['tls'], {
          'enabled': true,
          'server_name': _sni,
          'alpn': ['h2', 'http/1.1'],
        });
      },
    );
  }

  test(
    'XHTTP headers keep valid entries and trim custom packet encoding',
    () async {
      final profile = (await importer.importFromText(
        _vless({
          'type': 'xhttp',
          'host': 'cdn.example.invalid',
          'header':
              ' X-Fixture : value  |broken|Missing: | :discard|X-Other: ok',
          'packetEncoding': ' packetaddr ',
        }),
      )).single;
      expect(profile.kind, VpnProfileKind.vlessXhttp);
      expect(profile.outbound?['packet_encoding'], 'packetaddr');
      expect((profile.outbound?['transport'] as Map)['headers'], {
        'Host': 'cdn.example.invalid',
        'X-Fixture': 'value',
        'X-Other': 'ok',
      });
    },
  );

  test('unknown VLESS transport is reported, not silently replaced', () async {
    await expectLater(
      importer.importFromText(_vless({'type': 'fixture-unknown'})),
      throwsA(_failure('Transport "fixture-unknown" пока не поддержан.')),
    );
  });

  test('Naive QUIC preserves the requested congestion-control name', () async {
    final link = Uri(
      scheme: 'naive+https',
      userInfo: 'fixture:fixture',
      host: _edge,
      queryParameters: {
        'quic': 'true',
        'quic_congestion_control': 'bbr',
        'sni': _sni,
      },
    ).toString();
    final profile = (await importer.importFromText(link)).single;
    expect(profile.kind, VpnProfileKind.naive);
    expect(profile.outbound?['quic'], isTrue);
    expect(profile.outbound?['quic_congestion_control'], 'bbr');
    expect(profile.outbound?['tls'], {'enabled': true, 'server_name': _sni});
  });

  test(
    'legacy Hysteria reads userinfo, obfs, network and verified TLS options',
    () async {
      final link = Uri(
        scheme: 'hysteria',
        userInfo: 'fixture:auth',
        host: _edge,
        queryParameters: {
          'protocol': 'udp',
          'obfs': 'fixture-obfs',
          'sni': _sni,
          'alpn': 'h3, h3-29',
        },
      ).toString();
      final profile = (await importer.importFromText(link)).single;
      expect(profile.kind, VpnProfileKind.hysteria);
      expect(profile.outbound?['auth_str'], 'fixture:auth');
      expect(profile.outbound?['obfs'], 'fixture-obfs');
      expect(profile.outbound?['network'], 'udp');
      expect(profile.outbound?['tls'], {
        'enabled': true,
        'server_name': _sni,
        'alpn': ['h3', 'h3-29'],
      });
    },
  );

  test(
    'unsupported certificate pin is rejected instead of being dropped',
    () async {
      await expectLater(
        importer.importFromText(_vless({'peerFingerprint': 'fixture-only'})),
        throwsA(_failure(TlsPinPolicy.unsupportedPinMessage)),
      );
    },
  );

  test('full raw document rejects Xray VLESS without a TLS mode', () async {
    await expectLater(
      importer.importFromText(
        jsonEncode({
          'inbounds': [],
          'outbounds': [
            {
              'protocol': 'vless',
              'streamSettings': {'network': 'tcp'},
            },
          ],
        }),
      ),
      throwsA(_failure('VLESS без TLS/Reality не поддерживается.')),
    );
  });
}

String _encoded(Object payload) =>
    base64Url.encode(utf8.encode(jsonEncode(payload))).replaceAll('=', '');

String _vless(Map<String, String> options) => Uri(
  scheme: 'vless',
  userInfo: _uuid,
  host: _edge,
  queryParameters: {'security': 'tls', ...options},
).toString();

Map<String, Object?> _xray(String network, Map<String, Object?> transport) => {
  'remarks': 'Fixture',
  'outbounds': [
    {
      'protocol': 'vless',
      'settings': {
        'vnext': [
          {
            'address': _edge,
            'port': '2443',
            'users': [
              {'id': _uuid},
            ],
          },
        ],
      },
      'streamSettings': {
        'network': network,
        'security': 'tls',
        'tlsSettings': {
          'serverName': _sni,
          'alpn': ['h2', 'http/1.1'],
        },
        ...transport,
      },
    },
  ],
};

Matcher _failure(String text) => isA<ProfileImportException>().having(
  (error) => error.message,
  'message',
  contains(text),
);
