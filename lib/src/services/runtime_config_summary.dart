import 'dart:convert';

import 'sing_box_config_builder.dart';
import 'xray_config_builder.dart';

/// Produces the connection log summary for a serialized runtime config.
///
/// This is not a sanitizer: existing diagnostics include SNI and DNS values.
/// The report boundary is responsible for redacting sensitive data.
class RuntimeConfigSummary {
  static String summarize(
    String config, {
    required SingBoxConfigTarget target,
  }) {
    try {
      final decoded = jsonDecode(config);
      if (decoded is! Map) {
        return 'target=${target.name}; raw/custom config';
      }
      final map = decoded.cast<String, dynamic>();
      final yurichRuntime = (map['_yurich'] as Map?)?.cast<String, dynamic>();
      if (yurichRuntime?['core'] == XrayConfigBuilder.runtimeCore) {
        final xray = (map['xray'] as Map?)?.cast<String, dynamic>();
        if (xray == null) {
          return 'target=${target.name}; core=xray; invalid wrapper';
        }
        return _summarizeXrayConfig(xray, target: target);
      }
      final inbounds = ((map['inbounds'] as List?) ?? const [])
          .whereType<Map>()
          .map((item) => item.cast<String, dynamic>())
          .toList();
      final tun = inbounds.firstWhere(
        (inbound) => inbound['type'] == 'tun',
        orElse: () => const <String, dynamic>{},
      );
      final excludedPackages = ((tun['exclude_package'] as List?) ?? const [])
          .whereType<String>()
          .toList();
      final hasMixedProxy = inbounds.any(
        (inbound) =>
            inbound['type'] == 'mixed' &&
            inbound['listen'] == '127.0.0.1' &&
            inbound['listen_port'] == SingBoxConfigBuilder.localMixedProxyPort,
      );
      final route = (map['route'] as Map?)?.cast<String, dynamic>() ?? const {};
      final routeRules = ((route['rules'] as List?) ?? const [])
          .whereType<Map>()
          .map((item) => item.cast<String, dynamic>())
          .toList();
      final smartRouteEnabled = routeRules.any(
        (rule) =>
            rule['outbound'] == 'direct' &&
            (rule['domain_suffix'] as List?)?.contains('gosuslugi.ru') == true,
      );
      final smartRouteProxyRules = routeRules
          .where(
            (rule) =>
                rule['outbound'] == 'proxy' &&
                (rule.containsKey('domain') ||
                    rule.containsKey('domain_suffix')),
          )
          .length;
      final outbounds = ((map['outbounds'] as List?) ?? const [])
          .whereType<Map>()
          .map((item) => item.cast<String, dynamic>())
          .toList();
      final proxy = outbounds.firstWhere(
        (outbound) => outbound['tag'] == 'proxy',
        orElse: () =>
            outbounds.isEmpty ? const <String, dynamic>{} : outbounds.first,
      );
      final proxyTls = (proxy['tls'] as Map?)?.cast<String, dynamic>();
      final proxyReality = (proxyTls?['reality'] as Map?)
          ?.cast<String, dynamic>();
      final proxyUtls = (proxyTls?['utls'] as Map?)?.cast<String, dynamic>();
      final dns = (map['dns'] as Map?)?.cast<String, dynamic>() ?? const {};
      final dnsFinal = dns['final'] ?? 'unknown';
      final dnsServers = ((dns['servers'] as List?) ?? const [])
          .whereType<Map>()
          .map((item) => item.cast<String, dynamic>())
          .toList();
      final hasFakeDns = dnsServers.any((server) => server['type'] == 'fakeip');
      final dnsServer = dnsServers.firstWhere(
        (server) => server['tag'] == dnsFinal,
        orElse: () => const <String, dynamic>{},
      );
      final dnsDetour = dnsServer['detour'];
      final hasRemoteDns = dnsServers.whereType<Map>().any((server) {
        final tag = server['tag'];
        return tag == 'remote-dns' ||
            (tag is String &&
                (tag == 'remote-dns-primary' || tag == 'remote-dns-secondary'));
      });
      return [
        'target=${target.name}',
        'proxy=${proxy['type'] ?? 'unknown'}',
        'dns=$dnsFinal/${dnsServer['type'] ?? 'unknown'}',
        if (hasRemoteDns) 'dns_leak_guard=true',
        if (dnsDetour != null) 'dns_detour=$dnsDetour',
        if (hasFakeDns) 'fake_dns=true',
        'mtu=${tun['mtu'] ?? 'unknown'}',
        'strict_route=${tun['strict_route'] ?? 'unknown'}',
        'stack=${tun['stack'] ?? 'unknown'}',
        'smart_route=$smartRouteEnabled',
        if (smartRouteEnabled)
          'ru_bypass_packages=${excludedPackages.where((item) => item != "online.dnsai.ivanvpn").length}',
        if (smartRouteEnabled) 'global_proxy_rules=$smartRouteProxyRules',
        'network=${proxy['network_strategy'] ?? 'default'}',
        if (proxy['type'] == 'http') 'mode=https-connect',
        if (proxy['type'] == 'naive') 'mode=naive-native',
        if (proxy['type'] == 'http' || proxy['type'] == 'naive')
          'health_probe=mixed-proxy',
        if (proxy['type'] == 'naive')
          'transport=${proxy['quic'] == true ? 'h3/quic' : 'h2'}',
        if (proxy['type'] == 'vless')
          'packet=${proxy['packet_encoding'] ?? 'default'}',
        if (proxy['type'] == 'vless')
          'mode=${proxyReality?['enabled'] == true ? 'reality-tcp' : 'tls'}',
        if (proxy['type'] == 'vless') 'flow=${proxy['flow'] ?? 'default'}',
        if (proxy['type'] == 'vless')
          'sni=${proxyTls?['server_name'] ?? 'unknown'}',
        if (proxy['type'] == 'vless')
          'utls=${proxyUtls?['fingerprint'] ?? 'default'}',
        if (proxy['type'] == 'hysteria2' || proxy['type'] == 'hysteria')
          'transport=udp',
        'mixed_proxy=$hasMixedProxy',
      ].join('; ');
    } on Object {
      return 'target=${target.name}; raw/custom config';
    }
  }

  static String _summarizeXrayConfig(
    Map<String, dynamic> map, {
    required SingBoxConfigTarget target,
  }) {
    final inbounds = ((map['inbounds'] as List?) ?? const [])
        .whereType<Map>()
        .map((item) => item.cast<String, dynamic>())
        .toList();
    final tun = inbounds.firstWhere(
      (inbound) => inbound['protocol'] == 'tun',
      orElse: () => const <String, dynamic>{},
    );
    final tunSettings =
        (tun['settings'] as Map?)?.cast<String, dynamic>() ??
        const <String, dynamic>{};

    final outbounds = ((map['outbounds'] as List?) ?? const [])
        .whereType<Map>()
        .map((item) => item.cast<String, dynamic>())
        .toList();
    final proxy = outbounds.firstWhere(
      (outbound) => outbound['tag'] == 'proxy',
      orElse: () =>
          outbounds.isEmpty ? const <String, dynamic>{} : outbounds.first,
    );
    final stream =
        (proxy['streamSettings'] as Map?)?.cast<String, dynamic>() ??
        const <String, dynamic>{};
    final reality = (stream['realitySettings'] as Map?)
        ?.cast<String, dynamic>();
    final tls = (stream['tlsSettings'] as Map?)?.cast<String, dynamic>();
    final xhttp =
        (stream['xhttpSettings'] as Map?)?.cast<String, dynamic>() ??
        const <String, dynamic>{};
    final dns = (map['dns'] as Map?)?.cast<String, dynamic>() ?? const {};
    final route = (map['routing'] as Map?)?.cast<String, dynamic>() ?? const {};
    final routeRules = ((route['rules'] as List?) ?? const [])
        .whereType<Map>()
        .map((item) => item.cast<String, dynamic>())
        .toList();
    final smartRouteEnabled = routeRules.any(
      (rule) =>
          rule['outboundTag'] == 'direct' &&
          (rule['domain'] as List?)?.contains('domain:gosuslugi.ru') == true,
    );

    return [
      'target=${target.name}',
      'core=xray',
      'proxy=${proxy['protocol'] ?? 'unknown'}',
      'transport=${stream['network'] ?? 'unknown'}',
      'security=${stream['security'] ?? 'unknown'}',
      'xhttp_mode=${xhttp['mode'] ?? 'default'}',
      'dns=${((dns['servers'] as List?) ?? const []).join(',')}',
      'route_final=${route['final'] ?? 'missing'}',
      'smart_route=$smartRouteEnabled',
      'mtu=${tunSettings['mtu'] ?? 'unknown'}',
      'gateway=${tunSettings['gateway'] ?? 'unknown'}',
      'sni=${reality?['serverName'] ?? tls?['serverName'] ?? 'unknown'}',
      if (reality != null) 'reality=true',
      'mixed_proxy=false',
    ].join('; ');
  }
}
