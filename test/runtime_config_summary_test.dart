import 'dart:convert';

import 'package:aurum_vpn/src/services/profile_importer.dart';
import 'package:aurum_vpn/src/services/runtime_config_summary.dart';
import 'package:aurum_vpn/src/services/sing_box_config_builder.dart';
import 'package:aurum_vpn/src/services/xray_config_builder.dart';
import 'package:flutter_test/flutter_test.dart';

String _summarize(String config) =>
    RuntimeConfigSummary.summarize(config, target: SingBoxConfigTarget.android);

String _summarizeMap(Map<String, Object?> config) =>
    _summarize(jsonEncode(config));

void main() {
  const singBoxFallback =
      'dns=unknown/unknown; mtu=unknown; strict_route=unknown; stack=unknown; '
      'smart_route=false; network=default';
  const marker = {'core': XrayConfigBuilder.runtimeCore};

  test('reports malformed JSON and incompatible types as raw config', () {
    for (final config in [
      '{broken',
      '[]',
      '{"inbounds":{}}',
      '{"_yurich":{"core":"xray"},"xray":[]}',
    ]) {
      expect(_summarize(config), 'target=android; raw/custom config');
    }
  });

  test('reports missing sing-box TUN, proxy and DNS', () {
    expect(
      _summarize('{}'),
      'target=android; proxy=unknown; $singBoxFallback; mixed_proxy=false',
    );
  });

  test('does not echo configs with incompatible nested types', () {
    const sentinel = 'sentinel-nested-config';
    for (final config in [
      {
        'outbounds': [
          {'tag': 'proxy', 'tls': false, 'password': sentinel},
        ],
      },
      {
        '_yurich': marker,
        'xray': {
          'outbounds': [
            {'tag': 'proxy', 'streamSettings': false, 'settings': sentinel},
          ],
        },
      },
    ]) {
      final summary = _summarizeMap(config);
      expect(summary, 'target=android; raw/custom config');
      expect(summary, isNot(contains(sentinel)));
    }
  });

  test('uses the first sing-box outbound and handles unmatched final DNS', () {
    expect(
      _summarizeMap({
        'outbounds': [
          {'type': 'http', 'tag': 'first'},
          {'type': 'direct', 'tag': 'second'},
        ],
        'dns': {
          'final': 'missing',
          'servers': [
            {'tag': 'another', 'type': 'local'},
          ],
        },
      }),
      'target=android; proxy=http; dns=missing/unknown; mtu=unknown; '
      'strict_route=unknown; stack=unknown; smart_route=false; network=default; '
      'mode=https-connect; health_probe=mixed-proxy; mixed_proxy=false',
    );
  });

  test('reports sing-box Smart Route without package names or credentials', () {
    const username = 'sentinel-user';
    const password = 'sentinel-pass';
    const bypassPackage = 'example.sentinel.app';
    final summary = _summarizeMap({
      'inbounds': [
        {
          'type': 'tun',
          'mtu': 1380,
          'strict_route': true,
          'stack': 'mixed',
          'exclude_package': ['online.dnsai.ivanvpn', bypassPackage],
        },
        {
          'type': 'mixed',
          'listen': '127.0.0.1',
          'listen_port': SingBoxConfigBuilder.localMixedProxyPort,
        },
      ],
      'outbounds': [
        {'type': 'direct', 'tag': 'direct'},
        {
          'type': 'naive',
          'tag': 'proxy',
          'username': username,
          'password': password,
          'quic': true,
        },
      ],
      'route': {
        'rules': [
          {
            'outbound': 'direct',
            'domain_suffix': ['gosuslugi.ru'],
          },
          {
            'outbound': 'proxy',
            'domain': ['example.com'],
          },
          {
            'outbound': 'proxy',
            'domain_suffix': ['example.net'],
          },
          {'outbound': 'proxy'},
        ],
      },
      'dns': {
        'final': 'remote-dns-primary',
        'servers': [
          {'tag': 'remote-dns-primary', 'type': 'https', 'detour': 'proxy'},
          {'tag': 'fake-ip', 'type': 'fakeip'},
        ],
      },
    });
    expect(
      summary,
      'target=android; proxy=naive; dns=remote-dns-primary/https; '
      'dns_leak_guard=true; dns_detour=proxy; fake_dns=true; mtu=1380; '
      'strict_route=true; stack=mixed; smart_route=true; ru_bypass_packages=1; '
      'global_proxy_rules=2; network=default; mode=naive-native; '
      'health_probe=mixed-proxy; transport=h3/quic; mixed_proxy=true',
    );
    for (final sentinel in [username, password, bypassPackage]) {
      expect(summary, isNot(contains(sentinel)));
    }
  });

  test('reports a missing Xray payload as an invalid wrapper', () {
    expect(
      _summarizeMap({'_yurich': marker}),
      'target=android; core=xray; invalid wrapper',
    );
  });

  test('reports missing fields in an empty Xray payload', () {
    expect(
      _summarizeMap({'_yurich': marker, 'xray': <String, Object?>{}}),
      'target=android; core=xray; proxy=unknown; transport=unknown; '
      'security=unknown; xhttp_mode=default; dns=; route_final=missing; '
      'smart_route=false; mtu=unknown; gateway=unknown; sni=unknown; '
      'mixed_proxy=false',
    );
  });

  test('uses the first Xray outbound and falls back to TLS SNI', () {
    expect(
      _summarizeMap({
        '_yurich': marker,
        'xray': {
          'outbounds': [
            {
              'protocol': 'vless',
              'streamSettings': {
                'network': 'tcp',
                'security': 'tls',
                'tlsSettings': {'serverName': 'tls.example'},
              },
            },
            {'protocol': 'freedom'},
          ],
        },
      }),
      'target=android; core=xray; proxy=vless; transport=tcp; security=tls; '
      'xhttp_mode=default; dns=; route_final=missing; smart_route=false; '
      'mtu=unknown; gateway=unknown; sni=tls.example; mixed_proxy=false',
    );
  });

  const id = '11111111-1111-4111-8111-111111111111';

  test('summarizes builder-created sing-box VLESS TLS', () async {
    final profile = (await ProfileImporter().importFromText(
      'vless://$id@example.com:443?security=tls&type=tcp&sni=tls.example',
    )).single;
    final config = SingBoxConfigBuilder().build(profile);
    final summary = _summarize(config);

    expect(config, contains(id));
    expect(summary, startsWith('target=android; proxy=vless; dns='));
    expect(summary, contains('mode=tls; flow=default; sni=tls.example;'));
    expect(summary, endsWith('mixed_proxy=true'));
    expect(summary, isNot(contains(id)));
  });

  test(
    'summarizes builder-created Xray Reality XHTTP and Smart Route',
    () async {
      const key = 'sentinel-key';
      const shortId = '1234abcd';
      final profile = (await ProfileImporter().importFromText(
        'vless://$id@example.com:443?security=reality&type=xhttp'
        '&sni=reality.example&path=%2Fxhttp&mode=auto&fp=chrome'
        '&pbk=$key&sid=$shortId',
      )).single;
      final config = XrayConfigBuilder().build(
        profile,
        smartRouteRuDirect: true,
      );
      final summary = _summarize(config);

      expect(
        summary,
        startsWith(
          'target=android; core=xray; proxy=vless; transport=xhttp; '
          'security=reality; xhttp_mode=auto; dns=',
        ),
      );
      expect(
        summary,
        contains('route_final=missing; smart_route=true; mtu=1380;'),
      );
      expect(
        summary,
        endsWith('sni=reality.example; reality=true; mixed_proxy=false'),
      );
      for (final sentinel in [id, key, shortId]) {
        expect(config, contains(sentinel));
        expect(summary, isNot(contains(sentinel)));
      }
    },
  );
}
