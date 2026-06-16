import 'dart:convert';
import 'dart:io';

import '../models/vpn_profile.dart';
import 'smart_route_rules.dart';

enum SingBoxConfigTarget { android }

enum NaiveOutboundMode { auto, native, httpConnect }

class SingBoxConfigBuilder {
  static const localMixedProxyPort = 20808;

  String build(
    VpnProfile profile, {
    NaiveOutboundMode naiveMode = NaiveOutboundMode.auto,
    bool smartRouteRuDirect = false,
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

    if (!profile.kind.isClientSupported &&
        profile.kind != VpnProfileKind.naive) {
      throw UnsupportedError(
        '${profile.kind.label} отключён в этой Android-сборке. '
        'Используй VLESS Reality, NaiveProxy или Hysteria/Hysteria2.',
      );
    }

    final proxyOutbound =
        jsonDecode(jsonEncode(outbound)) as Map<String, dynamic>;
    proxyOutbound['tag'] = 'proxy';
    _normalizeOutbound(profile, proxyOutbound, naiveMode);
    _applyDialStability(proxyOutbound);
    final rejectUnsupportedUdp = profile.kind == VpnProfileKind.naive;

    final config = <String, dynamic>{
      'log': {'level': 'warn', 'timestamp': true},
      'dns': _dnsConfig(profile),
      'inbounds': [
        _tunInbound(smartRouteRuDirect: smartRouteRuDirect),
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
          if (smartRouteRuDirect) ..._smartRouteRules(),
          {'ip_is_private': true, 'outbound': 'direct'},
        ],
        'default_domain_resolver': 'local-dns',
        'auto_detect_interface': true,
        'final': 'proxy',
      },
    };

    return const JsonEncoder.withIndent('  ').convert(config);
  }

  Map<String, dynamic> _tunInbound({required bool smartRouteRuDirect}) {
    final inbound = <String, dynamic>{
      'type': 'tun',
      'tag': 'tun-in',
      'address': ['172.19.0.1/30'],
      'mtu': 1380,
      'auto_route': true,
      'strict_route': true,
      'stack': 'gvisor',
    };
    inbound['interface_name'] = 'tun0';
    inbound['exclude_package'] = [
      'online.dnsai.ivanvpn',
      if (smartRouteRuDirect) ...SmartRouteRules.ruDirectPackageNames,
    ];
    return inbound;
  }

  List<Map<String, dynamic>> _smartRouteRules() {
    return [
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

  Map<String, dynamic> _dnsConfig(VpnProfile profile) {
    final servers = <Map<String, dynamic>>[
      {'type': 'local', 'tag': 'local-dns'},
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
        'server': 'local-dns',
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
      'final': 'local-dns',
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

  void _applyDialStability(Map<String, dynamic> proxyOutbound) {
    proxyOutbound.putIfAbsent('connect_timeout', () => '8s');
    proxyOutbound.putIfAbsent('tcp_keep_alive', () => '3m');
    proxyOutbound.putIfAbsent('tcp_keep_alive_interval', () => '30s');
    proxyOutbound.putIfAbsent('domain_resolver', () => 'local-dns');
    proxyOutbound.putIfAbsent('domain_strategy', () => 'ipv4_only');
    proxyOutbound.putIfAbsent('network_strategy', () => 'fallback');
    proxyOutbound.putIfAbsent('fallback_delay', () => '300ms');
  }

  void _normalizeOutbound(
    VpnProfile profile,
    Map<String, dynamic> proxyOutbound,
    NaiveOutboundMode naiveMode,
  ) {
    if (profile.kind == VpnProfileKind.vlessReality ||
        profile.kind == VpnProfileKind.vlessTls) {
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
