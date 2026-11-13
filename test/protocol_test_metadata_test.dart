import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:aurum_vpn/src/models/vpn_profile.dart';
import 'package:aurum_vpn/src/services/protocol_test_metadata.dart';

void main() {
  VpnProfile profile(String server, {String name = 'private-name'}) =>
      VpnProfile(
        id: 'private-id',
        name: name,
        kind: VpnProfileKind.vlessReality,
        originalInput: 'private-credential',
        server: server,
        port: 443,
      );

  test('metadata contains only protocol, offline flag and address family', () {
    final value = ProtocolTestMetadata.profile(profile('private.example'));
    expect(value, {
      'protocol': 'Reality',
      'offlineMarked': false,
      'upstreamKind': 'domain',
    });
    final text = jsonEncode(value);
    for (final secret in [
      'private-name',
      'private-id',
      'private-credential',
      'private.example',
      '443',
    ]) {
      expect(text.contains(secret), isFalse);
    }
  });

  test(
    'hostname classification performs no lookup and distinguishes both IP families',
    () {
      expect(
        ProtocolTestMetadata.profile(profile('192.0.2.1'))['upstreamKind'],
        'ipv4',
      );
      expect(
        ProtocolTestMetadata.profile(profile('2001:db8::1'))['upstreamKind'],
        'ipv6',
      );
      expect(
        ProtocolTestMetadata.profile(profile(''))['upstreamKind'],
        'unavailable',
      );
    },
  );

  test(
    'explicit offline names are skipped including underscore separators',
    () {
      for (final name in [
        'country_offline',
        'ОФЛАЙН',
        'оффлайн',
        'не работает',
        'expired',
      ]) {
        expect(
          ProtocolTestMetadata.profile(
            profile('private.example', name: name),
          )['offlineMarked'],
          isTrue,
        );
      }
    },
  );

  test('TLS validation failures are not reduced to generic timeout', () {
    expect(
      ProtocolTestMetadata.failure([
        'timeout',
        'x509: certificate expired at private.example',
      ]),
      'tls_certificate',
    );
    expect(
      ProtocolTestMetadata.failure(['lookup private.example: no such host']),
      'dns_resolution',
    );
    expect(
      ProtocolTestMetadata.failure(['unknown field private-field']),
      'configuration',
    );
  });

  test('failure summary never returns user error text or credentials', () {
    expect(
      ProtocolTestMetadata.failure(['private-credential private.example']),
      'unclassified',
    );
    expect(ProtocolTestMetadata.failure([]), 'none');
  });

  test(
    'Hysteria reports numeric caps only and never includes other outbound fields',
    () {
      final value = ProtocolTestMetadata.profile(
        profile('private.example').copyWith(
          kind: VpnProfileKind.hysteria2,
          outbound: {
            'up_mbps': 30,
            'down_mbps': 50,
            'password': 'private-password',
          },
        ),
      );
      expect(value['bandwidthMode'], 'configured');
      expect(value['uploadLimitMbps'], 30);
      expect(value['downloadLimitMbps'], 50);
      expect(jsonEncode(value).contains('private'), isFalse);
    },
  );

  test('automatic congestion mode does not invent a bandwidth value', () {
    final value = ProtocolTestMetadata.profile(
      profile('private.example').copyWith(
        kind: VpnProfileKind.hysteria2,
        outbound: {'up_mbps': double.infinity, 'down_mbps': -1},
      ),
    );
    expect(value['bandwidthMode'], 'auto');
    expect(value.containsKey('downloadLimitMbps'), isFalse);
    expect(value.containsKey('uploadLimitMbps'), isFalse);
  });
}
