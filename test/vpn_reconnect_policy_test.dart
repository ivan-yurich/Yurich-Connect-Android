import 'package:aurum_vpn/src/models/vpn_profile.dart';
import 'package:aurum_vpn/src/services/profile_engine_selector.dart';
import 'package:aurum_vpn/src/services/vpn_reconnect_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('cold start keeps tolerant retries and readiness timeouts', () {
    final policy = VpnReconnectPolicy.resolve(
      kind: VpnProfileKind.naive,
      engine: VpnCoreEngine.singBox,
      rapidRestart: false,
      crossEngineRestart: false,
    );

    expect(policy.mode, VpnReconnectMode.initial);
    expect(policy.maxPlans, 2);
    expect(policy.maxAttemptsPerPlan, 2);
    expect(policy.configTimeout, const Duration(seconds: 10));
    expect(policy.startCallTimeout, const Duration(seconds: 8));
    expect(policy.statusTimeout, const Duration(seconds: 40));
    expect(policy.startupProbeTimeout, const Duration(seconds: 12));
    expect(policy.stopStatusTimeout, const Duration(seconds: 20));
    expect(policy.attemptBudget, isNull);
  });

  test('rapid sing-box switch has one bounded attempt', () {
    final policy = VpnReconnectPolicy.resolve(
      kind: VpnProfileKind.vlessTls,
      engine: VpnCoreEngine.singBox,
      rapidRestart: true,
      crossEngineRestart: false,
    );

    expect(policy.mode, VpnReconnectMode.rapidSameEngine);
    expect(policy.maxPlans, 1);
    expect(policy.maxAttemptsPerPlan, 1);
    expect(policy.configTimeout, const Duration(seconds: 4));
    expect(policy.startCallTimeout, const Duration(seconds: 5));
    expect(policy.statusTimeout, const Duration(seconds: 16));
    expect(policy.attemptBudget, const Duration(seconds: 25));
    expect(policy.stopStatusTimeout, const Duration(seconds: 20));
  });

  test('rapid QUIC and Xray switches get protocol-specific windows', () {
    final quic = VpnReconnectPolicy.resolve(
      kind: VpnProfileKind.hysteria2,
      engine: VpnCoreEngine.singBox,
      rapidRestart: true,
      crossEngineRestart: false,
    );
    final xray = VpnReconnectPolicy.resolve(
      kind: VpnProfileKind.vlessXhttp,
      engine: VpnCoreEngine.xray,
      rapidRestart: true,
      crossEngineRestart: false,
    );

    expect(quic.statusTimeout, const Duration(seconds: 16));
    expect(xray.statusTimeout, const Duration(seconds: 16));
    expect(xray.startCallTimeout, const Duration(seconds: 7));
    expect(xray.startupProbeTimeout, const Duration(seconds: 16));
    expect(xray.attemptBudget, const Duration(seconds: 32));
  });

  test('rapid Naive keeps fallback but never retries either plan', () {
    final policy = VpnReconnectPolicy.resolve(
      kind: VpnProfileKind.naive,
      engine: VpnCoreEngine.singBox,
      rapidRestart: true,
      crossEngineRestart: false,
    );

    expect(policy.maxPlans, 2);
    expect(policy.maxAttemptsPerPlan, 1);
    expect(policy.fallbackDelay, const Duration(milliseconds: 300));
  });

  test('cross-engine switch keeps stop confirmation and bounded attempt', () {
    final policy = VpnReconnectPolicy.resolve(
      kind: VpnProfileKind.vlessXhttp,
      engine: VpnCoreEngine.xray,
      rapidRestart: true,
      crossEngineRestart: true,
    );

    expect(policy.mode, VpnReconnectMode.rapidCrossEngine);
    expect(policy.startSettleDelay, const Duration(milliseconds: 650));
    expect(policy.stopStatusTimeout, const Duration(seconds: 20));
    expect(policy.attemptBudget, const Duration(seconds: 32));
  });

  test('attempt timeout is clamped to the remaining budget', () {
    final policy = VpnReconnectPolicy.resolve(
      kind: VpnProfileKind.vlessTls,
      engine: VpnCoreEngine.singBox,
      rapidRestart: true,
      crossEngineRestart: false,
    );

    expect(
      policy.timeoutWithinAttemptBudget(
        const Duration(seconds: 8),
        elapsed: const Duration(seconds: 21),
      ),
      const Duration(seconds: 4),
    );
    expect(
      policy.timeoutWithinAttemptBudget(
        const Duration(seconds: 8),
        elapsed: const Duration(seconds: 25),
      ),
      Duration.zero,
    );
  });
}
