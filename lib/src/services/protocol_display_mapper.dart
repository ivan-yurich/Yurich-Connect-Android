import '../models/vpn_profile.dart';

class ProtocolDisplayMapper {
  const ProtocolDisplayMapper._();

  static const naiveName = 'NaiveProxy';
  static const hysteriaName = 'Hysteria';
  static const hysteria2Name = 'Hysteria2';

  static String mapProfile(VpnProfile profile) {
    final outbound = profile.outbound;
    final transport = _transportFromOutbound(outbound);
    final security = _securityFromOutbound(outbound);

    return switch (profile.kind) {
      VpnProfileKind.vlessReality => mapProtocolToDisplayName(
        'vless',
        transport: transport ?? 'tcp',
        security: 'reality',
      ),
      VpnProfileKind.vlessTls => mapProtocolToDisplayName(
        'vless',
        transport: transport ?? 'tcp',
        security: security ?? 'tls',
      ),
      VpnProfileKind.vlessXhttp => mapProtocolToDisplayName(
        'vless',
        transport: 'xhttp',
        security: security ?? 'reality',
      ),
      VpnProfileKind.vlessMkcp => mapProtocolToDisplayName(
        'vless',
        transport: 'mkcp',
        security: security ?? 'reality',
      ),
      VpnProfileKind.naive => mapProtocolToDisplayName('naive'),
      VpnProfileKind.hysteria2 => mapProtocolToDisplayName('hysteria2'),
      VpnProfileKind.hysteria => mapProtocolToDisplayName('hysteria'),
      VpnProfileKind.singBoxConfig => profile.kind.label,
    };
  }

  static String mapProtocolToDisplayName(
    String protocol, {
    String? transport,
    String? security,
  }) {
    final normalizedProtocol = protocol.trim().toLowerCase();
    final normalizedTransport = (transport ?? '').trim().toLowerCase();
    final normalizedSecurity = (security ?? '').trim().toLowerCase();

    if (normalizedProtocol == 'vless' &&
        normalizedSecurity == 'reality' &&
        (normalizedTransport.isEmpty || normalizedTransport == 'tcp')) {
      return 'Reality';
    }
    if (normalizedProtocol == 'vless' &&
        (normalizedTransport == 'xhttp' ||
            normalizedTransport == 'splithttp')) {
      final securityName = switch (normalizedSecurity) {
        'reality' => ' (REALITY)',
        'tls' => ' (TLS)',
        _ => '',
      };
      return 'XHTTP$securityName';
    }
    if (normalizedProtocol == 'vless' &&
        normalizedSecurity == 'reality' &&
        normalizedTransport == 'grpc') {
      return 'Reality (gRPC)';
    }
    if (normalizedProtocol == 'naive' || normalizedProtocol == 'naiveproxy') {
      return naiveName;
    }
    if (normalizedProtocol == 'hysteria2' || normalizedProtocol == 'hy2') {
      return hysteria2Name;
    }
    if (normalizedProtocol == 'hysteria') {
      return hysteriaName;
    }
    if (normalizedProtocol == 'vless' && normalizedSecurity == 'tls') {
      return normalizedTransport == 'grpc' ? 'VLESS TLS (gRPC)' : 'VLESS TLS';
    }

    final fallback = protocol.trim();
    return fallback.isEmpty ? 'Unknown protocol' : fallback;
  }

  static String? _transportFromOutbound(Map<String, dynamic>? outbound) {
    final transport = outbound?['transport'];
    if (transport is Map) {
      return transport['type']?.toString();
    }
    return outbound?['network']?.toString();
  }

  static String? _securityFromOutbound(Map<String, dynamic>? outbound) {
    final tls = outbound?['tls'];
    if (tls is Map && tls['reality'] is Map) {
      return 'reality';
    }
    if (tls is Map && tls['enabled'] == true) {
      return 'tls';
    }
    return null;
  }
}
