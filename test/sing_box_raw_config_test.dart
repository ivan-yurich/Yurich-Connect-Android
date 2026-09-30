import 'dart:convert';

import 'package:aurum_vpn/src/models/vpn_profile.dart';
import 'package:aurum_vpn/src/services/sing_box_config_builder.dart';
import 'package:flutter_test/flutter_test.dart';

String buildRaw(Map<String, dynamic> config) => SingBoxConfigBuilder().build(
  VpnProfile(
    id: 'raw',
    name: 'Raw config',
    kind: VpnProfileKind.singBoxConfig,
    originalInput: '',
    rawConfig: jsonEncode(config),
  ),
);

void main() {
  test('adds loopback readiness inbound without changing user routes', () {
    final original = {
      'inbounds': [
        {'type': 'tun', 'tag': 'yurich-health-in'},
      ],
      'outbounds': [
        {'type': 'direct', 'tag': 'custom-direct'},
      ],
      'route': {
        'rules': [
          {
            'domain_suffix': ['example.com'],
            'outbound': 'custom-direct',
          },
        ],
        'final': 'custom-direct',
      },
    };
    final config = jsonDecode(buildRaw(original)) as Map<String, dynamic>;
    expect(config['route'], original['route']);
    expect(config['outbounds'], original['outbounds']);
    expect((config['inbounds'] as List).last, {
      'type': 'mixed',
      'tag': 'yurich-health-in-1',
      'listen': '127.0.0.1',
      'listen_port': SingBoxConfigBuilder.localMixedProxyPort,
    });
    expect(original['inbounds'], hasLength(1));
  });

  test('reuses an existing local unauthenticated readiness proxy', () {
    final config = {
      'inbounds': [
        {
          'type': 'mixed',
          'listen': '127.0.0.1',
          'listen_port': SingBoxConfigBuilder.localMixedProxyPort,
        },
      ],
    };
    expect(buildRaw(config), jsonEncode(config));
  });

  test(
    'rejects port conflicts instead of reporting a probe as unavailable',
    () {
      for (final inbound in [
        {'type': 'socks', 'listen': '127.0.0.1'},
        {'type': 'mixed', 'listen': '192.168.1.2'},
        {
          'type': 'mixed',
          'listen': '127.0.0.1',
          'users': [
            {'username': 'user', 'password': 'pass'},
          ],
        },
      ]) {
        expect(
          () => buildRaw({
            'inbounds': [
              {
                ...inbound,
                'listen_port': SingBoxConfigBuilder.localMixedProxyPort,
              },
            ],
          }),
          throwsStateError,
        );
      }
    },
  );
}
