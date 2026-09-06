import '../models/vpn_profile.dart';
import 'vless_profile_validator.dart';

enum VpnCoreEngine { singBox, xray }

enum VpnProtocolSupportLevel { stable, experimental, unavailable }

class ProfileEngineSelection {
  const ProfileEngineSelection({
    required this.engine,
    required this.available,
    required this.reason,
    required this.supportLevel,
    required this.coreVersion,
  });

  final VpnCoreEngine engine;
  final bool available;
  final String reason;
  final VpnProtocolSupportLevel supportLevel;
  final String coreVersion;

  bool get canRunInCurrentBuild => available;
}

class ProfileEngineSelector {
  const ProfileEngineSelector._();

  static const bool xrayEnabled = true;
  static const singBoxCoreVersion = '1.13.11';
  static const xrayCoreVersion = '26.6.27';

  static ProfileEngineSelection select(VpnProfile profile) {
    return switch (profile.kind) {
      VpnProfileKind.vlessReality => _selectReality(profile),
      VpnProfileKind.vlessXhttp => const ProfileEngineSelection(
        engine: VpnCoreEngine.xray,
        available: xrayEnabled,
        reason: 'Экспериментальная поддержка Xray/libXray $xrayCoreVersion.',
        supportLevel: VpnProtocolSupportLevel.experimental,
        coreVersion: xrayCoreVersion,
      ),
      VpnProfileKind.vlessMkcp => _xrayOnly(
        'VLESS mKCP требует Xray/libXray. В sing-box Android-сборке этот transport не запускается.',
      ),
      VpnProfileKind.vlessTls => const ProfileEngineSelection(
        engine: VpnCoreEngine.singBox,
        available: true,
        reason:
            'Поддерживается sing-box runtime: VLESS TLS и стандартные transport для данного билда.',
        supportLevel: VpnProtocolSupportLevel.stable,
        coreVersion: singBoxCoreVersion,
      ),
      VpnProfileKind.naive ||
      VpnProfileKind.hysteria2 ||
      VpnProfileKind.hysteria ||
      VpnProfileKind.singBoxConfig => const ProfileEngineSelection(
        engine: VpnCoreEngine.singBox,
        available: true,
        reason: 'Поддерживается текущим sing-box движком.',
        supportLevel: VpnProtocolSupportLevel.stable,
        coreVersion: singBoxCoreVersion,
      ),
    };
  }

  static bool requiresSuccessfulStartupProbe(VpnProfile profile) {
    final selection = select(profile);
    return selection.canRunInCurrentBuild &&
        selection.engine == VpnCoreEngine.xray;
  }

  static bool supportsLocalProxyProbe(VpnProfile profile) =>
      requiresSuccessfulStartupProbe(profile);

  static ProfileEngineSelection _selectReality(VpnProfile profile) {
    final transport = VlessProfileValidator.transportLabel(profile.outbound);
    if (transport == 'tcp') {
      return const ProfileEngineSelection(
        engine: VpnCoreEngine.singBox,
        available: true,
        reason:
            'VLESS Reality TCP теперь запускается через sing-box для стабильной работы на Android.',
        supportLevel: VpnProtocolSupportLevel.stable,
        coreVersion: singBoxCoreVersion,
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
      supportLevel: VpnProtocolSupportLevel.unavailable,
      coreVersion: xrayCoreVersion,
    );
  }
}
