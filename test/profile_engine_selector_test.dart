import 'package:aurum_vpn/src/models/vpn_profile.dart';
import 'package:aurum_vpn/src/services/profile_engine_selector.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('runs VLESS Reality TCP on sing-box', () {
    final profile = _profile(
      VpnProfileKind.vlessReality,
      outbound: {
        'type': 'vless',
        'server': 'example.com',
        'transport': {'type': 'tcp'},
      },
    );

    final selection = ProfileEngineSelector.select(profile);

    expect(selection.engine, VpnCoreEngine.singBox);
    expect(selection.canRunInCurrentBuild, true);
    expect(selection.reason, contains('sing-box'));
  });

  test('runs VLESS XHTTP on Xray engine', () {
    final profile = _profile(
      VpnProfileKind.vlessXhttp,
      outbound: {
        'type': 'vless',
        'server': 'example.com',
        'transport': {'type': 'xhttp', 'path': '/xhttp'},
      },
    );

    final selection = ProfileEngineSelector.select(profile);

    expect(selection.engine, VpnCoreEngine.xray);
    expect(selection.canRunInCurrentBuild, true);
    expect(selection.reason, contains('Xray/libXray'));
  });

  test('runs VLESS TLS on sing-box engine', () {
    final profile = _profile(
      VpnProfileKind.vlessTls,
      outbound: {
        'type': 'vless',
        'server': 'example.com',
        'transport': {'type': 'tcp'},
      },
    );

    final selection = ProfileEngineSelector.select(profile);

    expect(selection.engine, VpnCoreEngine.singBox);
    expect(selection.canRunInCurrentBuild, true);
    expect(selection.reason, contains('sing-box'));
  });

  test('keeps Naive and Hysteria on sing-box', () {
    for (final kind in [
      VpnProfileKind.naive,
      VpnProfileKind.hysteria2,
      VpnProfileKind.hysteria,
    ]) {
      final selection = ProfileEngineSelector.select(_profile(kind));

      expect(selection.engine, VpnCoreEngine.singBox);
      expect(selection.canRunInCurrentBuild, true);
    }
  });

  test(
    'requires a successful startup probe for managed VLESS and Hysteria',
    () {
      for (final kind in [
        VpnProfileKind.vlessReality,
        VpnProfileKind.vlessTls,
        VpnProfileKind.hysteria2,
        VpnProfileKind.hysteria,
      ]) {
        expect(
          ProfileEngineSelector.requiresSuccessfulStartupProbe(_profile(kind)),
          isTrue,
          reason: kind.name,
        );
      }
    },
  );

  test('does not enforce mixed-proxy startup probe for unmanaged configs', () {
    for (final kind in [
      VpnProfileKind.naive,
      VpnProfileKind.vlessXhttp,
      VpnProfileKind.singBoxConfig,
      VpnProfileKind.pingTunnelExperimental,
    ]) {
      expect(
        ProfileEngineSelector.requiresSuccessfulStartupProbe(_profile(kind)),
        isFalse,
        reason: kind.name,
      );
    }
  });

  test('treats VLESS TLS as supported by the client', () {
    expect(VpnProfileKind.vlessTls.isClientSupported, isTrue);
  });

  test('routes experimental PingTunnel to Xray-required engine', () {
    final selection = ProfileEngineSelector.select(
      _profile(VpnProfileKind.pingTunnelExperimental),
    );

    expect(selection.engine, VpnCoreEngine.xray);
    expect(selection.canRunInCurrentBuild, false);
    expect(selection.reason, contains('отдельного движка'));
  });
}

VpnProfile _profile(VpnProfileKind kind, {Map<String, dynamic>? outbound}) {
  return VpnProfile(
    id: kind.name,
    name: kind.label,
    kind: kind,
    originalInput: kind.name,
    server: 'example.com',
    port: 443,
    outbound:
        outbound ?? {'type': kind == VpnProfileKind.naive ? 'naive' : 'vless'},
  );
}
