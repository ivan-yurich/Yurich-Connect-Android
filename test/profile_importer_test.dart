import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:aurum_vpn/src/models/dns_protection_mode.dart';
import 'package:aurum_vpn/src/models/vpn_profile.dart';
import 'package:aurum_vpn/src/services/profile_importer.dart';
import 'package:aurum_vpn/src/services/sing_box_config_builder.dart';
import 'package:aurum_vpn/src/services/smart_route_rules.dart';

void main() {
  test('imports VLESS Reality link', () async {
    const link =
        'vless://11111111-1111-4111-8111-111111111111@example.com:443?security=reality&type=tcp&flow=xtls-rprx-vision&sni=www.example.com&fp=chrome&pbk=abc123&sid=01#Reality';

    final profiles = await ProfileImporter().importFromText(link);

    expect(profiles, hasLength(1));
    expect(profiles.first.kind, VpnProfileKind.vlessReality);
    expect(profiles.first.outbound?['type'], 'vless');
    expect(profiles.first.outbound?['network'], isNull);
    expect(profiles.first.outbound?['packet_encoding'], 'xudp');
    expect(profiles.first.outbound?['flow'], 'xtls-rprx-vision');
    expect(profiles.first.outbound?['tls']['server_name'], 'www.example.com');
    expect(profiles.first.outbound?['tls']['utls'], {
      'enabled': true,
      'fingerprint': 'chrome',
    });
    expect(profiles.first.outbound?['tls']['reality']['public_key'], 'abc123');
  });

  test('normalizes VLESS Reality defaults for stable Android config', () async {
    const link =
        'vless://11111111-1111-4111-8111-111111111111@example.com:443?security=reality&pbk=abc123#Reality';

    final profile = (await ProfileImporter().importFromText(link)).first;
    final config =
        jsonDecode(SingBoxConfigBuilder().build(profile))
            as Map<String, dynamic>;
    final proxy = (config['outbounds'] as List).first as Map<String, dynamic>;

    expect(profile.kind, VpnProfileKind.vlessReality);
    expect(proxy['network'], isNull);
    expect(proxy['flow'], 'xtls-rprx-vision');
    expect(proxy['packet_encoding'], 'xudp');
    expect(proxy['tls']['enabled'], true);
    expect(proxy['tls']['server_name'], 'example.com');
    expect(proxy['tls']['utls'], {'enabled': true, 'fingerprint': 'chrome'});
    expect(proxy['tls']['reality']['enabled'], true);
    expect(proxy['tls']['reality']['public_key'], 'abc123');
  });

  test('rejects VLESS Reality without public key', () async {
    const link =
        'vless://11111111-1111-4111-8111-111111111111@example.com:443?security=reality&type=tcp#Broken';

    await expectLater(
      ProfileImporter().importFromText(link),
      throwsA(isA<ProfileImportException>()),
    );
  });

  test('imports VLESS XHTTP link as unsupported legacy profile', () async {
    const link =
        'vless://11111111-1111-4111-8111-111111111111@example.com:443?security=tls&type=xhttp&sni=example.com&path=%2Fxhttp#XHTTP';

    final profile = (await ProfileImporter().importFromText(link)).first;

    expect(profile.kind, VpnProfileKind.vlessXhttp);
    expect(profile.outbound?['type'], 'vless');
    expect(profile.outbound?['unsupported_transport'], 'xhttp');
    expect(profile.outbound?['transport_options']['path'], '/xhttp');
    expect(
      () => SingBoxConfigBuilder().build(profile),
      throwsA(isA<UnsupportedError>()),
    );
  });

  test('imports VLESS mKCP link as unsupported legacy profile', () async {
    const link =
        'vless://11111111-1111-4111-8111-111111111111@example.com:8446?security=none&type=mkcp&headerType=wechat-video#MKCP';

    final profile = (await ProfileImporter().importFromText(link)).first;

    expect(profile.kind, VpnProfileKind.vlessMkcp);
    expect(profile.outbound?['type'], 'vless');
    expect(profile.outbound?['unsupported_transport'], 'mkcp');
    expect(
      profile.outbound?['transport_options']['headerType'],
      'wechat-video',
    );
    expect(
      () => SingBoxConfigBuilder().build(profile),
      throwsA(isA<UnsupportedError>()),
    );
  });

  test('imports Hysteria2 link', () async {
    const link =
        'hy2://secret-for-test@example.com:443?sni=cdn.example.com&obfs=salamander&obfs-password=obfs-secret&upmbps=100&downmbps=200#Hy2';

    final profile = (await ProfileImporter().importFromText(link)).first;
    final config =
        jsonDecode(SingBoxConfigBuilder().build(profile))
            as Map<String, dynamic>;
    final proxy = (config['outbounds'] as List).first as Map<String, dynamic>;

    expect(profile.kind, VpnProfileKind.hysteria2);
    expect(proxy['type'], 'hysteria2');
    expect(proxy['server'], 'example.com');
    expect(proxy['password'], 'secret-for-test');
    expect(proxy['up_mbps'], 100);
    expect(proxy['down_mbps'], 200);
    expect(proxy['obfs'], {'type': 'salamander', 'password': 'obfs-secret'});
    expect(proxy['tls'], {'enabled': true, 'server_name': 'cdn.example.com'});
  });

  test('imports Hysteria v1 link with safe defaults', () async {
    const link =
        'hysteria://example.com:443?auth=secret-for-test&peer=cdn.example.com&upmbps=80&downmbps=160#Hy1';

    final profile = (await ProfileImporter().importFromText(link)).first;
    final config =
        jsonDecode(SingBoxConfigBuilder().build(profile))
            as Map<String, dynamic>;
    final proxy = (config['outbounds'] as List).first as Map<String, dynamic>;

    expect(profile.kind, VpnProfileKind.hysteria);
    expect(proxy['type'], 'hysteria');
    expect(proxy['server'], 'example.com');
    expect(proxy['auth_str'], 'secret-for-test');
    expect(proxy['up_mbps'], 80);
    expect(proxy['down_mbps'], 160);
    expect(proxy['tls'], {'enabled': true, 'server_name': 'cdn.example.com'});
  });

  test('imports NaiveProxy link', () async {
    const link = 'naive+https://example.com:pass@example.com:443#Naive';

    final profiles = await ProfileImporter().importFromText(link);
    final config =
        jsonDecode(SingBoxConfigBuilder().build(profiles.first))
            as Map<String, dynamic>;
    final proxy = (config['outbounds'] as List).first as Map<String, dynamic>;

    expect(profiles, hasLength(1));
    expect(profiles.first.kind, VpnProfileKind.naive);
    expect(profiles.first.outbound?['username'], 'example.com');
    expect(profiles.first.outbound?['password'], 'pass');
    expect(proxy['type'], 'naive');
    expect(proxy['tls'], {'enabled': true, 'server_name': 'example.com'});
    final dnsServers =
        (config['dns'] as Map<String, dynamic>)['servers'] as List;
    expect(dnsServers.first, {'type': 'local', 'tag': 'local-dns'});
    expect(dnsServers[1], {
      'type': 'fakeip',
      'tag': 'fakeip',
      'inet4_range': '198.18.0.0/15',
      'inet6_range': 'fc00::/18',
    });
    expect(dnsServers, hasLength(2));
    expect((config['dns'] as Map<String, dynamic>)['rules'], [
      {
        'domain': ['example.com'],
        'action': 'route',
        'server': 'local-dns',
      },
      {
        'inbound': ['tun-in'],
        'query_type': ['A', 'AAAA'],
        'action': 'route',
        'server': 'fakeip',
      },
    ]);
    expect((config['dns'] as Map<String, dynamic>)['final'], 'local-dns');

    final inbounds = (config['inbounds'] as List)
        .whereType<Map<String, dynamic>>()
        .toList();
    final tunInbound = inbounds.firstWhere(
      (inbound) => inbound['type'] == 'tun',
    );
    expect(tunInbound['address'], ['172.19.0.1/30']);
    expect(tunInbound['mtu'], 1380);
    expect(tunInbound['interface_name'], 'tun0');
    expect(tunInbound['strict_route'], isTrue);
    expect(tunInbound['stack'], 'gvisor');
    expect(tunInbound['endpoint_independent_nat'], isNull);
    expect(tunInbound['exclude_package'], ['online.dnsai.ivanvpn']);
    expect(
      inbounds.any(
        (inbound) =>
            inbound['type'] == 'mixed' &&
            inbound['listen'] == '127.0.0.1' &&
            inbound['listen_port'] == SingBoxConfigBuilder.localMixedProxyPort,
      ),
      isTrue,
    );
    expect(
      (config['outbounds'] as List).whereType<Map<String, dynamic>>().map(
        (outbound) => outbound['type'],
      ),
      isNot(contains('dns')),
    );
    final routeRules =
        ((config['route'] as Map<String, dynamic>)['rules'] as List)
            .whereType<Map<String, dynamic>>()
            .toList();
    expect(routeRules.first['action'], 'sniff');
    expect(
      routeRules.any(
        (rule) =>
            rule['action'] == 'hijack-dns' &&
            (rule['rules'] as List).whereType<Map>().any(
              (nested) => nested['protocol'] == 'dns',
            ),
      ),
      isTrue,
    );
    expect(
      routeRules.any(
        (rule) =>
            rule['action'] == 'reject' &&
            (rule['rules'] as List).whereType<Map>().any(
              (nested) => nested['port'] == 853,
            ) &&
            (rule['rules'] as List).whereType<Map>().any(
              (nested) => nested['protocol'] == 'icmp',
            ),
      ),
      isTrue,
    );
    final rejectRule = routeRules.firstWhere(
      (rule) => rule['action'] == 'reject',
    );
    expect(
      (rejectRule['rules'] as List).whereType<Map>().any(
        (nested) => nested['network'] == 'udp' && nested.length == 1,
      ),
      isTrue,
    );
    expect(
      (rejectRule['rules'] as List).whereType<Map>().any(
        (nested) => nested['network'] == 'udp' && nested['port'] == 443,
      ),
      isTrue,
    );
    expect(routeRules.any((rule) => rule['ip_is_private'] == true), isTrue);
    expect(
      (config['route'] as Map<String, dynamic>)['default_domain_resolver'],
      'local-dns',
    );
    expect(
      (config['route'] as Map<String, dynamic>)['auto_detect_interface'],
      isTrue,
    );
    expect((config['route'] as Map<String, dynamic>)['find_process'], isNull);
    expect((config['dns'] as Map<String, dynamic>)['cache_capacity'], 8192);
    expect((config['dns'] as Map<String, dynamic>)['reverse_mapping'], isTrue);
    expect((config['dns'] as Map<String, dynamic>)['strategy'], 'ipv4_only');
    expect(proxy['connect_timeout'], '8s');
    expect(proxy['tcp_fast_open'], isNull);
    expect(proxy['tcp_keep_alive'], '3m');
    expect(proxy['tcp_keep_alive_interval'], '30s');
    expect(proxy['domain_resolver'], 'local-dns');
    expect(proxy['domain_strategy'], 'ipv4_only');
    expect(proxy['network_strategy'], 'fallback');
    expect(proxy['fallback_delay'], '200ms');
    expect(proxy['quic'], isFalse);
    expect(proxy['quic_congestion_control'], isNull);
    expect(proxy['udp_over_tcp'], isNull);

    final httpFallbackConfig =
        jsonDecode(
              SingBoxConfigBuilder().build(
                profiles.first,
                naiveMode: NaiveOutboundMode.httpConnect,
              ),
            )
            as Map<String, dynamic>;
    final httpFallbackProxy =
        (httpFallbackConfig['outbounds'] as List).first as Map<String, dynamic>;
    expect(httpFallbackProxy['type'], 'http');
    expect(httpFallbackProxy['server'], 'example.com');
    expect(httpFallbackProxy['username'], 'example.com');
    expect(httpFallbackProxy['password'], 'pass');
  });

  test('keeps Naive DNS stable when Auto DNS is enabled', () async {
    const link = 'naive+https://example.com:pass@example.com:443#Naive';

    final profile = (await ProfileImporter().importFromText(link)).first;
    final config =
        jsonDecode(
              SingBoxConfigBuilder().build(
                profile,
                dnsProtectionMode: DnsProtectionMode.leakGuard,
              ),
            )
            as Map<String, dynamic>;

    final dns = config['dns'] as Map<String, dynamic>;
    final dnsServers = (dns['servers'] as List)
        .whereType<Map<String, dynamic>>()
        .toList();

    expect(dns['final'], 'local-dns');
    expect(
      dnsServers.where((server) => server['tag'] == 'remote-dns'),
      isEmpty,
    );
    expect((dns['rules'] as List).whereType<Map<String, dynamic>>().first, {
      'domain': ['example.com'],
      'action': 'route',
      'server': 'local-dns',
    });
    expect(
      (config['route'] as Map<String, dynamic>)['default_domain_resolver'],
      'local-dns',
    );

    final proxy = (config['outbounds'] as List)
        .whereType<Map<String, dynamic>>()
        .first;
    expect(proxy['domain_resolver'], 'local-dns');
  });

  test('keeps VLESS Reality DNS stable when Auto DNS is enabled', () async {
    const link =
        'vless://11111111-1111-4111-8111-111111111111@example.com:443?security=reality&type=tcp&flow=xtls-rprx-vision&sni=www.example.com&fp=chrome&pbk=abc123&sid=01#Reality';

    final profile = (await ProfileImporter().importFromText(link)).first;
    final config =
        jsonDecode(
              SingBoxConfigBuilder().build(
                profile,
                dnsProtectionMode: DnsProtectionMode.leakGuard,
              ),
            )
            as Map<String, dynamic>;
    final dns = config['dns'] as Map<String, dynamic>;
    final dnsServers = (dns['servers'] as List)
        .whereType<Map<String, dynamic>>()
        .toList();

    expect(dns['final'], 'local-dns');
    expect(
      dnsServers.where((server) => server['tag'] == 'remote-dns'),
      isEmpty,
    );
    expect(
      (config['route'] as Map<String, dynamic>)['default_domain_resolver'],
      'local-dns',
    );
  });

  test('keeps remote DNS only for Hysteria Auto DNS mode', () async {
    const link =
        'hy2://secret-for-test@example.com:443?sni=cdn.example.com#Hy2';

    final profile = (await ProfileImporter().importFromText(link)).first;
    final config =
        jsonDecode(
              SingBoxConfigBuilder().build(
                profile,
                dnsProtectionMode: DnsProtectionMode.leakGuard,
              ),
            )
            as Map<String, dynamic>;
    final dns = config['dns'] as Map<String, dynamic>;
    final dnsServers = (dns['servers'] as List)
        .whereType<Map<String, dynamic>>()
        .toList();
    final remoteDns = dnsServers.firstWhere(
      (server) => server['tag'] == 'remote-dns',
    );

    expect(dns['final'], 'remote-dns');
    expect(remoteDns['type'], 'https');
    expect(remoteDns['server'], '1.1.1.1');
    expect(remoteDns['detour'], 'proxy');
    expect(
      (config['route'] as Map<String, dynamic>)['default_domain_resolver'],
      'remote-dns',
    );
  });

  test('adds Smart Route direct rules for Russian apps and domains', () async {
    const link =
        'naive+https://user:pass@example.com:443#Naive%20Smart%20Route';

    final profile = (await ProfileImporter().importFromText(link)).first;
    final config =
        jsonDecode(
              SingBoxConfigBuilder().build(
                profile,
                smartRouteRuDirect: true,
                smartRouteRuBypassPackages: const [
                  'ru.gosuslugi',
                  'ru.some.newbank',
                  'ru.yandex.browser',
                  'ru.yandex.searchplugin',
                  'com.yandex.browser',
                  'com.openai.chatgpt',
                  'com.android.chrome',
                  'com.google.android.gm',
                  'com.google.android.gms',
                  'com.google.android.apps.gemini',
                  'com.google.android.youtube',
                  'org.telegram.messenger',
                ],
              ),
            )
            as Map<String, dynamic>;

    final inbounds = (config['inbounds'] as List)
        .whereType<Map<String, dynamic>>()
        .toList();
    final tunInbound = inbounds.firstWhere(
      (inbound) => inbound['type'] == 'tun',
    );
    final excludedPackages = (tunInbound['exclude_package'] as List)
        .whereType<String>()
        .toList();
    expect(excludedPackages, contains('online.dnsai.ivanvpn'));
    expect(excludedPackages, isNot(contains('ru.yandex.browser')));
    expect(excludedPackages, isNot(contains('ru.yandex.searchplugin')));
    expect(excludedPackages, isNot(contains('com.yandex.browser')));
    expect(excludedPackages, isNot(contains('com.openai.chatgpt')));
    expect(excludedPackages, isNot(contains('com.android.chrome')));
    expect(excludedPackages, isNot(contains('com.google.android.gm')));
    expect(excludedPackages, isNot(contains('com.google.android.gms')));
    expect(excludedPackages, isNot(contains('com.google.android.apps.gemini')));
    expect(excludedPackages, isNot(contains('com.google.android.youtube')));
    expect(excludedPackages, isNot(contains('org.telegram.messenger')));
    expect(excludedPackages, contains('ru.gosuslugi'));
    expect(excludedPackages, contains('ru.some.newbank'));
    expect(excludedPackages, contains('ru.sberbankmobile'));
    expect(excludedPackages, contains('ru.vk.android'));

    final routeRules =
        ((config['route'] as Map<String, dynamic>)['rules'] as List)
            .whereType<Map<String, dynamic>>()
            .toList();
    final globalExactRuleIndex = routeRules.indexWhere(
      (rule) =>
          rule['outbound'] == 'proxy' &&
          (rule['domain'] as List?)?.contains('chat.openai.com') == true &&
          (rule['domain'] as List?)?.contains('aistudio.google.com') == true &&
          (rule['domain'] as List?)?.contains('gemini.google.com') == true &&
          (rule['domain'] as List?)?.contains('accounts.google.com') == true &&
          (rule['domain'] as List?)?.contains(
                'generativelanguage.googleapis.com',
              ) ==
              true &&
          (rule['domain'] as List?)?.contains('mtalk.google.com') == true &&
          (rule['domain'] as List?)?.contains('web.telegram.org') == true &&
          (rule['domain'] as List?)?.contains('t.me') == true,
    );
    expect(globalExactRuleIndex, isNonNegative);

    final globalProxyRuleIndex = routeRules.indexWhere(
      (rule) =>
          rule['outbound'] == 'proxy' &&
          (rule['domain_suffix'] as List?)?.contains('chatgpt.com') == true &&
          (rule['domain_suffix'] as List?)?.contains('openai.com') == true &&
          (rule['domain_suffix'] as List?)?.contains('gemini.google.com') ==
              true &&
          (rule['domain_suffix'] as List?)?.contains('telegram.org') == true &&
          (rule['domain_suffix'] as List?)?.contains('instagram.com') == true &&
          (rule['domain_suffix'] as List?)?.contains('youtube.com') == true &&
          (rule['domain_suffix'] as List?)?.contains('googlevideo.com') == true,
    );
    expect(globalProxyRuleIndex, isNonNegative);
    expect(globalExactRuleIndex, lessThan(globalProxyRuleIndex));

    final ruDirectRuleIndex = routeRules.indexWhere(
      (rule) =>
          rule['outbound'] == 'direct' &&
          (rule['domain_suffix'] as List?)?.contains('ru') == true &&
          (rule['domain_suffix'] as List?)?.contains('рф') == true,
    );
    expect(ruDirectRuleIndex, isNonNegative);
    expect(globalProxyRuleIndex, lessThan(ruDirectRuleIndex));

    expect(
      routeRules.any(
        (rule) =>
            rule['outbound'] == 'direct' &&
            (rule['domain_suffix'] as List?)?.contains('ru') == true &&
            (rule['domain_suffix'] as List?)?.contains('рф') == true,
      ),
      isTrue,
    );
    expect(
      routeRules.any(
        (rule) =>
            rule['outbound'] == 'direct' &&
            (rule['domain'] as List?)?.contains('gosuslugi.ru') == true,
      ),
      isTrue,
    );
    expect(SmartRouteRules.ruDirectPackageNames, isNotEmpty);
  });

  test('imports PingTunnel link as experimental profile', () async {
    const link = 'pingtunnel://user:token@example.com:443#PingTunnel';

    final profiles = await ProfileImporter().importFromText(link);
    final profile = profiles.first;

    expect(profiles, hasLength(1));
    expect(profile.kind, VpnProfileKind.pingTunnelExperimental);
    expect(profile.server, 'example.com');
    expect(profile.outbound?['type'], 'pingtunnel');
    expect(
      () => SingBoxConfigBuilder().build(profile),
      throwsA(isA<UnsupportedError>()),
    );
  });

  test('builds Hiddify-like RU app bypass list with global app denylist', () {
    final packages = SmartRouteRules.ruBypassPackages(const [
      'ru.gosuslugi',
      'ru.some.newbank',
      'ru.yandex.browser',
      'ru.yandex.searchplugin',
      'com.yandex.browser',
      'com.openai.chatgpt',
      'com.microsoft.copilot',
      'com.microsoft.bing',
      'ai.perplexity.app.android',
      'com.android.chrome',
      'com.google.android.gm',
      'com.google.android.gms',
      'com.google.android.apps.gemini',
      'org.telegram.messenger',
      'com.google.android.youtube',
    ]);

    expect(packages, contains('ru.gosuslugi'));
    expect(packages, contains('ru.some.newbank'));
    expect(packages, contains('ru.sberbankmobile'));
    expect(packages, isNot(contains('ru.yandex.browser')));
    expect(packages, isNot(contains('ru.yandex.searchplugin')));
    expect(packages, isNot(contains('com.yandex.browser')));
    expect(packages, isNot(contains('com.openai.chatgpt')));
    expect(packages, isNot(contains('com.microsoft.copilot')));
    expect(packages, isNot(contains('com.microsoft.bing')));
    expect(packages, isNot(contains('ai.perplexity.app.android')));
    expect(packages, isNot(contains('com.android.chrome')));
    expect(packages, isNot(contains('com.google.android.gm')));
    expect(packages, isNot(contains('com.google.android.gms')));
    expect(packages, isNot(contains('com.google.android.apps.gemini')));
    expect(packages, isNot(contains('org.telegram.messenger')));
    expect(packages, isNot(contains('com.google.android.youtube')));
  });

  test('keeps native Naive outbound and normalizes TLS fields', () {
    const profile = VpnProfile(
      id: 'legacy-naive',
      name: 'Legacy Naive',
      kind: VpnProfileKind.naive,
      originalInput: 'naive+https://user:pass@example.com:443',
      server: 'example.com',
      port: 443,
      outbound: {
        'type': 'naive',
        'server': 'example.com',
        'server_port': 443,
        'username': 'user',
        'password': 'pass',
        'tls': {
          'enabled': true,
          'server_name': 'example.com',
          'insecure': true,
        },
      },
    );

    final config =
        jsonDecode(SingBoxConfigBuilder().build(profile))
            as Map<String, dynamic>;
    final proxy = (config['outbounds'] as List).first as Map<String, dynamic>;

    expect(proxy['type'], 'naive');
    expect(proxy['tls'], {'server_name': 'example.com', 'enabled': true});
  });

  test(
    'imports go-it style NaiveProxy link as native Naive outbound',
    () async {
      const link = 'naive+https://ivan:secret-for-test@go-it.tech:443';

      final profile = (await ProfileImporter().importFromText(link)).first;
      final config =
          jsonDecode(SingBoxConfigBuilder().build(profile))
              as Map<String, dynamic>;
      final proxy = (config['outbounds'] as List).first as Map<String, dynamic>;

      expect(profile.kind, VpnProfileKind.naive);
      expect(profile.server, 'go-it.tech');
      expect(proxy['type'], 'naive');
      expect(proxy['server'], 'go-it.tech');
      expect(proxy['server_port'], 443);
      expect(proxy['username'], 'ivan');
      expect(proxy['password'], 'secret-for-test');
      expect(proxy['tls'], {'enabled': true, 'server_name': 'go-it.tech'});
    },
  );

  test(
    'imports n8n style NaiveProxy link and supports HTTP CONNECT fallback',
    () async {
      const link =
          'naive+https://n8n-cloud.online:secret-for-test@n8n-cloud.online:443';

      final profile = (await ProfileImporter().importFromText(link)).first;
      final nativeConfig =
          jsonDecode(SingBoxConfigBuilder().build(profile))
              as Map<String, dynamic>;
      final nativeProxy =
          (nativeConfig['outbounds'] as List).first as Map<String, dynamic>;
      final httpConfig =
          jsonDecode(
                SingBoxConfigBuilder().build(
                  profile,
                  naiveMode: NaiveOutboundMode.httpConnect,
                ),
              )
              as Map<String, dynamic>;
      final httpProxy =
          (httpConfig['outbounds'] as List).first as Map<String, dynamic>;

      expect(profile.kind, VpnProfileKind.naive);
      expect(profile.server, 'n8n-cloud.online');
      expect(nativeProxy['type'], 'naive');
      expect(httpProxy['type'], 'http');
      expect(httpProxy['server'], 'n8n-cloud.online');
      expect(httpProxy['server_port'], 443);
      expect(httpProxy['username'], 'n8n-cloud.online');
      expect(httpProxy['password'], 'secret-for-test');
      expect(httpProxy['tls'], {
        'enabled': true,
        'server_name': 'n8n-cloud.online',
      });
    },
  );

  test('imports standalone sing-box HTTP outbound for NaiveProxy', () async {
    final payload = jsonEncode({
      'type': 'http',
      'tag': 'naiveproxy-out',
      'server': 'n8n-cloud.online',
      'server_port': 443,
      'username': 'n8n-cloud.online',
      'password': 'secret-for-test',
      'tls': {'enabled': true, 'server_name': 'n8n-cloud.online'},
    });

    final profile = (await ProfileImporter().importFromText(payload)).first;
    final config =
        jsonDecode(SingBoxConfigBuilder().build(profile))
            as Map<String, dynamic>;
    final proxy = (config['outbounds'] as List).first as Map<String, dynamic>;

    expect(profile.kind, VpnProfileKind.naive);
    expect(profile.name, 'n8n-cloud.online');
    expect(proxy['type'], 'http');
    expect(proxy['tag'], 'proxy');
    expect(proxy['server'], 'n8n-cloud.online');
    expect(proxy['server_port'], 443);
    expect(proxy['username'], 'n8n-cloud.online');
    expect(proxy['password'], 'secret-for-test');
    expect(proxy['tls'], {'server_name': 'n8n-cloud.online', 'enabled': true});
  });

  test('imports standalone sing-box Hysteria2 outbound', () async {
    final payload = jsonEncode({
      'type': 'hysteria2',
      'tag': 'proxy',
      'server': 'example.com',
      'server_port': 443,
      'password': 'secret-for-test',
      'tls': {'enabled': true, 'server_name': 'example.com'},
    });

    final profile = (await ProfileImporter().importFromText(payload)).first;
    final config =
        jsonDecode(SingBoxConfigBuilder().build(profile))
            as Map<String, dynamic>;
    final proxy = (config['outbounds'] as List).first as Map<String, dynamic>;

    expect(profile.kind, VpnProfileKind.hysteria2);
    expect(proxy['type'], 'hysteria2');
    expect(proxy['server'], 'example.com');
    expect(proxy['password'], 'secret-for-test');
  });

  test('normalizes standalone sing-box VLESS Reality outbound', () async {
    final payload = jsonEncode({
      'type': 'vless',
      'tag': 'proxy',
      'server': 'example.com',
      'server_port': 443,
      'uuid': '11111111-1111-4111-8111-111111111111',
      'network': 'tcp',
      'transport': {'type': 'tcp'},
      'tls': {
        'enabled': true,
        'insecure': true,
        'reality': {'enabled': true, 'public_key': 'abc123'},
      },
    });

    final profile = (await ProfileImporter().importFromText(payload)).first;
    final config =
        jsonDecode(SingBoxConfigBuilder().build(profile))
            as Map<String, dynamic>;
    final proxy = (config['outbounds'] as List).first as Map<String, dynamic>;

    expect(profile.kind, VpnProfileKind.vlessReality);
    expect(proxy['network'], isNull);
    expect(proxy['transport'], isNull);
    expect(proxy['flow'], 'xtls-rprx-vision');
    expect(proxy['packet_encoding'], 'xudp');
    expect(proxy['tls']['server_name'], 'example.com');
    expect(proxy['tls']['insecure'], isNull);
    expect(proxy['tls']['utls'], {'enabled': true, 'fingerprint': 'chrome'});
    expect(proxy['tls']['reality']['public_key'], 'abc123');
  });

  test('rejects legacy VLESS Reality outbounds without Reality fields', () {
    const profile = VpnProfile(
      id: 'legacy-vless',
      name: 'Legacy VLESS',
      kind: VpnProfileKind.vlessReality,
      originalInput: 'vless://legacy',
      server: 'example.com',
      port: 443,
      outbound: {
        'type': 'vless',
        'server': 'example.com',
        'server_port': 443,
        'uuid': '11111111-1111-4111-8111-111111111111',
        'network': 'tcp',
      },
    );

    expect(
      () => SingBoxConfigBuilder().build(profile),
      throwsA(isA<StateError>()),
    );
  });

  test('imports base64 subscription list', () async {
    const raw =
        'naive+https://user:pass@example.com:443#Naive\nvless://11111111-1111-4111-8111-111111111111@example.com:443?security=reality&pbk=abc123#Reality';
    final encoded = base64.encode(utf8.encode(raw));

    final profiles = await ProfileImporter().importFromText(encoded);

    expect(profiles, hasLength(2));
  });

  test('imports subscription expiration metadata from payload', () async {
    const raw =
        'subscription-userinfo: upload=0; download=0; total=1073741824; expire=1893456000\n'
        'naive+https://user:pass@example.com:443#Naive';

    final profile = (await ProfileImporter().importFromText(raw)).first;

    expect(
      profile.subscriptionExpiresAt,
      DateTime.fromMillisecondsSinceEpoch(1893456000 * 1000, isUtc: true),
    );
    expect(
      VpnProfile.fromJson(profile.toJson()).subscriptionExpiresAt,
      profile.subscriptionExpiresAt,
    );
  });

  test('imports subscription expiration from profile name', () async {
    const raw =
        'naive+https://user:pass@example.com:443#%F0%9F%87%AB%F0%9F%87%AE%20Finland%20%E2%80%A2%20%D0%B4%D0%BE%2008.06.2027%20%E2%80%A2%20Yurich%20Proxy\n'
        'hy2://pass@example.com:8443?insecure=1#Germany%20until%2009-06-2027';

    final profiles = await ProfileImporter().importFromText(raw);

    expect(profiles, hasLength(2));
    expect(profiles.first.subscriptionExpiresAt, isNotNull);
    expect(profiles.first.subscriptionExpiresAt!.toLocal().year, 2027);
    expect(profiles.first.subscriptionExpiresAt!.toLocal().month, 6);
    expect(profiles.first.subscriptionExpiresAt!.toLocal().day, 8);
    expect(profiles.last.subscriptionExpiresAt, isNotNull);
    expect(profiles.last.subscriptionExpiresAt!.toLocal().day, 9);
  });

  test(
    'applies subscription expiration from one profile name to whole list',
    () async {
      const raw =
          'naive+https://user:pass@example.com:443#net-it.pro\n'
          'hy2://pass@example.com:8443?insecure=1#ivan-hy2-until-2027-06-08';

      final profiles = await ProfileImporter().importFromText(raw);

      expect(profiles, hasLength(2));
      expect(profiles.first.name, 'net-it.pro');
      expect(profiles.first.subscriptionExpiresAt, isNotNull);
      expect(
        profiles.first.subscriptionExpiresAt,
        profiles.last.subscriptionExpiresAt,
      );
      expect(profiles.first.subscriptionExpiresAt!.toLocal().year, 2027);
      expect(profiles.first.subscriptionExpiresAt!.toLocal().month, 6);
      expect(profiles.first.subscriptionExpiresAt!.toLocal().day, 8);
    },
  );

  test('keeps HTTP subscription source separate from profile links', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    unawaited(
      server.first.then((request) {
        request.response.headers.set(
          'subscription-userinfo',
          'upload=0; download=0; total=0; expire=1893456000',
        );
        request.response.write(
          'naive+https://user:pass@example.com:443#Naive\n'
          'vless://11111111-1111-4111-8111-111111111111@example.com:443?security=reality&pbk=abc123#Reality',
        );
        return request.response.close();
      }),
    );
    final source = 'http://${server.address.host}:${server.port}/s/token/';

    final profiles = await ProfileImporter().importFromText(source);

    expect(profiles, hasLength(2));
    expect(profiles.first.subscriptionSource, source);
    expect(profiles.first.originalInput, startsWith('naive+https://'));
    expect(profiles.first.subscriptionExpiresAt, isNotNull);
  });

  test('tries links.txt for root /s/token/ subscriptions', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) {
      if (request.uri.path.endsWith('/links.txt')) {
        request.response.headers.set(
          'subscription-userinfo',
          'upload=0; download=0; total=0; expire=1893456000',
        );
        request.response.write(
          'naive+https://user:pass@example.com:443#Naive\n'
          'hy2://secret@example.com:443#Turbo',
        );
      } else {
        request.response
          ..headers.contentType = ContentType.html
          ..write('<html><body>subscription landing</body></html>');
      }
      unawaited(request.response.close());
    });

    final source = 'http://${server.address.host}:${server.port}/s/token/';
    final profiles = await ProfileImporter().importFromText(source);

    expect(profiles, hasLength(2));
    expect(profiles.map((profile) => profile.kind), [
      VpnProfileKind.naive,
      VpnProfileKind.hysteria2,
    ]);
    expect(profiles.first.subscriptionSource, source);
    expect(profiles.first.subscriptionExpiresAt, isNotNull);
  });

  test('imports Remnawave Xray JSON subscription', () async {
    final payload = jsonEncode([
      {
        'remarks': 'Russia',
        'outbounds': [
          {
            'protocol': 'vless',
            'tag': 'proxy',
            'settings': {
              'vnext': [
                {
                  'address': 'dns-ai.online',
                  'port': 443,
                  'users': [
                    {
                      'id': '11111111-1111-4111-8111-111111111111',
                      'encryption': 'none',
                      'flow': 'xtls-rprx-vision',
                    },
                  ],
                },
              ],
            },
            'streamSettings': {
              'network': 'tcp',
              'security': 'reality',
              'realitySettings': {
                'serverName': 'dns-ai.online',
                'publicKey': 'abc123',
                'shortId': '01',
                'fingerprint': 'chrome',
              },
            },
          },
        ],
      },
    ]);

    final profiles = await ProfileImporter().importFromText(payload);

    expect(profiles, hasLength(1));
    expect(profiles.first.kind, VpnProfileKind.vlessReality);
    expect(profiles.first.originalInput, startsWith('vless://'));
    expect(profiles.first.outbound?['tls']['reality']['public_key'], 'abc123');
  });

  test('imports HTML subscription page with embedded profile links', () async {
    const html = '''
<!doctype html>
<html>
  <body>
    <a href="naive+https://user:pass@net-it.pro:443#naive">naive</a>
    <a href="hy2://secret@net-it.pro:8443/?sni=net-it.pro&amp;obfs=salamander&amp;obfs-password=obfs-secret#ivan-hy2">hy2</a>
    <a href="vless://11111111-1111-4111-8111-111111111111@net-it.pro:8444?security=reality&amp;type=tcp&amp;flow=xtls-rprx-vision&amp;sni=www.microsoft.com&amp;fp=chrome&amp;pbk=abc123&amp;sid=01#ivan-reality">reality</a>
    <a href="vless://11111111-1111-4111-8111-111111111111@net-it.pro:8446?security=none&amp;type=mkcp#ivan-mkcp">mkcp</a>
    <a href="vless://11111111-1111-4111-8111-111111111111@net-it.pro:8447?security=tls&amp;type=grpc&amp;serviceName=vless-grpc&amp;sni=net-it.pro&amp;fp=chrome#ivan-grpc">grpc</a>
  </body>
</html>
''';

    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) {
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType.html
        ..write(html)
        ..close();
    });

    try {
      final profiles = await ProfileImporter().importFromText(
        'http://${server.address.address}:${server.port}/s/token/',
      );

      expect(profiles.map((profile) => profile.name), contains('naive'));
      expect(profiles.map((profile) => profile.name), contains('ivan-hy2'));
      expect(profiles.map((profile) => profile.name), contains('ivan-reality'));
      expect(profiles.map((profile) => profile.name), contains('ivan-mkcp'));
      expect(profiles.map((profile) => profile.name), contains('ivan-grpc'));

      final hysteria = profiles.firstWhere(
        (profile) => profile.kind == VpnProfileKind.hysteria2,
      );
      expect(hysteria.outbound?['obfs'], {
        'type': 'salamander',
        'password': 'obfs-secret',
      });

      final grpc = profiles.firstWhere(
        (profile) => profile.name == 'ivan-grpc',
      );
      expect(grpc.outbound?['transport'], {
        'type': 'grpc',
        'service_name': 'vless-grpc',
      });

      final mkcp = profiles.firstWhere(
        (profile) => profile.name == 'ivan-mkcp',
      );
      expect(mkcp.kind, VpnProfileKind.vlessMkcp);
      expect(mkcp.outbound?['unsupported_transport'], 'mkcp');
    } finally {
      await server.close(force: true);
    }
  });
}
