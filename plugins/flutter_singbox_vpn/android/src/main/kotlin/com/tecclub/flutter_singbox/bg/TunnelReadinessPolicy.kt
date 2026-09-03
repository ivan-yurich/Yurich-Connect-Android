package com.tecclub.flutter_singbox.bg

internal object TunnelReadinessPolicy {
    const val REQUIRED_ENDPOINT_SUCCESSES = 2

    fun isHealthy(successfulEndpoints: Int, totalEndpoints: Int): Boolean {
        if (totalEndpoints < REQUIRED_ENDPOINT_SUCCESSES) {
            return false
        }
        return successfulEndpoints >= REQUIRED_ENDPOINT_SUCCESSES
    }

    fun canRestart(
        nowMs: Long,
        lastRestartAtMs: Long,
        cooldownMs: Long,
        allowCooldownBypass: Boolean = false,
    ): Boolean {
        if (cooldownMs < 0L) {
            return false
        }
        return allowCooldownBypass ||
            lastRestartAtMs == 0L ||
            nowMs < lastRestartAtMs ||
            nowMs - lastRestartAtMs >= cooldownMs
    }

    fun canRestartAfterStartupGrace(
        nowMs: Long,
        startAttemptAtMs: Long,
        graceMs: Long,
    ): Boolean {
        if (graceMs < 0L) {
            return false
        }
        return startAttemptAtMs == 0L ||
            nowMs < startAttemptAtMs ||
            nowMs - startAttemptAtMs >= graceMs
    }
}
