import 'dart:convert';

import 'package:aurum_vpn/src/models/vpn_profile.dart';
import 'package:aurum_vpn/src/services/xray_config_builder.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('rejects profile kinds outside Xray VLESS XHTTP and Reality', () {
    expect(
      () => XrayConfigBuilder().build(_profile(kind: VpnProfileKind.hysteria2)),
      _rejects<UnsupportedError>('only VLESS XHTTP/Reality'),
    );
  });

  test('rejects a supported profile without an outbound config', () {
    expect(
      () => XrayConfigBuilder().build(_profile()),
      _rejects<StateError>('нет outbound-конфига'),
    );
  });

  for (final field in ['server', 'uuid']) {
    for (final value in [null, '']) {
      test('rejects a ${value == null ? 'missing' : 'blank'} XHTTP $field', () {
        final profile = _profile(
          outbound: _outbound(overrides: {field: value}),
          // A deliberately blank outbound address is not repaired by silently
          // switching to a different endpoint from the enclosing profile.
          server: field == 'server' && value == '' ? 'fallback.invalid' : null,
        );
        expect(
          () => XrayConfigBuilder().build(profile),
          _rejects<StateError>('без $field'),
        );
      });
    }
  }

  test('merges encoded XHTTP extras, preserving TLS and dedicated Host', () {
    final profile = _profile(
      outbound: _outbound(
        transport: {
          'host': 'front.example.invalid',
          'headers': {
            'Host': 'header.example.invalid',
            'hOsT': 'other.example.invalid',
            'X-Fixture': 'fixture',
          },
          'extra': '{"xPaddingBytes":"100-200","xmux":{"maxConcurrency":2}}',
          'xmux': '{"maxConcurrency":8}',
        },
      ),
    );

    final stream = _proxyFor(profile)['streamSettings'] as Map<String, dynamic>;
    expect(stream['network'], 'xhttp');
    expect(stream['security'], 'tls');
    expect(
      stream['tlsSettings'],
      containsPair('serverName', 'sni.example.invalid'),
    );
    expect(stream['tlsSettings'], isNot(contains('allowInsecure')));
    expect(stream['xhttpSettings'], {
      'path': '/fixture',
      'host': 'front.example.invalid',
      'extra': {
        'xPaddingBytes': '100-200',
        'headers': {'X-Fixture': 'fixture'},
        'xmux': {'maxConcurrency': 8},
      },
    });
  });

  for (final (label, source, expected) in [
    (
      'JSON array',
      '[1,{"fixture":true}]',
      [
        1,
        {'fixture': true},
      ],
    ),
    ('non-JSON string', 'fixture-extra', 'fixture-extra'),
  ]) {
    test('preserves the XHTTP extra shape for a $label', () {
      final settings = _xhttpFor({'extra': source});
      expect(settings['extra'], expected);
    });
  }

  test('keeps a non-JSON xmux string without failing config serialization', () {
    final settings = _xhttpFor({'xmux': 'fixture-xmux'});
    expect(settings['extra'], {'xmux': 'fixture-xmux'});
  });

  for (final (label, source, storedPort, expected) in [
    ('numeric value', 8443.9, null, 8443),
    ('integer string', '9443', null, 9443),
    ('invalid string with profile fallback', 'invalid', 1443, 1443),
    ('invalid string without profile fallback', 'invalid', null, 443),
  ]) {
    test('sets the Xray server port ($label)', () {
      final proxy = _proxyFor(
        _profile(
          outbound: _outbound(overrides: {'server_port': source}),
          port: storedPort,
        ),
      );
      final vnext = proxy['settings']['vnext'] as List;
      expect(vnext.single['address'], 'edge.example.invalid');
      expect(vnext.single['port'], expected);
    });
  }
}

VpnProfile _profile({
  VpnProfileKind kind = VpnProfileKind.vlessXhttp,
  Map<String, dynamic>? outbound,
  String? server,
  int? port,
}) => VpnProfile(
  id: 'fixture',
  name: 'Fixture',
  kind: kind,
  originalInput: '',
  server: server,
  port: port,
  outbound: outbound,
);

Map<String, dynamic> _outbound({
  Map<String, Object?> overrides = const {},
  Map<String, Object?> transport = const {},
}) => {
  'type': 'vless',
  'server': 'edge.example.invalid',
  'server_port': 443,
  'uuid': '11111111-1111-4111-8111-111111111111',
  'tls': {'enabled': true, 'server_name': 'sni.example.invalid'},
  'transport': {'type': 'xhttp', 'path': '/fixture', ...transport},
  ...overrides,
};

Map<String, dynamic> _proxyFor(VpnProfile profile) {
  final wrapper = jsonDecode(XrayConfigBuilder().build(profile));
  final outbounds = wrapper['xray']['outbounds'] as List;
  return outbounds.whereType<Map<String, dynamic>>().singleWhere(
    (outbound) => outbound['tag'] == 'proxy',
  );
}

Map<String, dynamic> _xhttpFor(Map<String, Object?> transport) {
  final proxy = _proxyFor(_profile(outbound: _outbound(transport: transport)));
  final stream = proxy['streamSettings'] as Map<String, dynamic>;
  return stream['xhttpSettings'] as Map<String, dynamic>;
}

Matcher _rejects<T extends Error>(String fragment) => throwsA(
  isA<T>().having(
    (error) => error.toString(),
    'diagnostic',
    contains(fragment),
  ),
);
