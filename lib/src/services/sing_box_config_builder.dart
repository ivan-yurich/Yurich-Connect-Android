import 'dart:convert';
import 'dart:io';

import '../models/dns_protection_mode.dart';
import '../models/vpn_profile.dart';
import 'profile_engine_selector.dart';
import 'smart_route_rules.dart';
import 'vless_profile_validator.dart';

enum SingBoxConfigTarget { android }

enum NaiveOutboundMode { auto, native, httpConnect }

class SingBoxConfigBuilder {
  static const localMixedProxyPort = 20808;
  static const _remoteDnsTag = 'remote-dns-primary';
  static const _localDnsTag = 'local-dns';
  static const _tunIpv4Address = '172.19.0.1/30';
  static const _tunIpv6Address = 'fdfe:dcba:9876::1/126';

  String build(
    VpnProfile profile, {
    NaiveOutboundMode naiveMode = NaiveOutboundMode.auto,
    bool smartRouteRuDirect = false,
    List<String> smartRouteRuBypassPackages = const [],
    DnsProtectionMode dnsProtectionMode = DnsProtectionMode.stable,
  }) {
    if (profile.kind == VpnProfileKind.singBoxConfig) {
      final raw = profile.rawConfig;
      if (raw == null || raw.trim().isEmpty) {
        throw StateError('Пустой sing-box config.');
      }
      return raw;
    }

    final outbound = profile.outbound;
    if (outbound == null) {
      throw StateError('У профиля нет outbound-конфига.');
    }

    final engine = ProfileEngineSelector.select(profile);
    if (!engine.canRunInCurrentBuild ||
        engine.engine != VpnCoreEngine.singBox) {
      throw UnsupportedError(engine.reason);
    }

    final proxyOutbound =
        jsonDecode(jsonEncode(outbound)) as Map<String, dynamic>;
    proxyOutbound['tag'] = 'proxy';
    final useRemoteDns = _usesRemoteDns(profile, dnsProtectionMode);
    _normalizeOutbound(profile, proxyOutbound, naiveMode);
    _applyDialStability(profile: profile, proxyOutbound: proxyOutbound);
    final rejectUnsupportedUdp = profile.kind == VpnProfileKind.naive;

    final config = <String, dynamic>{
      'log': {'level': 'warn', 'timestamp': true},
      'dns': _dnsConfig(profile, useRemoteDns: useRemoteDns),
      'inbounds': [
        _tunInbound(
          smartRouteRuDirect: smartRouteRuDirect,
          smartRouteRuBypassPackages: smartRouteRuBypassPackages,
        ),
        _mixedInbound(),
      ],
      'outbounds': [
        proxyOutbound,
        {'type': 'direct', 'tag': 'direct'},
      ],
      'route': {
        'rules': [
          {'action': 'sniff'},
          {
            'type': 'logical',
            'mode': 'or',
            'rules': [
              {'protocol': 'dns'},
              {'port': 53},
            ],
            'action': 'hijack-dns',
          },
          _unsupportedUdpRule(rejectUnsupportedUdp),
          {
            'ip_cidr': ['198.18.0.0/15', 'fc00::/18'],
            'outbound': 'proxy',
          },
          if (smartRouteRuDirect) ..._smartRouteRules(),
          {'ip_is_private': true, 'outbound': 'direct'},
        ],
        'default_domain_resolver': useRemoteDns ? _remoteDnsTag : _localDnsTag,
        'auto_detect_interface': true,
        'final': 'proxy',
      },
    };

    return const JsonEncoder.withIndent('  ').convert(config);
  }

  Map<String, dynamic> _tunInbound({
    required bool smartRouteRuDirect,
    required List<String> smartRouteRuBypassPackages,
  }) {
    final inbound = <String, dynamic>{
      'type': 'tun',
      'tag': 'tun-in',
      'address': [_tunIpv4Address, _tunIpv6Address],
      'mtu': 1380,
      'auto_route': true,
      'strict_route': true,
      'stack': 'gvisor',
    };
    inbound['interface_name'] = 'tun0';
    inbound['exclude_package'] = [
      'online.dnsai.ivanvpn',
      if (smartRouteRuDirect)
        ...SmartRouteRules.ruBypassPackages(smartRouteRuBypassPackages),
    ];
    return inbound;
  }

  List<Map<String, dynamic>> _smartRouteRules() {
    return [
      {'domain': SmartRouteRules.globalProxyDomains, 'outbound': 'proxy'},
      {
        'domain_suffix': SmartRouteRules.globalProxyDomainSuffixes,
        'outbound': 'proxy',
      },
      {'domain': SmartRouteRules.ruDirectDomains, 'outbound': 'direct'},
      {
        'domain_suffix': SmartRouteRules.ruDirectDomainSuffixes,
        'outbound': 'direct',
      },
    ];
  }

  Map<String, dynamic> _mixedInbound() {
    return {
      'type': 'mixed',
      'tag': 'mixed-in',
      'listen': '127.0.0.1',
      'listen_port': localMixedProxyPort,
    };
  }

  Map<String, dynamic> _dnsConfig(
    VpnProfile profile, {
    required bool useRemoteDns,
  }) {
    const remoteDnsServers = <Map<String, dynamic>>[
      {
        'type': 'https',
        'tag': 'remote-dns-primary',
        'server': '1.1.1.1',
        'server_port': 443,
        'path': '/dns-query',
        'tls': {'enabled': true, 'server_name': 'cloudflare-dns.com'},
        'detour': 'proxy',
      },
      {
        'type': 'https',
        'tag': 'remote-dns-secondary',
        'server': '8.8.8.8',
        'server_port': 443,
        'path': '/dns-query',
        'tls': {'enabled': true, 'server_name': 'dns.google'},
        'detour': 'proxy',
      },
    ];
    final servers = <Map<String, dynamic>>[
      {'type': 'local', 'tag': _localDnsTag},
      if (useRemoteDns) ...remoteDnsServers,
      {
        'type': 'fakeip',
        'tag': 'fakeip',
        'inet4_range': '198.18.0.0/15',
        'inet6_range': 'fc00::/18',
      },
    ];

    final rules = <Map<String, dynamic>>[];
    final server = profile.server?.trim();
    if (server != null && server.isNotEmpty && !_isIpLiteral(server)) {
      rules.add({
        'domain': [server],
        'action': 'route',
        'server': _localDnsTag,
      });
    }
    rules.add({
      'inbound': ['tun-in'],
      'query_type': ['A', 'AAAA'],
      'action': 'route',
      'server': 'fakeip',
    });
    return {
      'servers': servers,
      'rules': rules,
      'strategy': 'ipv4_only',
      'cache_capacity': 8192,
      'reverse_mapping': true,
      'final': useRemoteDns ? _remoteDnsTag : _localDnsTag,
    };
  }

  bool _usesRemoteDns(VpnProfile profile, DnsProtectionMode dnsProtectionMode) {
    if (!dnsProtectionMode.protectsAgainstLeaks) {
      return false;
    }
    return switch (profile.kind) {
      VpnProfileKind.hysteria ||
      VpnProfileKind.hysteria2 ||
      VpnProfileKind.vlessReality ||
      VpnProfileKind.vlessTls => true,
      VpnProfileKind.naive ||
      VpnProfileKind.vlessXhttp ||
      VpnProfileKind.vlessMkcp ||
      VpnProfileKind.pingTunnelExperimental ||
      VpnProfileKind.singBoxConfig => false,
    };
  }

  bool _isIpLiteral(String value) => InternetAddress.tryParse(value) != null;

  Map<String, dynamic> _unsupportedUdpRule(bool rejectAllUdp) {
    return {
      'type': 'logical',
      'mode': 'or',
      'rules': [
        {'port': 853},
        {'protocol': 'stun'},
        {'protocol': 'icmp'},
        if (rejectAllUdp) {'network': 'udp', 'port': 443},
        if (rejectAllUdp) {'network': 'udp'},
      ],
      'action': 'reject',
    };
  }

  void _applyDialStability({
    required VpnProfile profile,
    required Map<String, dynamic> proxyOutbound,
  }) {
    proxyOutbound.putIfAbsent('connect_timeout', () => '8s');
    proxyOutbound.putIfAbsent('tcp_keep_alive', () => '3m');
    proxyOutbound.putIfAbsent('tcp_keep_alive_interval', () => '30s');
    proxyOutbound.putIfAbsent('domain_resolver', () => _localDnsTag);
    proxyOutbound.putIfAbsent('domain_strategy', () => 'ipv4_only');
    proxyOutbound.putIfAbsent('network_strategy', () => 'fallback');
    proxyOutbound.putIfAbsent(
      'fallback_delay',
      () =>
          profile.kind == VpnProfileKind.hysteria2 ||
              profile.kind == VpnProfileKind.hysteria
          ? '300ms'
          : '200ms',
    );
  }

  void _normalizeOutbound(
    VpnProfile profile,
    Map<String, dynamic> proxyOutbound,
    NaiveOutboundMode naiveMode,
  ) {
    if (profile.kind == VpnProfileKind.vlessReality ||
        profile.kind == VpnProfileKind.vlessTls) {
      if (profile.kind == VpnProfileKind.vlessReality) {
        final normalized = VlessProfileValidator.normalizeRealityTcpOutbound(
          proxyOutbound,
        );
        proxyOutbound
          ..clear()
          ..addAll(normalized);
        return;
      }
      if (proxyOutbound['network'] == 'tcp') {
        proxyOutbound.remove('network');
      }
      proxyOutbound.putIfAbsent('packet_encoding', () => 'xudp');
      return;
    }

    if (profile.kind != VpnProfileKind.naive) {
      return;
    }

    final originalTls = (proxyOutbound['tls'] as Map?)?.cast<String, dynamic>();
    final outboundType = (proxyOutbound['type'] as String?)?.toLowerCase();
    final useHttpConnect =
        naiveMode == NaiveOutboundMode.httpConnect ||
        (naiveMode == NaiveOutboundMode.auto && outboundType == 'http');

    if (!useHttpConnect) {
      proxyOutbound['type'] = 'naive';
      if (naiveMode == NaiveOutboundMode.native ||
          naiveMode == NaiveOutboundMode.auto) {
        proxyOutbound['quic'] = false;
        proxyOutbound.remove('quic_congestion_control');
      }
    } else {
      proxyOutbound['type'] = 'http';
      proxyOutbound.remove('extra_headers');
      proxyOutbound.remove('insecure_concurrency');
      proxyOutbound.remove('quic');
      proxyOutbound.remove('quic_congestion_control');
      proxyOutbound.remove('udp_over_tcp');
    }

    final normalizedTls = <String, dynamic>{};
    for (final key in const [
      'server_name',
      'certificate',
      'certificate_path',
      'ech',
    ]) {
      final value = originalTls?[key];
      if (value != null) {
        normalizedTls[key] = value;
      }
    }

    normalizedTls['enabled'] = true;
    normalizedTls.putIfAbsent(
      'server_name',
      () => profile.server ?? proxyOutbound['server'],
    );
    proxyOutbound['tls'] = normalizedTls;
  }
}
