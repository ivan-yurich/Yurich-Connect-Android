import '../models/vpn_profile.dart';
import 'profile_engine_selector.dart';

enum VpnReconnectMode { initial, rapidSameEngine, rapidCrossEngine }

/// Bounds reconnect work without changing the more tolerant cold-start path.
///
/// Rapid switches use one attempt per plan and a protocol-aware readiness
/// budget so a bad profile cannot occupy the command queue for several
/// minutes. The cold-start path keeps its tolerant retries.
final class VpnReconnectPolicy {
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
  }) {
    if (!rapidRestart) {
      return VpnReconnectPolicy(
        mode: VpnReconnectMode.initial,
        maxPlans: kind == VpnProfileKind.naive ? 2 : 1,
        maxAttemptsPerPlan: 2,
        configTimeout: const Duration(seconds: 10),
        startCallTimeout: const Duration(seconds: 8),
        statusTimeout: const Duration(seconds: 40),
        startupProbeTimeout: const Duration(seconds: 12),
        stopCallTimeout: const Duration(seconds: 5),
        stopStatusTimeout: const Duration(seconds: 20),
        startSettleDelay: const Duration(seconds: 1),
        retryDelay: const Duration(milliseconds: 1200),
        fallbackDelay: const Duration(milliseconds: 800),
        attemptBudget: null,
      );
    }

    final mode = crossEngineRestart
        ? VpnReconnectMode.rapidCrossEngine
        : VpnReconnectMode.rapidSameEngine;
    final isXray = engine == VpnCoreEngine.xray;
    final isNaive = kind == VpnProfileKind.naive;

    // Android native startup may need about 14 seconds before Started becomes
    // observable on LTE. Keep the readiness window independent from config
    // persistence and the asynchronous start command.
    const statusTimeout = Duration(seconds: 16);
    final extendedStart = crossEngineRestart || isXray;
    final attemptBudget = extendedStart
        ? const Duration(seconds: 32)
        : const Duration(seconds: 25);

    return VpnReconnectPolicy(
      mode: mode,
      maxPlans: isNaive ? 2 : 1,
      maxAttemptsPerPlan: 1,
      configTimeout: const Duration(seconds: 4),
      startCallTimeout: Duration(seconds: extendedStart ? 7 : 5),
      statusTimeout: statusTimeout,
      startupProbeTimeout: Duration(seconds: isXray ? 16 : 4),
      stopCallTimeout: const Duration(seconds: 3),
      // Native service cleanup can legitimately take about 17.5 seconds.
      // Never start the next runtime while the previous one is still Stopping.
      stopStatusTimeout: const Duration(seconds: 20),
      startSettleDelay: Duration(milliseconds: crossEngineRestart ? 650 : 120),
      retryDelay: Duration.zero,
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
