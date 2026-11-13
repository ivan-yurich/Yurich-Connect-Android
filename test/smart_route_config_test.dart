import 'dart:convert';

import 'package:aurum_vpn/src/models/dns_protection_mode.dart';
import 'package:aurum_vpn/src/models/vpn_profile.dart';
import 'package:aurum_vpn/src/services/sing_box_config_builder.dart';
import 'package:aurum_vpn/src/services/smart_route_rules.dart';
import 'package:aurum_vpn/src/services/xray_config_builder.dart';
import 'package:flutter_test/flutter_test.dart';

VpnProfile _profile(VpnProfileKind kind) => VpnProfile(
  id: 'fixture-${kind.name}',
  name: 'Synthetic fixture',
  kind: kind,
  originalInput: '',
  server: 'edge.example.com',
  port: 443,
  outbound: {
    'type': switch (kind) {
      VpnProfileKind.naive => 'naive',
      VpnProfileKind.hysteria => 'hysteria',
      VpnProfileKind.hysteria2 => 'hysteria2',
      _ => 'vless',
    },
    'server': 'edge.example.com',
    'server_port': 443,
    'uuid': '11111111-1111-4111-8111-111111111111',
    'password': 'synthetic-test-only',
    'tls': {
      'enabled': true,
      'server_name': 'edge.example.com',
      if (kind == VpnProfileKind.vlessReality)
        'reality': {
          'enabled': true,
          'public_key': 'test-only',
          'short_id': '01',
        },
    },
    if (kind == VpnProfileKind.vlessXhttp)
      'transport': {'type': 'xhttp', 'path': '/test'},
  },
);

bool _suffixMatches(String host, String suffix) =>
    host == suffix || host.endsWith('.$suffix');

String _singBoxRoute(Map config, String host) {
  for (final rule in (config['route']['rules'] as List).whereType<Map>()) {
    if ((rule['domain'] as List? ?? const []).contains(host) ||
        (rule['domain_suffix'] as List? ?? const []).cast<String>().any(
          (suffix) => _suffixMatches(host, suffix),
        )) {
      return rule['outbound'] as String;
    }
  }
  return config['route']['final'] as String;
}

String _xrayRoute(Map config, String host) {
  for (final rule in (config['routing']['rules'] as List).whereType<Map>()) {
    for (final domain in (rule['domain'] as List? ?? const []).cast<String>()) {
      if ((domain.startsWith('full:') && host == domain.substring(5)) ||
          (domain.startsWith('domain:') &&
              _suffixMatches(host, domain.substring(7)))) {
        return rule['outboundTag'] as String;
      }
    }
  }
  return config['routing']['rules'].last['outboundTag'] as String;
}

const _expectedRoutes = {
  'gosuslugi.ru': 'direct',
  'esia.gosuslugi.ru': 'direct',
  'api.yandex.ru': 'direct',
  'ya.ru': 'direct',
  'sberbank.ru': 'direct',
  'cdn.vk.com': 'direct',
  'unknown.ru': 'proxy',
  'unknown.su': 'proxy',
  'unknown.xn--p1ai': 'proxy',
  'yandex.ru.attacker.test': 'proxy',
  'notyandex.ru': 'proxy',
  'google.ru': 'proxy',
  'chat.openai.com': 'proxy',
  'gemini.google.com': 'proxy',
  'web.telegram.org': 'proxy',
  'example.com': 'proxy',
};

void main() {
  test(
    'local diagnostics are forced through proxy before Smart Route bypass',
    () {
      final singBox =
          jsonDecode(
                SingBoxConfigBuilder().build(
                  _profile(VpnProfileKind.naive),
                  smartRouteRuDirect: true,
                ),
              )
              as Map;
      final singRules = (singBox['route']['rules'] as List).cast<Map>();
      final localIndex = singRules.indexWhere(
        (r) => (r['inbound'] as List? ?? []).contains('mixed-in'),
      );
      final directIndex = singRules.indexWhere(
        (r) => r['outbound'] == 'direct',
      );
      expect(localIndex, greaterThanOrEqualTo(0));
      expect(localIndex, lessThan(directIndex));
      expect(singRules[localIndex]['outbound'], 'proxy');
      final xray =
          jsonDecode(
                XrayConfigBuilder().build(
                  _profile(VpnProfileKind.vlessXhttp),
                  smartRouteRuDirect: true,
                ),
              )['xray']
              as Map;
      final xrayRules = (xray['routing']['rules'] as List).cast<Map>();
      final httpIndex = xrayRules.indexWhere(
        (r) => (r['inboundTag'] as List? ?? []).contains('health-http-in'),
      );
      expect(httpIndex, greaterThanOrEqualTo(0));
      expect(
        httpIndex,
        lessThan(xrayRules.indexWhere((r) => r['outboundTag'] == 'direct')),
      );
      expect(xrayRules[httpIndex]['outboundTag'], 'proxy');
    },
  );
  for (final kind in [
    VpnProfileKind.naive,
    VpnProfileKind.hysteria,
    VpnProfileKind.hysteria2,
    VpnProfileKind.vlessTls,
    VpnProfileKind.vlessReality,
  ]) {
    for (final mode in DnsProtectionMode.values) {
      test(
        'sing-box ${kind.name}/${mode.name} uses allowlist-only direct routing',
        () {
          final text = SingBoxConfigBuilder().build(
            _profile(kind),
            smartRouteRuDirect: true,
            dnsProtectionMode: mode,
          );
          final config = jsonDecode(text) as Map;
          for (final entry in _expectedRoutes.entries) {
            expect(
              _singBoxRoute(config, entry.key),
              entry.value,
              reason: entry.key,
            );
          }
          final domainRules = (config['route']['rules'] as List)
              .whereType<Map>()
              .where(
                (rule) =>
                    rule.containsKey('domain') ||
                    rule.containsKey('domain_suffix'),
              )
              .toList();
          expect(domainRules, hasLength(2));
          expect(domainRules.first['outbound'], 'proxy');
          expect(domainRules.last['outbound'], 'direct');
          expect(text, isNot(contains('\n')));
          final remoteDns = (config['dns']['servers'] as List)
              .whereType<Map>()
              .where((server) => server['type'] == 'https');
          for (final server in remoteDns) {
            expect(server['detour'], 'proxy');
          }
        },
      );
    }
  }

  for (final kind in [VpnProfileKind.vlessXhttp, VpnProfileKind.vlessReality]) {
    for (final mode in DnsProtectionMode.values) {
      test(
        'Xray ${kind.name}/${mode.name} has identical allowlist routing',
        () {
          final text = XrayConfigBuilder().build(
            _profile(kind),
            smartRouteRuDirect: true,
            dnsProtectionMode: mode,
          );
          final wrapper = jsonDecode(text) as Map;
          final config = wrapper['xray'] as Map;
          for (final entry in _expectedRoutes.entries) {
            expect(
              _xrayRoute(config, entry.key),
              entry.value,
              reason: entry.key,
            );
          }
          final domainRules = (config['routing']['rules'] as List)
              .whereType<Map>()
              .where((rule) => rule.containsKey('domain'))
              .toList();
          expect(domainRules, hasLength(2));
          expect(domainRules.first['outboundTag'], 'proxy');
          expect(domainRules.last['outboundTag'], 'direct');
          expect(
            wrapper['_yurich']['androidDisallowedPackages'],
            SmartRouteRules.ruBypassPackages(const []),
          );
          expect(text, isNot(contains('\n')));
        },
      );
    }
  }

  test('disabling Smart Route retains full-tunnel rules in both cores', () {
    final singBox =
        jsonDecode(SingBoxConfigBuilder().build(_profile(VpnProfileKind.naive)))
            as Map;
    final xrayWrapper =
        jsonDecode(
              XrayConfigBuilder().build(_profile(VpnProfileKind.vlessXhttp)),
            )
            as Map;
    for (final host in _expectedRoutes.keys) {
      expect(_singBoxRoute(singBox, host), 'proxy');
      expect(_xrayRoute(xrayWrapper['xray'] as Map, host), 'proxy');
    }
    expect(singBox['inbounds'].first['exclude_package'], [
      'online.dnsai.ivanvpn',
    ]);
    expect(xrayWrapper['_yurich']['androidDisallowedPackages'], isNull);
  });
}
