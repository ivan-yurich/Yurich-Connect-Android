package com.tecclub.flutter_singbox.bg

import com.tecclub.flutter_singbox.session.VpnSessionPhase
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class TunnelReadinessPolicyTest {
    @Test
    fun `starting runtime handles a physical network handover`() {
        assertTrue(TunnelReadinessPolicy.canHandleNetworkEvent(
            VpnSessionPhase.Starting, true, true, false,
        ))
        assertTrue(TunnelReadinessPolicy.canHandleNetworkEvent(
            VpnSessionPhase.Reconnecting, true, true, false,
        ))
    }

    @Test
    fun `network callbacks cannot revive a manually stopped or absent runtime`() {
        for (phase in VpnSessionPhase.entries) {
            assertFalse(TunnelReadinessPolicy.canHandleNetworkEvent(phase, false, true, false))
            assertFalse(TunnelReadinessPolicy.canHandleNetworkEvent(phase, true, false, false))
            assertFalse(TunnelReadinessPolicy.canHandleNetworkEvent(phase, true, true, true))
        }
        for (phase in listOf(VpnSessionPhase.Stopped, VpnSessionPhase.Stopping, VpnSessionPhase.Failed)) {
            assertFalse(TunnelReadinessPolicy.canHandleNetworkEvent(phase, true, true, false))
        }
    }

    @Test
    fun `own VPN never substitutes for a physical internet network`() {
        assertFalse(TunnelReadinessPolicy.isPhysicalInternetNetwork(true, true, true))
        assertFalse(TunnelReadinessPolicy.isPhysicalInternetNetwork(false, true, false))
        assertFalse(TunnelReadinessPolicy.isPhysicalInternetNetwork(true, false, false))
        assertTrue(TunnelReadinessPolicy.isPhysicalInternetNetwork(true, true, false))
    }

    @Test
    fun `invalid quorum counts cannot confirm readiness`() {
        assertFalse(TunnelReadinessPolicy.isHealthy(4, 3))
        assertFalse(TunnelReadinessPolicy.isHealthy(-1, 3))
        assertFalse(TunnelReadinessPolicy.isHealthy(2, 1))
    }

    @Test
    fun `one endpoint cannot report the tunnel ready`() {
        assertFalse(TunnelReadinessPolicy.isHealthy(1, 3))
    }

    @Test
    fun `two independent endpoints confirm readiness`() {
        assertTrue(TunnelReadinessPolicy.isHealthy(2, 3))
    }

    @Test
    fun `restart is blocked inside cooldown across service instances`() {
        assertFalse(
            TunnelReadinessPolicy.canRestart(
                nowMs = 15_000L,
                lastRestartAtMs = 10_000L,
                cooldownMs = 90_000L,
            )
        )
    }

    @Test
    fun `restart is allowed after cooldown`() {
        assertTrue(
            TunnelReadinessPolicy.canRestart(
                nowMs = 100_000L,
                lastRestartAtMs = 10_000L,
                cooldownMs = 90_000L,
            )
        )
    }

    @Test
    fun `new physical network may bypass cooldown once`() {
        assertTrue(
            TunnelReadinessPolicy.canRestart(
                nowMs = 15_000L,
                lastRestartAtMs = 10_000L,
                cooldownMs = 90_000L,
                allowCooldownBypass = true,
            )
        )
    }

    @Test
    fun `first restart is allowed`() {
        assertTrue(
            TunnelReadinessPolicy.canRestart(
                nowMs = 10_000L,
                lastRestartAtMs = 0L,
                cooldownMs = 90_000L,
            )
        )
    }

    @Test
    fun `runtime restart is deferred during current generation phase grace`() {
        assertFalse(
            TunnelReadinessPolicy.canRestartAfterPhaseGrace(
                nowMs = 22_000L,
                currentGeneration = 4L,
                currentPhase = VpnSessionPhase.Reconnecting,
                phaseStamp = LifecyclePhaseStamp(
                    generation = 4L,
                    phase = VpnSessionPhase.Reconnecting,
                    startedAtElapsedMs = 10_000L,
                ),
                graceMs = 30_000L,
            )
        )
    }

    @Test
    fun `runtime restart is allowed after current generation phase grace`() {
        assertTrue(
            TunnelReadinessPolicy.canRestartAfterPhaseGrace(
                nowMs = 40_000L,
                currentGeneration = 4L,
                currentPhase = VpnSessionPhase.Reconnecting,
                phaseStamp = LifecyclePhaseStamp(
                    generation = 4L,
                    phase = VpnSessionPhase.Reconnecting,
                    startedAtElapsedMs = 10_000L,
                ),
                graceMs = 30_000L,
            )
        )
    }

    @Test
    fun `stale generation cannot authorize runtime restart`() {
        assertFalse(
            TunnelReadinessPolicy.canRestartAfterPhaseGrace(
                nowMs = 50_000L,
                currentGeneration = 5L,
                currentPhase = VpnSessionPhase.Reconnecting,
                phaseStamp = LifecyclePhaseStamp(
                    generation = 4L,
                    phase = VpnSessionPhase.Reconnecting,
                    startedAtElapsedMs = 10_000L,
                ),
                graceMs = 30_000L,
            )
        )
    }

    @Test
    fun `monotonic clock rollback cannot authorize runtime restart`() {
        assertFalse(
            TunnelReadinessPolicy.canRestartAfterPhaseGrace(
                nowMs = 9_000L,
                currentGeneration = 4L,
                currentPhase = VpnSessionPhase.Reconnecting,
                phaseStamp = LifecyclePhaseStamp(
                    generation = 4L,
                    phase = VpnSessionPhase.Reconnecting,
                    startedAtElapsedMs = 10_000L,
                ),
                graceMs = 30_000L,
            )
        )
    }

    @Test
    fun `previous phase timestamp cannot authorize runtime restart`() {
        assertFalse(
            TunnelReadinessPolicy.canRestartAfterPhaseGrace(
                nowMs = 100_000L,
                currentGeneration = 4L,
                currentPhase = VpnSessionPhase.Reconnecting,
                phaseStamp = LifecyclePhaseStamp(
                    generation = 4L,
                    phase = VpnSessionPhase.Connected,
                    startedAtElapsedMs = 10_000L,
                ),
                graceMs = 30_000L,
            )
        )
    }

    @Test
    fun `xray network changes require two quorum failures before restart`() {
        val plan = TunnelReadinessPolicy.networkChangePlan(
            runtimeCore = VpnRuntimeCore.Xray,
            defaultInitialDelayMs = 6_000L,
            xrayInitialDelayMs = 4_000L,
            defaultProbeAttempts = 1,
        )

        assertEquals(4_000L, plan.initialDelayMs)
        assertEquals(2, plan.probeAttempts)
    }

    @Test
    fun `singbox network changes retain conservative readiness probes`() {
        val plan = TunnelReadinessPolicy.networkChangePlan(
            runtimeCore = VpnRuntimeCore.SingBox,
            defaultInitialDelayMs = 6_000L,
            xrayInitialDelayMs = 1_000L,
            defaultProbeAttempts = 2,
        )

        assertEquals(6_000L, plan.initialDelayMs)
        assertEquals(2, plan.probeAttempts)
    }

    @Test
    fun `duplicate callback is debounced while readiness is active`() {
        assertTrue(
            TunnelReadinessPolicy.shouldDebounceNetworkEvent(
                elapsedSinceLastEventMs = 2_500L,
                debounceMs = 5_000L,
                networkChanged = false,
            )
        )
    }

    @Test
    fun `new physical network bypasses callback debounce`() {
        assertFalse(
            TunnelReadinessPolicy.shouldDebounceNetworkEvent(
                elapsedSinceLastEventMs = 200L,
                debounceMs = 5_000L,
                networkChanged = true,
            )
        )
    }

    @Test
    fun `active runtime cannot be declared stale`() {
        assertFalse(
            TunnelReadinessPolicy.isStaleLifecyclePhase(
                nowMs = 100_000L,
                currentGeneration = 7L,
                currentPhase = VpnSessionPhase.Stopping,
                phaseStamp = LifecyclePhaseStamp(
                    generation = 7L,
                    phase = VpnSessionPhase.Stopping,
                    startedAtElapsedMs = 10_000L,
                ),
                timeoutMs = 30_000L,
                runtimeActive = true,
            )
        )
    }

    @Test
    fun `inactive current generation phase becomes stale only after monotonic timeout`() {
        val stamp = LifecyclePhaseStamp(
            generation = 7L,
            phase = VpnSessionPhase.Stopping,
            startedAtElapsedMs = 10_000L,
        )
        assertFalse(
            TunnelReadinessPolicy.isStaleLifecyclePhase(
                nowMs = 39_999L,
                currentGeneration = 7L,
                currentPhase = VpnSessionPhase.Stopping,
                phaseStamp = stamp,
                timeoutMs = 30_000L,
                runtimeActive = false,
            )
        )
        assertTrue(
            TunnelReadinessPolicy.isStaleLifecyclePhase(
                nowMs = 40_000L,
                currentGeneration = 7L,
                currentPhase = VpnSessionPhase.Stopping,
                phaseStamp = stamp,
                timeoutMs = 30_000L,
                runtimeActive = false,
            )
        )
    }
}
