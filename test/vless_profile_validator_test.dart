import 'package:aurum_vpn/src/models/vpn_profile.dart';
import 'package:aurum_vpn/src/services/vless_profile_validator.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the Reality validator does not apply to other profile kinds', () {
    for (final kind in [VpnProfileKind.hysteria2, VpnProfileKind.vlessXhttp]) {
      expect(VlessProfileValidator.validate(_profile(kind: kind)).ok, isTrue);
    }
  });

  test('requires outbound configuration for a Reality profile', () {
    final result = VlessProfileValidator.validate(_profile());
    expect(result.ok, isFalse);
    expect(result.message, contains('outbound'));
  });

  test('accepts a valid Reality TCP profile', () {
    expect(VlessProfileValidator.isSupportedRealityTcpOnly, isTrue);
    final result = VlessProfileValidator.validate(
      _profile(outbound: _outbound()),
    );
    expect(result.ok, isTrue);
    expect(result.message, isNull);
    expect(result.details, containsPair('transport', 'tcp'));
    expect(result.details, containsPair('flow', 'xtls-rprx-vision'));
  });

  test('import TLS detection recognizes only supported true forms', () {
    for (final enabled in [true, ' TRUE ', 'yes', '1', ' On ']) {
      expect(
        VlessProfileValidator.hasEnabledTls(
          _outbound(tls: {'enabled': enabled}),
        ),
        isTrue,
        reason: 'TLS enabled: $enabled',
      );
    }
    for (final enabled in [
      false,
      'FALSE',
      'off',
      '0',
      'unknown',
      '',
      null,
      1,
    ]) {
      expect(
        VlessProfileValidator.hasEnabledTls(
          _outbound(tls: {'enabled': enabled}),
        ),
        isFalse,
        reason: 'TLS enabled: $enabled',
      );
    }
    expect(VlessProfileValidator.hasEnabledTls(null), isFalse);
    expect(
      VlessProfileValidator.hasEnabledTls(
        _outbound(overrides: const {'tls': []}),
      ),
      isFalse,
    );
  });

  test('rejects a missing TLS block even with a valid server and UUID', () {
    final result = VlessProfileValidator.validateOutbound(
      _outbound(overrides: const {'tls': null}),
    );
    expect(result.ok, isFalse);
    for (final field in ['tls.enabled', 'reality.enabled', 'sni/server_name']) {
      expect(result.message, contains(field));
    }
  });

  for (final (label, config, error) in [
    ('blank host', _outbound(overrides: {'server': ' '}), 'host'),
    ('missing UUID', _outbound(overrides: {'uuid': null}), 'uuid'),
    ('TLS disabled', _outbound(tls: {'enabled': false}), 'tls.enabled'),
    ('non-boolean TLS', _outbound(tls: {'enabled': 'yes'}), 'tls.enabled'),
    ('insecure TLS', _outbound(tls: {'insecure': true}), 'tls.insecure'),
    (
      'Reality disabled',
      _outbound(reality: {'enabled': false}),
      'reality.enabled',
    ),
    ('blank SNI', _outbound(tls: {'server_name': '  '}), 'sni/server_name'),
    (
      'unsupported flow',
      _outbound(overrides: {'flow': 'fixture-flow'}),
      'flow=fixture-flow',
    ),
    (
      'unsupported packet encoding',
      _outbound(overrides: {'packet_encoding': 'fixture-encoding'}),
      'packet_encoding=fixture-encoding',
    ),
  ]) {
    test('Reality TCP rejects $label', () {
      final result = VlessProfileValidator.validateOutbound(config);
      expect(result.ok, isFalse);
      expect(result.message, contains(error));
    });
  }

  for (final (label, overrides, expected) in [
    (
      'explicit unsupported marker',
      <String, Object?>{
        'unsupported_transport': ' XhTtP ',
        'transport': {'type': 'tcp'},
        'network': 'tcp',
      },
      'xhttp',
    ),
    (
      'transport map',
      <String, Object?>{
        'transport': {'type': ' WS '},
        'network': 'tcp',
      },
      'ws',
    ),
    (
      'legacy network field',
      <String, Object?>{'unsupported_transport': ' ', 'network': ' GRPC '},
      'grpc',
    ),
  ]) {
    test('Reality TCP rejects a non-TCP transport from the $label', () {
      final outbound = _outbound(overrides: overrides);
      expect(VlessProfileValidator.transportLabel(outbound), expected);
      final result = VlessProfileValidator.validate(
        _profile(outbound: outbound),
      );
      expect(result.ok, isFalse);
      expect(result.message, contains('transport=$expected'));
      expect(result.details, containsPair('transport', expected));
    });
  }

  test('normalization does not coerce a WebSocket transport into TCP', () {
    final outbound = _outbound(
      overrides: const {
        'transport': {'type': 'ws'},
      },
    );
    expect(
      () => VlessProfileValidator.normalizeRealityTcpOutbound(outbound),
      throwsA(
        isA<StateError>().having(
          (error) => error.message.toString(),
          'message',
          contains('transport=ws'),
        ),
      ),
    );
  });
}

VpnProfile _profile({
  VpnProfileKind kind = VpnProfileKind.vlessReality,
  Map<String, dynamic>? outbound,
}) => VpnProfile(
  id: 'fixture',
  name: 'Fixture',
  kind: kind,
  originalInput: '',
  outbound: outbound,
);

Map<String, dynamic> _outbound({
  Map<String, Object?> overrides = const {},
  Map<String, Object?> tls = const {},
  Map<String, Object?> reality = const {},
}) => {
  'type': 'vless',
  'server': 'edge.example.invalid',
  'server_port': 443,
  'uuid': '11111111-1111-4111-8111-111111111111',
  'tls': {
    'enabled': true,
    'server_name': 'origin.example.invalid',
    'reality': {'enabled': true, 'public_key': 'fixture-key', ...reality},
    ...tls,
  },
  ...overrides,
};
