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

  bool get canRunInCurrentBuild => available && engine == VpnCoreEngine.singBox;
}

class ProfileEngineSelector {
  const ProfileEngineSelector._();

  static const bool xrayEnabled = false;

  static ProfileEngineSelection select(VpnProfile profile) {
    return switch (profile.kind) {
      VpnProfileKind.vlessReality => _selectReality(profile),
      VpnProfileKind.vlessXhttp => _xrayOnly(
        'VLESS XHTTP требует Xray/libXray. Текущая Android-сборка запускает VPN через sing-box.',
      ),
      VpnProfileKind.vlessMkcp => _xrayOnly(
        'VLESS mKCP требует Xray/libXray. В sing-box Android-сборке этот transport не запускается.',
      ),
      VpnProfileKind.vlessTls => _xrayOnly(
        'VLESS TLS без Reality отключён в этой сборке: используем Reality как основной безопасный VLESS-профиль.',
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

  static ProfileEngineSelection _selectReality(VpnProfile profile) {
    final transport = VlessProfileValidator.transportLabel(profile.outbound);
    if (transport == 'tcp') {
      return const ProfileEngineSelection(
        engine: VpnCoreEngine.singBox,
        available: true,
        reason: 'VLESS Reality TCP поддерживается текущим sing-box движком.',
      );
    }
    return _xrayOnly(
      'VLESS Reality transport=$transport требует Xray/libXray. Текущая сборка поддерживает Reality только через TCP.',
    );
  }

  static ProfileEngineSelection _xrayOnly(String reason) {
    return ProfileEngineSelection(
      engine: VpnCoreEngine.xray,
      available: xrayEnabled,
      reason: xrayEnabled ? 'Поддерживается Xray/libXray.' : reason,
    );
  }
}
