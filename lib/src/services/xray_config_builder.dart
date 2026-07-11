import 'dart:convert';
import 'dart:io';

import '../models/dns_protection_mode.dart';
import '../models/vpn_profile.dart';
import 'smart_route_rules.dart';
import 'vless_profile_validator.dart';

class XrayConfigBuilder {
  static const runtimeCore = 'xray';
  static const runtimeSchema = 1;
  static const _dnsOutboundTag = 'dns-out';
  static const _healthProxyPort = 20808;
  static const _tunDnsServers = ['1.1.1.1', '8.8.8.8'];
  static const _tunGateways = ['172.19.0.1/30', 'fdfe:dcba:9876::1/126'];

  String build(
    VpnProfile profile, {
    bool smartRouteRuDirect = false,
    List<String> smartRouteRuBypassPackages = const [],
    DnsProtectionMode dnsProtectionMode = DnsProtectionMode.stable,
  }) {
    if (profile.kind != VpnProfileKind.vlessXhttp &&
        profile.kind != VpnProfileKind.vlessReality) {
      throw UnsupportedError('Xray builder supports only VLESS XHTTP/Reality.');
    }

    final rawOutbound = profile.outbound;
    if (rawOutbound == null) {
      throw StateError('У VLESS-профиля нет outbound-конфига.');
    }
    final outbound = profile.kind == VpnProfileKind.vlessReality
        ? VlessProfileValidator.normalizeRealityTcpOutbound(rawOutbound)
        : rawOutbound;

    final config = <String, dynamic>{
      'log': {'loglevel': 'warning'},
      'dns': {
        'tag': 'dns-generated',
        'servers': _dnsServers(profile, dnsProtectionMode),
        'queryStrategy': 'UseIPv4',
        'disableFallback': false,
        'disableFallbackIfMatch': false,
      },
      'inbounds': [
        {
          'tag': 'tun-in',
          'protocol': 'tun',
          'settings': {
            'name': 'yurich-xray0',
            'mtu': 1380,
            'gateway': _tunGateways,
            'dns': _tunDnsServers,
            'userLevel': 0,
          },
          'sniffing': {
            'enabled': true,
            'destOverride': ['http', 'tls', 'quic'],
            'routeOnly': false,
          },
        },
        {
          'tag': 'health-http-in',
          'listen': '127.0.0.1',
          'port': _healthProxyPort,
          'protocol': 'http',
          'settings': {'allowTransparent': false},
        },
      ],
      'outbounds': [
        _vlessOutbound(profile, outbound),
        {'tag': _dnsOutboundTag, 'protocol': 'dns'},
        {
          'tag': 'direct',
          'protocol': 'freedom',
          'settings': {'domainStrategy': 'UseIPv4'},
        },
        {'tag': 'block', 'protocol': 'blackhole'},
      ],
      'routing': {
        'domainStrategy': 'IPIfNonMatch',
        'rules': [
          {
            'type': 'field',
            'protocol': ['dns'],
            'outboundTag': _dnsOutboundTag,
          },
          {'type': 'field', 'port': '53', 'outboundTag': _dnsOutboundTag},
          {
            'type': 'field',
            'inboundTag': ['dns-generated'],
            'outboundTag': 'proxy',
          },
          if (smartRouteRuDirect) ..._smartRouteRules(),
          {
            'type': 'field',
            'ip': [
              '127.0.0.0/8',
              '10.0.0.0/8',
              '172.16.0.0/12',
              '192.168.0.0/16',
              '169.254.0.0/16',
              '::1/128',
              'fc00::/7',
              'fe80::/10',
            ],
            'outboundTag': 'direct',
          },
          {
            'type': 'field',
            'protocol': ['bittorrent'],
            'outboundTag': 'block',
          },
          {'type': 'field', 'network': 'tcp,udp', 'outboundTag': 'proxy'},
        ],
      },
    };

    return const JsonEncoder.withIndent('  ').convert({
      '_yurich': {
        'core': runtimeCore,
        'schema': runtimeSchema,
        'profileKind': profile.kind.name,
      },
      'xray': config,
    });
  }

  List<Map<String, dynamic>> _smartRouteRules() {
    return [
      {
        'type': 'field',
        'domain': [
          for (final domain in SmartRouteRules.globalProxyDomains)
            'full:$domain',
        ],
        'outboundTag': 'proxy',
      },
      {
        'type': 'field',
        'domain': [
          for (final domain in SmartRouteRules.globalProxyDomainSuffixes)
            'domain:$domain',
        ],
        'outboundTag': 'proxy',
      },
      {
        'type': 'field',
        'domain': [
          for (final domain in SmartRouteRules.ruDirectDomains) 'full:$domain',
        ],
        'outboundTag': 'direct',
      },
      {
        'type': 'field',
        'domain': [
          for (final domain in SmartRouteRules.ruDirectDomainSuffixes)
            'domain:$domain',
        ],
        'outboundTag': 'direct',
      },
    ];
  }

  List<Map<String, dynamic>> _dnsServers(
    VpnProfile profile,
    DnsProtectionMode dnsProtectionMode,
  ) {
    final server = profile.server?.trim();
    final bootstrap =
        server != null && server.isNotEmpty && !_isIpLiteral(server)
        ? <Map<String, dynamic>>[
            {
              'address': 'localhost',
              'domains': ['full:$server'],
              'skipFallback': true,
              'finalQuery': true,
              'queryStrategy': 'UseIPv4',
            },
          ]
        : const <Map<String, dynamic>>[];
    if (!dnsProtectionMode.protectsAgainstLeaks) {
      return [
        ...bootstrap,
        for (final server in _tunDnsServers)
          {'address': server, 'queryStrategy': 'UseIPv4', 'timeoutMs': 4000},
      ];
    }

    return [
      ...bootstrap,
      {
        'tag': 'remote-dns',
        'address': 'https://1.1.1.1/dns-query',
        'queryStrategy': 'UseIPv4',
        'timeoutMs': 5000,
      },
      {
        'address': 'https://8.8.8.8/dns-query',
        'queryStrategy': 'UseIPv4',
        'timeoutMs': 5000,
      },
    ];
  }

  bool _isIpLiteral(String value) => InternetAddress.tryParse(value) != null;

  Map<String, dynamic> _vlessOutbound(
    VpnProfile profile,
    Map<String, dynamic> outbound,
  ) {
    final server = _string(outbound['server']) ?? profile.server;
    final port = _int(outbound['server_port']) ?? profile.port ?? 443;
    final uuid = _string(outbound['uuid']);
    if (server == null || server.isEmpty) {
      throw StateError('XHTTP-профиль без server.');
    }
    if (uuid == null || uuid.isEmpty) {
      throw StateError('XHTTP-профиль без uuid.');
    }

    final tls = _map(outbound['tls']) ?? const <String, dynamic>{};
    final reality = _map(tls['reality']);
    final hasReality = reality != null && reality['enabled'] == true;
    final utls = _map(tls['utls']);
    final transport = _map(outbound['transport']);
    final transportType =
        _string(transport?['type'])?.toLowerCase() ??
        _string(outbound['network'])?.toLowerCase() ??
        (profile.kind == VpnProfileKind.vlessXhttp ? 'xhttp' : 'tcp');
    final xhttp = transportType == 'xhttp'
        ? _xhttpSettings(transport)
        : const <String, dynamic>{};

    final streamSettings = <String, dynamic>{
      'network': transportType == 'xhttp' ? 'xhttp' : 'tcp',
      if (xhttp.isNotEmpty) 'xhttpSettings': xhttp,
      if (hasReality) ...{
        'security': 'reality',
        'realitySettings': {
          'serverName': _string(tls['server_name']) ?? server,
          if (_string(reality['public_key'])?.isNotEmpty == true)
            'publicKey': _string(reality['public_key']),
          if (_string(reality['short_id'])?.isNotEmpty == true)
            'shortId': _string(reality['short_id']),
          if (_string(utls?['fingerprint'])?.isNotEmpty == true)
            'fingerprint': _string(utls?['fingerprint']),
          'spiderX': '/',
        },
      } else ...{
        'security': 'tls',
        'tlsSettings': {
          'serverName': _string(tls['server_name']) ?? server,
          if (tls['insecure'] == true) 'allowInsecure': true,
          if (_string(utls?['fingerprint'])?.isNotEmpty == true)
            'fingerprint': _string(utls?['fingerprint']),
          if (tls['alpn'] is List) 'alpn': tls['alpn'],
        },
      },
    };

    final user = <String, dynamic>{
      'id': uuid,
      'encryption': 'none',
      if (_string(outbound['flow'])?.isNotEmpty == true)
        'flow': _string(outbound['flow']),
      'level': 0,
    };

    return {
      'tag': 'proxy',
      'protocol': 'vless',
      'settings': {
        'vnext': [
          {
            'address': server,
            'port': port,
            'users': [user],
          },
        ],
      },
      'streamSettings': streamSettings,
    };
  }

  Map<String, dynamic> _xhttpSettings(Map<String, dynamic>? transport) {
    if (transport == null) {
      return const <String, dynamic>{};
    }

    final headers = _map(transport['headers']);
    final host =
        _string(transport['host']) ??
        _string(headers?['Host']) ??
        _string(headers?['host']);
    final sanitizedHeaders = <String, dynamic>{
      if (headers != null)
        for (final entry in headers.entries)
          if (entry.key.toLowerCase() != 'host') entry.key: entry.value,
    };
    final extra = transport['extra'];
    final xmux = transport['xmux'];
    final normalizedExtra = extra is String && extra.isNotEmpty
        ? _tryJson(extra) ?? extra
        : extra;
    final extraSettings = <String, dynamic>{
      if (normalizedExtra is Map)
        for (final entry in normalizedExtra.entries)
          entry.key.toString(): entry.value,
      if (sanitizedHeaders.isNotEmpty) 'headers': sanitizedHeaders,
      if (xmux != null) 'xmux': xmux is String ? _tryJson(xmux) ?? xmux : xmux,
    };
    final mode = _xhttpMode(_string(transport['mode']));

    final settings = <String, dynamic>{
      if (_string(transport['path'])?.isNotEmpty == true)
        'path': _string(transport['path']),
      if (host != null && host.isNotEmpty) 'host': host,
    };
    if (mode != null) {
      settings['mode'] = mode;
    }
    if (extraSettings.isNotEmpty) {
      settings['extra'] = extraSettings;
    } else if (normalizedExtra is List || normalizedExtra is String) {
      settings['extra'] = normalizedExtra;
    }
    return settings;
  }

  String? _xhttpMode(String? value) {
    final normalized = value?.trim().toLowerCase();
    if (normalized == null || normalized.isEmpty) {
      return null;
    }
    const supportedModes = {'auto', 'packet-up', 'stream-up', 'stream-one'};
    return supportedModes.contains(normalized) ? normalized : value;
  }

  Map<String, dynamic>? _map(Object? value) =>
      (value as Map?)?.cast<String, dynamic>();

  String? _string(Object? value) => value?.toString();

  int? _int(Object? value) => switch (value) {
    int() => value,
    num() => value.toInt(),
    String() => int.tryParse(value),
    _ => null,
  };

  Object? _tryJson(String value) {
    try {
      return jsonDecode(value);
    } on FormatException {
      return null;
    }
  }
}
