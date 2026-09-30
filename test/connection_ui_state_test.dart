import 'package:flutter_test/flutter_test.dart';
import 'package:aurum_vpn/src/models/connection_status.dart';
import 'package:aurum_vpn/src/models/connection_ui_state.dart';
import 'package:aurum_vpn/src/models/vpn_profile.dart';
import 'package:aurum_vpn/src/services/protocol_display_mapper.dart';
import 'package:aurum_vpn/src/utils/traffic_formatter.dart';

void main() {
  group('TrafficFormatter', () {
    test('formats speeds and bytes', () {
      expect(TrafficFormatter.formatSpeed(0), '0 B/s');
      expect(TrafficFormatter.formatSpeed(512), '512 B/s');
      expect(TrafficFormatter.formatSpeed(2048), '2 KB/s');
      expect(TrafficFormatter.formatSpeed(1048576), '1 MB/s');
      expect(TrafficFormatter.formatBytes(128 * 1024 * 1024), '128 MB');
    });

    test('formats duration as hh:mm:ss', () {
      expect(
        TrafficFormatter.formatDuration(const Duration(seconds: 12)),
        '00:00:12',
      );
      expect(
        TrafficFormatter.formatDuration(
          const Duration(minutes: 12, seconds: 35),
        ),
        '00:12:35',
      );
      expect(
        TrafficFormatter.formatDuration(
          const Duration(hours: 1, minutes: 5, seconds: 10),
        ),
        '01:05:10',
      );
    });
  });

  group('ProtocolDisplayMapper', () {
    test('distinguishes TLS and Reality XHTTP without changing profiles', () {
      for (final transport in ['xhttp', 'splithttp']) {
        expect(
          ProtocolDisplayMapper.mapProtocolToDisplayName(
            'vless',
            transport: transport,
            security: 'tls',
          ),
          'Xray TLS XHTTP / Современный',
        );
        expect(
          ProtocolDisplayMapper.mapProtocolToDisplayName(
            'vless',
            transport: transport,
          ),
          'Xray XHTTP / Современный',
        );
      }
      for (final reality in [false, true]) {
        final profile = VpnProfile(
          id: 'xhttp-display',
          name: 'XHTTP',
          kind: VpnProfileKind.vlessXhttp,
          originalInput: 'test-profile',
          outbound: {
            'type': 'vless',
            'transport': {'type': 'xhttp'},
            'tls': {
              'enabled': true,
              if (reality) 'reality': {'enabled': true},
            },
          },
        );
        final snapshot = profile.toJson();
        expect(
          ProtocolDisplayMapper.mapProfile(profile),
          'Xray ${reality ? 'REALITY' : 'TLS'} XHTTP / Современный',
        );
        expect(profile.toJson(), snapshot);
      }
    });

    test('maps public protocol names', () {
      expect(
        ProtocolDisplayMapper.mapProtocolToDisplayName(
          'vless',
          transport: 'tcp',
          security: 'reality',
        ),
        'Xray REALITY TCP / Стабильный',
      );
      expect(
        ProtocolDisplayMapper.mapProtocolToDisplayName(
          'vless',
          transport: 'xhttp',
          security: 'reality',
        ),
        'Xray REALITY XHTTP / Современный',
      );
      expect(
        ProtocolDisplayMapper.mapProtocolToDisplayName('naiveproxy'),
        'Веб',
      );
      expect(ProtocolDisplayMapper.mapProtocolToDisplayName('hy2'), 'ИИ');
      for (final protocol in ['hysteria', 'hysteria2', ' HY2 ']) {
        expect(ProtocolDisplayMapper.mapProtocolToDisplayName(protocol), 'ИИ');
      }
      expect(ProtocolDisplayMapper.mapProtocolToDisplayName('naive'), 'Веб');
    });
  });

  group('ConnectionUiState', () {
    test('preserves a protocol-specific latency label', () {
      final state = ConnectionUiState.connected(
        uploadSpeed: '0 B/s',
        downloadSpeed: '0 B/s',
        totalTraffic: '0 B',
        latencyLabel: 'DNS 24 ms',
      );

      expect(state.latencyLabel, 'DNS 24 ms');
      expect(state.toJson()['latencyLabel'], 'DNS 24 ms');
    });

    test('serializes idle, degraded, network changing and failed states', () {
      expect(
        ConnectionUiState.idle(
          uploadSpeed: '0 B/s',
          downloadSpeed: '0 B/s',
          totalTraffic: '1 MB',
          profileName: 'idle-profile',
        ).toJson()['status'],
        ConnectionStatus.idle.name,
      );
      expect(
        ConnectionUiState.degraded(
          uploadSpeed: '0 B/s',
          downloadSpeed: '0 B/s',
          totalTraffic: '1 MB',
        ).toJson()['status'],
        ConnectionStatus.degraded.name,
      );
      expect(
        ConnectionUiState.networkChanging(
          uploadSpeed: '0 B/s',
          downloadSpeed: '0 B/s',
          totalTraffic: '1 MB',
        ).toJson()['status'],
        ConnectionStatus.networkChanging.name,
      );
      expect(
        ConnectionUiState.reconnecting().toJson()['status'],
        ConnectionStatus.reconnecting.name,
      );
      expect(
        ConnectionUiState.failed().toJson()['status'],
        ConnectionStatus.failed.name,
      );
    });
  });
}
