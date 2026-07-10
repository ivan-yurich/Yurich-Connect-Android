import 'dart:convert';

import 'package:aurum_vpn/src/models/vpn_profile.dart';
import 'package:aurum_vpn/src/models/dns_protection_mode.dart';
import 'package:aurum_vpn/src/services/profile_importer.dart';
import 'package:aurum_vpn/src/services/xray_config_builder.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('builds wrapped Xray VLESS XHTTP config', () async {
    const link =
        'vless://11111111-1111-4111-8111-111111111111@example.com:443?security=reality&type=xhttp&sni=www.microsoft.com&path=%2Fxhttp&mode=auto&host=cdn.example.com&fp=chrome&pbk=abc123&sid=01#XHTTP';

    final profile = (await ProfileImporter().importFromText(link)).first;
    final wrapper =
        jsonDecode(XrayConfigBuilder().build(profile)) as Map<String, dynamic>;
    final xray = wrapper['xray'] as Map<String, dynamic>;

    expect(wrapper['_yurich']['core'], XrayConfigBuilder.runtimeCore);
    expect(profile.kind, VpnProfileKind.vlessXhttp);

    final inbound = (xray['inbounds'] as List).first as Map<String, dynamic>;
    expect(inbound['protocol'], 'tun');
    expect(inbound['settings']['address'], '172.19.0.1/30');
    expect(inbound['settings']['mtu'], 1380);
    expect(inbound['settings']['dns'], ['1.1.1.1', '8.8.8.8']);
    expect(xray['dns']['queryStrategy'], 'UseIPv4');
    expect(
      ((xray['dns']['servers'] as List).first
          as Map<String, dynamic>)['address'],
      '1.1.1.1',
    );

    final proxy = (xray['outbounds'] as List).first as Map<String, dynamic>;
    expect(proxy['protocol'], 'vless');
    expect(
      (xray['outbounds'] as List).whereType<Map>().any(
        (outbound) =>
            outbound['tag'] == 'direct' && outbound['protocol'] == 'freedom',
      ),
      isTrue,
    );
    expect(
      (xray['outbounds'] as List).whereType<Map>().any(
        (outbound) =>
            outbound['tag'] == 'dns-out' && outbound['protocol'] == 'dns',
      ),
      isTrue,
    );
    final vnext = proxy['settings']['vnext'] as List;
    expect(vnext.first['address'], 'example.com');
    expect(vnext.first['port'], 443);
    final users = vnext.first['users'] as List;
    expect(users.first['id'], '11111111-1111-4111-8111-111111111111');
    expect(users.first['encryption'], 'none');

    final stream = proxy['streamSettings'] as Map<String, dynamic>;
    expect(stream['network'], 'xhttp');
    expect(stream['security'], 'reality');
    expect(stream['realitySettings']['serverName'], 'www.microsoft.com');
    expect(stream['realitySettings']['publicKey'], 'abc123');
    expect(stream['realitySettings']['shortId'], '01');
    expect(stream['realitySettings']['fingerprint'], 'chrome');
    expect(stream['xhttpSettings']['path'], '/xhttp');
    expect(stream['xhttpSettings']['host'], 'cdn.example.com');
    expect(stream['xhttpSettings'].containsKey('headers'), isFalse);
    expect(stream['xhttpSettings']['mode'], 'auto');

    final routing = xray['routing'] as Map<String, dynamic>;
    final rules = routing['rules'] as List;
    expect(rules.first, {
      'type': 'field',
      'protocol': ['dns'],
      'outboundTag': 'dns-out',
    });
    expect(rules[1], {'type': 'field', 'port': '53', 'outboundTag': 'dns-out'});
    expect(routing['final'], 'proxy');
  });

  test('builds wrapped Xray VLESS Reality TCP config', () async {
    const link =
        'vless://11111111-1111-4111-8111-111111111111@example.com:443?security=reality&type=tcp&sni=www.microsoft.com&flow=xtls-rprx-vision&fp=chrome&pbk=abc123&sid=01#REALITY';

    final profile = (await ProfileImporter().importFromText(link)).first;
    final wrapper =
        jsonDecode(XrayConfigBuilder().build(profile)) as Map<String, dynamic>;
    final xray = wrapper['xray'] as Map<String, dynamic>;

    expect(wrapper['_yurich']['core'], XrayConfigBuilder.runtimeCore);
    expect(profile.kind, VpnProfileKind.vlessReality);

    final proxy = (xray['outbounds'] as List).first as Map<String, dynamic>;
    final stream = proxy['streamSettings'] as Map<String, dynamic>;
    expect(stream['network'], 'tcp');
    expect(stream.containsKey('xhttpSettings'), isFalse);
    expect(stream['security'], 'reality');
    expect(stream['realitySettings']['serverName'], 'www.microsoft.com');
    expect(stream['realitySettings']['publicKey'], 'abc123');
    final vnext = proxy['settings']['vnext'] as List;
    final users = vnext.first['users'] as List;
    expect(users.first['flow'], 'xtls-rprx-vision');
    expect(xray['routing']['final'], 'proxy');
  });

  test('builds smart-route rules when enabled for Xray', () async {
    const link =
        'vless://11111111-1111-4111-8111-111111111111@example.com:443?security=reality&type=tcp&sni=www.microsoft.com&flow=xtls-rprx-vision&fp=chrome&pbk=abc123&sid=01#REALITY';

    final profile = (await ProfileImporter().importFromText(link)).first;
    final wrapper = jsonDecode(
      XrayConfigBuilder().build(
        profile,
        smartRouteRuDirect: true,
      ),
    ) as Map<String, dynamic>;
    final xray = wrapper['xray'] as Map<String, dynamic>;
    final rules = xray['routing']['rules'] as List;

    final hasProxyDomainRule = rules.any(
      (rule) =>
          rule['outboundTag'] == 'proxy' &&
          (rule['domain'] as List?)?.contains('chat.openai.com') == true,
    );
    final hasProxySuffixRule = rules.any(
      (rule) =>
          rule['outboundTag'] == 'proxy' &&
          (rule['domain_suffix'] as List?)?.contains('google.com') == true,
    );
    final hasDirectDomainRule = rules.any(
      (rule) =>
          rule['outboundTag'] == 'direct' &&
          (rule['domain'] as List?)?.contains('vk.com') == true,
    );
    final hasDirectSuffixRule = rules.any(
      (rule) =>
          rule['outboundTag'] == 'direct' &&
          (rule['domain_suffix'] as List?)?.contains('ru') == true,
    );

    expect(hasProxyDomainRule, isTrue);
    expect(hasProxySuffixRule, isTrue);
    expect(hasDirectDomainRule, isTrue);
    expect(hasDirectSuffixRule, isTrue);
  });

  test('builds leak-guard DNS settings for Xray', () async {
    const link =
        'vless://11111111-1111-4111-8111-111111111111@example.com:443?security=reality&type=tcp&sni=www.microsoft.com&flow=xtls-rprx-vision&fp=chrome&pbk=abc123&sid=01#REALITY';

    final profile = (await ProfileImporter().importFromText(link)).first;
    final wrapper = jsonDecode(
      XrayConfigBuilder().build(
        profile,
        dnsProtectionMode: DnsProtectionMode.leakGuard,
      ),
    ) as Map<String, dynamic>;
    final xray = wrapper['xray'] as Map<String, dynamic>;
    final dnsServers = xray['dns']['servers'] as List;
    expect(dnsServers.length, 2);

    for (final server in dnsServers) {
      final s = server as Map<String, dynamic>;
      expect('${s['address']}', startsWith('https://'));
      expect(s['queryStrategy'], 'UseIPv4');
    }
  });
}
