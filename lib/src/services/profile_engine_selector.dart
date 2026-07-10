import '../models/vpn_profile.dart';
import 'vless_profile_validator.dart';

enum VpnCoreEngine { singBox, xray }

class ProfileEngineSelection {
  const ProfileEngineSelection({
    required this.engine,
    required this.available,
    required this.reason,
  });

  final VpnCoreEngine engine;
  final bool available;
  final String reason;

  bool get canRunInCurrentBuild => available;
}

class ProfileEngineSelector {
  const ProfileEngineSelector._();

  static const bool xrayEnabled = true;

  static ProfileEngineSelection select(VpnProfile profile) {
    return switch (profile.kind) {
      VpnProfileKind.vlessReality => _selectReality(profile),
      VpnProfileKind.vlessXhttp => const ProfileEngineSelection(
        engine: VpnCoreEngine.xray,
        available: xrayEnabled,
        reason: 'Поддерживается Xray/libXray runtime.',
      ),
      VpnProfileKind.vlessMkcp => _xrayOnly(
        'VLESS mKCP требует Xray/libXray. В sing-box Android-сборке этот transport не запускается.',
      ),
      VpnProfileKind.vlessTls => const ProfileEngineSelection(
        engine: VpnCoreEngine.singBox,
        available: true,
        reason:
            'Поддерживается sing-box runtime: VLESS TLS и стандартные transport для данного билда.',
      ),
      VpnProfileKind.pingTunnelExperimental => _xrayOnly(
        'PingTunnel сейчас помечен как экспериментальный и требует отдельного движка, не включённого в текущую сборку.',
      ),
      VpnProfileKind.naive ||
      VpnProfileKind.hysteria2 ||
      VpnProfileKind.hysteria ||
      VpnProfileKind.singBoxConfig => const ProfileEngineSelection(
        engine: VpnCoreEngine.singBox,
        available: true,
        reason: 'Поддерживается текущим sing-box движком.',
      ),
    };
  }

  static bool requiresSuccessfulStartupProbe(VpnProfile profile) {
    if (profile.kind == VpnProfileKind.naive ||
        profile.kind == VpnProfileKind.singBoxConfig) {
      return false;
    }

    final selection = select(profile);
    return selection.canRunInCurrentBuild &&
        selection.engine == VpnCoreEngine.singBox;
  }

  static ProfileEngineSelection _selectReality(VpnProfile profile) {
    final transport = VlessProfileValidator.transportLabel(profile.outbound);
    if (transport == 'tcp') {
      return const ProfileEngineSelection(
        engine: VpnCoreEngine.singBox,
        available: true,
        reason:
            'VLESS Reality TCP теперь запускается через sing-box для стабильной работы на Android.',
      );
    }
    return _xrayOnly(
      'VLESS Reality transport=$transport требует Xray/libXray. Текущая сборка поддерживает Reality только через TCP.',
    );
  }

  static ProfileEngineSelection _xrayOnly(String reason) {
    return ProfileEngineSelection(
      engine: VpnCoreEngine.xray,
      available: false,
      reason: reason,
    );
  }
}
