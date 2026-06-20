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
  });

  test('routes VLESS XHTTP to future Xray engine', () {
    final profile = _profile(
      VpnProfileKind.vlessXhttp,
      outbound: {
        'type': 'vless',
        'server': 'example.com',
        'unsupported_transport': 'xhttp',
      },
    );

    final selection = ProfileEngineSelector.select(profile);

    expect(selection.engine, VpnCoreEngine.xray);
    expect(selection.canRunInCurrentBuild, false);
    expect(selection.reason, contains('Xray/libXray'));
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
