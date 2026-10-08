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

    fun retryDelayMs(state: WatchdogRecoveryState, nowMs: Long, idle: Boolean): Long {
        val remaining = if (nowMs < state.lastRestartAtMs) 0L
            else (cooldownMs(state.attempts) - (nowMs - state.lastRestartAtMs)).coerceAtLeast(0L)
        return remaining.coerceIn(20_000L, if (idle) 90_000L else 60_000L)
    }
}
