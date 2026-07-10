import '../models/vpn_profile.dart';

class VlessValidationResult {
  const VlessValidationResult({
    required this.ok,
    this.message,
    this.details = const {},
  });

  final bool ok;
  final String? message;
  final Map<String, String> details;
}

class VlessProfileValidator {
  const VlessProfileValidator._();

  static bool get isSupportedRealityTcpOnly => true;

  static VlessValidationResult validate(VpnProfile profile) {
    if (profile.kind != VpnProfileKind.vlessReality) {
      return const VlessValidationResult(ok: true);
    }
    final outbound = profile.outbound;
    if (outbound == null) {
      return const VlessValidationResult(
        ok: false,
        message: 'VLESS Reality профиль без outbound-конфига.',
      );
    }
    return validateOutbound(outbound);
  }

  static VlessValidationResult validateOutbound(Map<String, dynamic> outbound) {
    final type = outbound['type']?.toString().toLowerCase();
    if (type != 'vless') {
      return const VlessValidationResult(
        ok: false,
        message: 'VLESS Reality профиль содержит не VLESS outbound.',
      );
    }

    final server = outbound['server']?.toString().trim() ?? '';
    final uuid = outbound['uuid']?.toString().trim() ?? '';
    final tls = _map(outbound['tls']);
    final reality = _map(tls?['reality']);
    final transport = _transport(outbound);
    final serverName = tls?['server_name']?.toString().trim() ?? '';
    final publicKey = reality?['public_key']?.toString().trim() ?? '';
    final shortId = reality?['short_id']?.toString().trim() ?? '';
    final flow = outbound['flow']?.toString().trim() ?? '';
    final packetEncoding = outbound['packet_encoding']?.toString().trim() ?? '';
    final insecure = tls?['insecure'] == true;
    final fingerprint =
        _map(tls?['utls'])?['fingerprint']?.toString().trim() ?? '';

    final errors = <String>[];
    if (server.isEmpty) {
      errors.add('host');
    }
    if (uuid.isEmpty) {
      errors.add('uuid');
    }
    if (tls?['enabled'] != true) {
      errors.add('tls.enabled');
    }
    if (insecure) {
      errors.add('tls.insecure');
    }
    if (reality?['enabled'] != true) {
      errors.add('reality.enabled');
    }
    if (serverName.isEmpty) {
      errors.add('sni/server_name');
    }
    if (publicKey.isEmpty) {
      errors.add('pbk/public_key');
    }
    if (transport != 'tcp') {
      errors.add('transport=$transport');
    }
    if (flow.isNotEmpty && flow != 'xtls-rprx-vision') {
      errors.add('flow=$flow');
    }
    if (packetEncoding.isNotEmpty && packetEncoding != 'xudp') {
      errors.add('packet_encoding=$packetEncoding');
    }

    if (errors.isNotEmpty) {
      return VlessValidationResult(
        ok: false,
        message:
            'VLESS Reality профиль неполный или несовместимый: ${errors.join(', ')}.',
        details: {
          'server': server,
          'transport': transport,
          'flow': flow.isEmpty ? 'default' : flow,
          'sni': serverName,
          'fingerprint': fingerprint,
          'short_id': shortId.isEmpty ? 'none' : shortId,
        },
      );
    }

    return VlessValidationResult(
      ok: true,
      details: {
        'server': server,
        'transport': transport,
        'flow': flow.isEmpty ? 'xtls-rprx-vision' : flow,
        'sni': serverName,
        'fingerprint': fingerprint.isEmpty ? 'chrome' : fingerprint,
        'short_id': shortId.isEmpty ? 'none' : shortId,
      },
    );
  }

  static Map<String, dynamic> normalizeRealityTcpOutbound(
    Map<String, dynamic> outbound,
  ) {
    final normalized = Map<String, dynamic>.from(outbound);
    normalized['type'] = 'vless';
    normalized.remove('unsupported_transport');
    normalized.remove('transport_options');

    final network = normalized['network']?.toString().trim().toLowerCase();
    if (network == null || network.isEmpty || network == 'tcp') {
      normalized.remove('network');
    }

    final transport = _map(normalized['transport']);
    final transportType =
        transport?['type']?.toString().trim().toLowerCase() ?? '';
    if (transportType.isEmpty || transportType == 'tcp') {
      normalized.remove('transport');
    }

    final packetEncoding = normalized['packet_encoding']?.toString().trim();
    if (packetEncoding == null || packetEncoding.isEmpty) {
      normalized['packet_encoding'] = 'xudp';
    }

    final flow = normalized['flow']?.toString().trim();
    if (flow == null || flow.isEmpty) {
      normalized['flow'] = 'xtls-rprx-vision';
    }

    final tls = _deepMap(normalized['tls']);
    tls['enabled'] = true;
    tls.remove('insecure');
    tls.putIfAbsent('server_name', () => normalized['server']);
    final utls = _deepMap(tls['utls']);
    utls['enabled'] = true;
    utls.putIfAbsent('fingerprint', () => 'chrome');
    tls['utls'] = utls;

    final reality = _deepMap(tls['reality']);
    reality['enabled'] = true;
    tls['reality'] = reality;
    normalized['tls'] = tls;

    final result = validateOutbound(normalized);
    if (!result.ok) {
      throw StateError(result.message ?? 'Некорректный VLESS Reality профиль.');
    }
    return normalized;
  }

  static String transportLabel(Map<String, dynamic>? outbound) {
    if (outbound == null) {
      return 'unknown';
    }
    return _transport(outbound);
  }

  static String _transport(Map<String, dynamic> outbound) {
    final unsupported = outbound['unsupported_transport']?.toString().trim();
    if (unsupported != null && unsupported.isNotEmpty) {
      return unsupported.toLowerCase();
    }
    final transport = _map(outbound['transport']);
    if (transport != null) {
      return (transport['type']?.toString().trim().toLowerCase() ?? 'tcp');
    }
    return (outbound['network']?.toString().trim().toLowerCase() ?? 'tcp');
  }

  static Map<String, dynamic>? _map(Object? value) =>
      value is Map ? value.cast<String, dynamic>() : null;

  static Map<String, dynamic> _deepMap(Object? value) {
    if (value is! Map) {
      return <String, dynamic>{};
    }
    return Map<String, dynamic>.from(value.cast<String, dynamic>());
  }
}
