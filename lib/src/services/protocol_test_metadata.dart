import 'dart:io';
import '../models/vpn_profile.dart';
import 'protocol_display_mapper.dart';

/// QA metadata only. Never serialize names, endpoint values or error messages.
class ProtocolTestMetadata {
  const ProtocolTestMetadata._();

  static final _offline = RegExp(
    r'offline|офлайн|оффлайн|не\s*работает|недоступен|отключ[её]н|expired|истекла',
    caseSensitive: false,
  );

  static bool isOfflineMarked(VpnProfile profile) =>
      _offline.hasMatch(profile.name);

  static Map<String, Object> profile(VpnProfile profile) {
    final host = profile.server?.trim() ?? '';
    final address = InternetAddress.tryParse(host);
    return {
      'protocol': ProtocolDisplayMapper.mapProfile(profile),
      'offlineMarked': isOfflineMarked(profile),
      'upstreamKind': host.isEmpty
          ? 'unavailable'
          : address == null
          ? 'domain'
          : address.type == InternetAddressType.IPv4
          ? 'ipv4'
          : 'ipv6',
      if (profile.kind == VpnProfileKind.hysteria2 ||
          profile.kind == VpnProfileKind.hysteria) ...{
        'bandwidthMode':
            _cap(profile, 'up_mbps') != null ||
                _cap(profile, 'down_mbps') != null
            ? 'configured'
            : 'auto',
        'uploadLimitMbps': ?_cap(profile, 'up_mbps'),
        'downloadLimitMbps': ?_cap(profile, 'down_mbps'),
      },
    };
  }

  static num? _cap(VpnProfile profile, String key) {
    final value = profile.outbound?[key];
    return value is num && value.isFinite && value > 0 && value <= 1000000
        ? value
        : null;
  }

  static String failure(Iterable<String?> messages) {
    final text = messages.whereType<String>().join('\n').toLowerCase();
    if (text.isEmpty) return 'none';
    for (final (category, pattern) in _failures) {
      if (RegExp(pattern, caseSensitive: false).hasMatch(text)) return category;
    }
    return 'unclassified';
  }

  static const _failures = <(String, String)>[
    (
      'tls_certificate',
      r'x509:|certificate.*(?:verify|invalid|expired|unknown)|сертификат.*(?:ошиб|провер|просроч|невер)',
    ),
    (
      'configuration',
      r'unknown field|unsupported runtime configuration|invalid.*(?:config|option)|failed to parse|decode.*(?:config|option)',
    ),
    (
      'dns_resolution',
      r'no such host|unknownhost|name resolution|lookup.*(?:timeout|timed out|failed)',
    ),
    (
      'permission',
      r'missing vpn permission|permission denied|vpn permission.*(?:missing|denied)',
    ),
    (
      'tls_handshake',
      r'tls.*(?:handshake|failed)|handshake.*(?:timeout|failed)',
    ),
    ('connection_refused', r'connection refused'),
    ('connection_reset', r'connection reset|broken pipe'),
    ('network_unreachable', r'network is unreachable|no route to host'),
    (
      'timeout',
      r'i/o timeout|context deadline|deadline exceeded|timeoutexception|timed out',
    ),
    ('unsupported', r'unsupported|не поддерживается'),
  ];
}
