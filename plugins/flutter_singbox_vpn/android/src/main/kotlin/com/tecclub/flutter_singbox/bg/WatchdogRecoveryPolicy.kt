package com.tecclub.flutter_singbox.bg

internal data class WatchdogRecoveryState(
    val lastRestartAtMs: Long = 0L,
    val attempts: Int = 0,
    val healthySinceMs: Long = 0L,
    val lastHealthyAtMs: Long = 0L,
)

internal object WatchdogRecoveryPolicy {
    const val BASE_COOLDOWN_MS = 90_000L
    const val MAX_COOLDOWN_MS = 15 * 60_000L
    const val HEALTHY_RESET_MS = 10 * 60_000L
    const val MAX_HEALTHY_GAP_MS = 3 * 60_000L
    const val NETWORK_RECOVERY_MIN_MS = 15_000L
    const val HYSTERIA2_CELLULAR_CONFIRMATION_CYCLES = 2
    private val ACTIVE_REPROBE_DELAYS_MS = longArrayOf(12_000L, 20_000L, 30_000L, 60_000L)
    private val IDLE_REPROBE_DELAYS_MS = longArrayOf(30_000L, 60_000L, 90_000L)

    fun cooldownMs(attempts: Int): Long =
        (BASE_COOLDOWN_MS * (1L shl (attempts.coerceIn(1, 5) - 1)))
            .coerceAtMost(MAX_COOLDOWN_MS)

    fun canRestart(state: WatchdogRecoveryState, nowMs: Long, networkRecovery: Boolean): Boolean {
        if (nowMs < 0L) return false
        val cooldown = if (networkRecovery) NETWORK_RECOVERY_MIN_MS else cooldownMs(state.attempts)
        return TunnelReadinessPolicy.canRestart(nowMs, state.lastRestartAtMs, cooldown)
    }

    fun restarted(state: WatchdogRecoveryState, nowMs: Long): WatchdogRecoveryState =
        WatchdogRecoveryState(nowMs, (state.attempts.coerceIn(0, 5) + 1).coerceAtMost(5))

    fun observed(state: WatchdogRecoveryState, nowMs: Long, healthy: Boolean): WatchdogRecoveryState {
        if (!healthy) return state.copy(healthySinceMs = 0L, lastHealthyAtMs = 0L)
        if (state.attempts == 0) return state
        if (state.healthySinceMs == 0L || nowMs < state.lastHealthyAtMs ||
            nowMs - state.lastHealthyAtMs > MAX_HEALTHY_GAP_MS) {
            return state.copy(healthySinceMs = nowMs, lastHealthyAtMs = nowMs)
        }
        return if (nowMs - state.healthySinceMs >= HEALTHY_RESET_MS) {
            WatchdogRecoveryState(lastRestartAtMs = state.lastRestartAtMs)
        } else state.copy(lastHealthyAtMs = nowMs)
    }

    fun readinessRetryDelayMs(failedCycles: Int, idle: Boolean): Long {
        val delays = if (idle) IDLE_REPROBE_DELAYS_MS else ACTIVE_REPROBE_DELAYS_MS
        val index = if (failedCycles <= 1) 0 else (failedCycles - 1).coerceAtMost(delays.lastIndex)
        return delays[index]
    }

    fun requiresExtendedReadinessConfirmation(
        usesHysteria2: Boolean,
        cellular: Boolean,
    ): Boolean = usesHysteria2 && cellular

    fun canAttemptReadinessRestart(
        failedCycles: Int,
        usesHysteria2: Boolean,
        cellular: Boolean,
    ): Boolean {
        if (failedCycles <= 0) return false
        val requiredCycles = if (requiresExtendedReadinessConfirmation(usesHysteria2, cellular)) {
            HYSTERIA2_CELLULAR_CONFIRMATION_CYCLES
        } else {
            1
        }
        return failedCycles >= requiredCycles
    }

    fun shouldAttemptHysteria2CellularSoftReset(
        failedCycles: Int,
        usesHysteria2: Boolean,
        cellular: Boolean,
        periodicHealthCheck: Boolean,
        sawDefaultNetwork: Boolean,
        hasDefaultNetwork: Boolean,
        runtimeWasReady: Boolean,
        alreadyAttempted: Boolean,
    ): Boolean = failedCycles == 1 &&
        requiresExtendedReadinessConfirmation(usesHysteria2, cellular) &&
        periodicHealthCheck && sawDefaultNetwork && hasDefaultNetwork &&
        runtimeWasReady && !alreadyAttempted
}
