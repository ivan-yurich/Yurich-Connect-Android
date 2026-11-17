import 'dart:convert';

import 'package:aurum_vpn/src/models/dns_protection_mode.dart';
import 'package:aurum_vpn/src/models/vpn_profile.dart';
import 'package:aurum_vpn/src/services/sing_box_config_builder.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final raw in [null, ' \t\n ']) {
    test('rejects a ${raw == null ? 'missing' : 'blank'} raw config', () {
      expect(
        () => SingBoxConfigBuilder().build(
          _profile(VpnProfileKind.singBoxConfig, raw: raw),
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message.toString(),
            'message',
            contains('Пустой sing-box config'),
          ),
        ),
      );
    });
  }

  test('rejects a structured profile without outbound settings', () {
    expect(
      () => SingBoxConfigBuilder().build(_profile(VpnProfileKind.vlessTls)),
      throwsA(
        isA<StateError>().having(
          (error) => error.message.toString(),
          'message',
          contains('нет outbound-конфига'),
        ),
      ),
    );
  });

  const remoteDnsKinds = {
    VpnProfileKind.hysteria,
    VpnProfileKind.hysteria2,
    VpnProfileKind.vlessReality,
    VpnProfileKind.vlessTls,
  };
  for (final mode in DnsProtectionMode.values) {
    test('sing-box DNS policy for every profile kind in ${mode.name}', () {
      for (final kind in VpnProfileKind.values) {
        expect(
          SingBoxConfigBuilder.usesRemoteDnsFor(kind, mode),
          mode == DnsProtectionMode.leakGuard && remoteDnsKinds.contains(kind),
          reason: kind.name,
        );
      }
    });
  }

  for (final (kind, transport) in [
    (VpnProfileKind.vlessXhttp, 'xhttp'),
    (VpnProfileKind.vlessMkcp, 'kcp'),
    (VpnProfileKind.vlessReality, 'ws'),
  ]) {
    test('Leak Guard does not make ${kind.name}/$transport runnable', () {
      final profile = _profile(
        kind,
        outbound: {
          ..._vlessOutbound,
          'transport': {'type': transport},
        },
      );
      expect(
        () => SingBoxConfigBuilder().build(
          profile,
          dnsProtectionMode: DnsProtectionMode.leakGuard,
        ),
        throwsA(
          isA<UnsupportedError>().having(
            (error) => error.message.toString(),
            'message',
            contains('Xray/libXray'),
          ),
        ),
      );
    });
  }

  test('VLESS TLS removes the TCP alias and keeps leak-guard DNS tunneled', () {
    final profile = _profile(
      VpnProfileKind.vlessTls,
      server: 'edge.example.invalid',
      outbound: _vlessOutbound,
    );
    final config = _build(profile, DnsProtectionMode.leakGuard);
    final proxy = (config['outbounds'] as List).first as Map<String, dynamic>;
    expect(proxy, isNot(contains('network')));
    expect(proxy['packet_encoding'], 'xudp');
    expect(proxy['tls'], _vlessOutbound['tls']);
    expect(profile.outbound?['network'], 'tcp');

    final dns = config['dns'] as Map<String, dynamic>;
    expect(dns['final'], 'remote-dns-primary');
    expect(config['route']['default_domain_resolver'], 'remote-dns-primary');
    final remote = (dns['servers'] as List).whereType<Map>().where(
      (server) => server['type'] == 'https',
    );
    expect(remote.map((server) => server['tag']), [
      'remote-dns-primary',
      'remote-dns-secondary',
    ]);
    for (final server in remote) {
      expect(server['detour'], 'proxy');
      expect(server['tls']['enabled'], isTrue);
    }
    expect((dns['rules'] as List).first, {
      'domain': ['edge.example.invalid'],
      'action': 'route',
      'server': 'local-dns',
    });
    final stable = _build(profile, DnsProtectionMode.stable);
    expect(stable['dns']['final'], 'local-dns');
    expect(stable['route']['default_domain_resolver'], 'local-dns');
    expect(
      (stable['dns']['servers'] as List).whereType<Map>().map((s) => s['type']),
      isNot(contains('https')),
    );
  });

  for (final server in ['profile.example.invalid', null]) {
    test(
      'Naive uses the profile or outbound host for missing SNI ($server)',
      () {
        final profile = _profile(
          VpnProfileKind.naive,
          server: server,
          outbound: const {
            'type': 'naive',
            'server': 'outbound.example.invalid',
            'server_port': 443,
            'tls': {'enabled': true},
          },
        );
        final config = _build(profile, DnsProtectionMode.leakGuard);
        final proxy =
            (config['outbounds'] as List).first as Map<String, dynamic>;
        expect(proxy['tls'], {
          'enabled': true,
          'server_name': server ?? 'outbound.example.invalid',
        });
        expect(config['dns']['final'], 'local-dns');
        expect(config['route']['default_domain_resolver'], 'local-dns');
      },
    );
  }

  test('generated DNS policy leaves custom raw DNS settings unchanged', () {
    const dns = {
      'servers': [
        {
          'type': 'https',
          'tag': 'fixture-dns',
          'server': 'dns.example.invalid',
        },
      ],
      'final': 'fixture-dns',
    };
    final profile = _profile(
      VpnProfileKind.singBoxConfig,
      raw: jsonEncode({'dns': dns}),
    );
    expect(_build(profile, DnsProtectionMode.leakGuard)['dns'], dns);
  });
}

const _vlessOutbound = {
  'type': 'vless',
  'server': 'edge.example.invalid',
  'server_port': 443,
  'uuid': '11111111-1111-4111-8111-111111111111',
  'network': 'tcp',
  'tls': {'enabled': true, 'server_name': 'sni.example.invalid'},
};

VpnProfile _profile(
  VpnProfileKind kind, {
  String? raw,
  String? server,
  Map<String, dynamic>? outbound,
}) => VpnProfile(
  id: 'fixture',
  name: 'Fixture',
  kind: kind,
  originalInput: '',
  server: server,
  rawConfig: raw,
  outbound: outbound,
);

Map<String, dynamic> _build(VpnProfile profile, DnsProtectionMode mode) =>
    jsonDecode(SingBoxConfigBuilder().build(profile, dnsProtectionMode: mode))
        as Map<String, dynamic>;
