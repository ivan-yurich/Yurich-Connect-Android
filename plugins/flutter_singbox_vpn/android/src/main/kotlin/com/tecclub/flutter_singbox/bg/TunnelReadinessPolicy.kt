package com.tecclub.flutter_singbox.bg

import com.tecclub.flutter_singbox.session.VpnSessionPhase

internal data class NetworkReadinessPlan(
    val initialDelayMs: Long,
    val probeAttempts: Int,
)

internal data class LifecyclePhaseStamp(
    val generation: Long,
    val phase: VpnSessionPhase,
    val startedAtElapsedMs: Long,
)

internal object TunnelReadinessPolicy {
    const val REQUIRED_ENDPOINT_SUCCESSES = 2
    const val MIN_NETWORK_CHANGE_PROBE_ATTEMPTS = 2

    fun isHealthy(successfulEndpoints: Int, totalEndpoints: Int): Boolean {
        if (totalEndpoints < REQUIRED_ENDPOINT_SUCCESSES ||
            successfulEndpoints < 0 || successfulEndpoints > totalEndpoints
        ) {
            return false
        }
        return successfulEndpoints >= REQUIRED_ENDPOINT_SUCCESSES
    }

    fun canHandleNetworkEvent(
        phase: VpnSessionPhase,
        desiredRunning: Boolean,
        runtimeActive: Boolean,
        restarting: Boolean,
    ): Boolean = desiredRunning && runtimeActive && !restarting && phase in setOf(
        VpnSessionPhase.Starting, VpnSessionPhase.Reconnecting, VpnSessionPhase.Connected,
    )

    fun isPhysicalInternetNetwork(
        capabilitiesKnown: Boolean,
        internetCapable: Boolean,
        vpnTransport: Boolean,
    ): Boolean = capabilitiesKnown && internetCapable && !vpnTransport

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

    fun canRestartAfterPhaseGrace(
        nowMs: Long,
        currentGeneration: Long,
        currentPhase: VpnSessionPhase,
        phaseStamp: LifecyclePhaseStamp,
        graceMs: Long,
    ): Boolean {
        if (graceMs < 0L ||
            phaseStamp.generation != currentGeneration ||
            phaseStamp.phase != currentPhase ||
            nowMs < phaseStamp.startedAtElapsedMs
        ) {
            return false
        }
        return nowMs - phaseStamp.startedAtElapsedMs >= graceMs
    }

    fun isStaleLifecyclePhase(
        nowMs: Long,
        currentGeneration: Long,
        currentPhase: VpnSessionPhase,
        phaseStamp: LifecyclePhaseStamp,
        timeoutMs: Long,
        runtimeActive: Boolean,
    ): Boolean {
        if (runtimeActive || timeoutMs < 0L ||
            currentPhase !in setOf(
                VpnSessionPhase.Starting,
                VpnSessionPhase.Reconnecting,
                VpnSessionPhase.Stopping,
            ) ||
            phaseStamp.generation != currentGeneration ||
            phaseStamp.phase != currentPhase ||
            nowMs < phaseStamp.startedAtElapsedMs
        ) {
            return false
        }
        return nowMs - phaseStamp.startedAtElapsedMs >= timeoutMs
    }

    fun networkChangePlan(
        runtimeCore: VpnRuntimeCore?,
        defaultInitialDelayMs: Long,
        xrayInitialDelayMs: Long,
        defaultProbeAttempts: Int,
    ): NetworkReadinessPlan {
        require(defaultInitialDelayMs >= 0L)
        require(xrayInitialDelayMs >= 0L)
        require(defaultProbeAttempts > 0)
        return if (runtimeCore == VpnRuntimeCore.Xray) {
            NetworkReadinessPlan(
                initialDelayMs = xrayInitialDelayMs,
                probeAttempts = maxOf(
                    MIN_NETWORK_CHANGE_PROBE_ATTEMPTS,
                    defaultProbeAttempts,
                ),
            )
        } else {
            NetworkReadinessPlan(
                initialDelayMs = defaultInitialDelayMs,
                probeAttempts = maxOf(
                    MIN_NETWORK_CHANGE_PROBE_ATTEMPTS,
                    defaultProbeAttempts,
                ),
            )
        }
    }

    fun shouldDebounceNetworkEvent(
        elapsedSinceLastEventMs: Long,
        debounceMs: Long,
        networkChanged: Boolean,
    ): Boolean {
        if (networkChanged || elapsedSinceLastEventMs < 0L || debounceMs < 0L) {
            return false
        }
        return elapsedSinceLastEventMs < debounceMs
    }
}
