import '../models/vpn_profile.dart';
import 'profile_engine_selector.dart';

enum VpnReconnectMode {
  initial,
  rapidSameEngine,
  rapidCrossEngine,
  autoCandidate,
}

/// Bounds connection work while keeping protocol-specific readiness windows.
///
/// Rapid switches use bounded attempts and a protocol-aware readiness
/// budget so a bad profile cannot occupy the command queue for several
/// minutes. Cold starts keep retries where the native runtime needs them.
final class VpnReconnectPolicy {
  // Android may need 25 s graceful stop, 4 s forced stop and 2 s to confirm
  // process exit. This is a ceiling, not a delay on a successful stop.
  static const nativeStopStatusTimeout = Duration(seconds: 35);
  const VpnReconnectPolicy({
    required this.mode,
    required this.maxPlans,
    required this.maxAttemptsPerPlan,
    required this.configTimeout,
    required this.startCallTimeout,
    required this.statusTimeout,
    required this.startupProbeTimeout,
    required this.stopCallTimeout,
    required this.stopStatusTimeout,
    required this.startSettleDelay,
    required this.retryDelay,
    required this.fallbackDelay,
    required this.attemptBudget,
  });

  final VpnReconnectMode mode;
  final int maxPlans;
  final int maxAttemptsPerPlan;
  final Duration configTimeout;
  final Duration startCallTimeout;
  final Duration statusTimeout;
  final Duration startupProbeTimeout;
  final Duration stopCallTimeout;
  final Duration stopStatusTimeout;
  final Duration startSettleDelay;
  final Duration retryDelay;
  final Duration fallbackDelay;

  /// Budget for start/readiness attempts. Cleanup is deliberately allowed to
  /// finish after this deadline so the next profile never starts over a native
  /// service that is still stopping.
  final Duration? attemptBudget;

  bool get isRapid => mode != VpnReconnectMode.initial;

  static VpnReconnectPolicy resolve({
    required VpnProfileKind kind,
    required VpnCoreEngine engine,
    required bool rapidRestart,
    required bool crossEngineRestart,
    bool automaticFailover = false,
  }) {
    if (automaticFailover) {
      final slowReadiness =
          engine == VpnCoreEngine.xray ||
          kind == VpnProfileKind.hysteria2 ||
          kind == VpnProfileKind.hysteria;
      return VpnReconnectPolicy(
        mode: VpnReconnectMode.autoCandidate,
        maxPlans: 1,
        maxAttemptsPerPlan: 1,
        configTimeout: const Duration(seconds: 4),
        startCallTimeout: const Duration(seconds: 7),
        statusTimeout: Duration(seconds: slowReadiness ? 40 : 24),
        startupProbeTimeout: const Duration(seconds: 6),
        stopCallTimeout: const Duration(seconds: 5),
        stopStatusTimeout: nativeStopStatusTimeout,
        startSettleDelay: Duration.zero,
        retryDelay: Duration.zero,
        fallbackDelay: Duration.zero,
        attemptBudget: Duration(seconds: slowReadiness ? 51 : 35),
      );
    }
    if (!rapidRestart) {
      final isXray = engine == VpnCoreEngine.xray;
      return VpnReconnectPolicy(
        mode: VpnReconnectMode.initial,
        maxPlans: kind == VpnProfileKind.naive ? 2 : 1,
        // Xray already probes and recovers within the native startup window.
        // Restarting the same config from Flutter adds another full 40 s wait.
        maxAttemptsPerPlan: isXray ? 1 : 2,
        configTimeout: const Duration(seconds: 10),
        startCallTimeout: const Duration(seconds: 8),
        statusTimeout: const Duration(seconds: 40),
        startupProbeTimeout: const Duration(seconds: 12),
        stopCallTimeout: const Duration(seconds: 5),
        stopStatusTimeout: nativeStopStatusTimeout,
        startSettleDelay: const Duration(seconds: 1),
        retryDelay: isXray ? Duration.zero : const Duration(milliseconds: 1200),
        fallbackDelay: const Duration(milliseconds: 800),
        attemptBudget: null,
      );
    }

    final mode = crossEngineRestart
        ? VpnReconnectMode.rapidCrossEngine
        : VpnReconnectMode.rapidSameEngine;
    final isXray = engine == VpnCoreEngine.xray;
    final isNaive = kind == VpnProfileKind.naive;
    final isHysteria2 = kind == VpnProfileKind.hysteria2;

    // Both QUIC and Xray readiness can outlive a 16-second UI deadline while
    // native startup still has its legitimate 30-second grace. Match cold-start
    // readiness; a successful status completes immediately, without a fixed wait.
    final statusTimeout = Duration(seconds: isHysteria2 || isXray ? 40 : 16);
    final extendedStart = crossEngineRestart || isXray;
    // Cleanup between attempts consumes this budget. Final cleanup may exceed
    // it so the next profile cannot overlap a stopping service.
    final attemptBudget = isHysteria2 || isXray
        ? const Duration(seconds: 65)
        : extendedStart
        ? const Duration(seconds: 32)
        : const Duration(seconds: 25);

    return VpnReconnectPolicy(
      mode: mode,
      maxPlans: isNaive ? 2 : 1,
      maxAttemptsPerPlan: isHysteria2 ? 2 : 1,
      configTimeout: const Duration(seconds: 4),
      startCallTimeout: Duration(seconds: extendedStart ? 7 : 5),
      statusTimeout: statusTimeout,
      startupProbeTimeout: Duration(seconds: isXray ? 16 : 4),
      stopCallTimeout: const Duration(seconds: 3),
      // Never start the next runtime while the previous one is still Stopping.
      stopStatusTimeout: nativeStopStatusTimeout,
      // A restart already awaits native stop/cleanup; reload has its own
      // native readiness gate. Do not add a second, fixed settle delay.
      startSettleDelay: Duration.zero,
      retryDelay: isHysteria2
          ? const Duration(milliseconds: 500)
          : Duration.zero,
      fallbackDelay: const Duration(milliseconds: 300),
      attemptBudget: attemptBudget,
    );
  }

  bool isAttemptBudgetExpired(Duration elapsed) {
    final budget = attemptBudget;
    return budget != null && elapsed >= budget;
  }

  Duration timeoutWithinAttemptBudget(
    Duration preferred, {
    required Duration elapsed,
  }) {
    final budget = attemptBudget;
    if (budget == null) {
      return preferred;
    }
    final remaining = budget - elapsed;
    if (remaining <= Duration.zero) {
      return Duration.zero;
    }
    return preferred <= remaining ? preferred : remaining;
  }
}
