package com.tecclub.flutter_singbox.bg

import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class TunnelReadinessPolicyTest {
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
    fun `runtime restart is deferred during startup grace`() {
        assertFalse(
            TunnelReadinessPolicy.canRestartAfterStartupGrace(
                nowMs = 22_000L,
                startAttemptAtMs = 10_000L,
                graceMs = 30_000L,
            )
        )
    }

    @Test
    fun `runtime restart is allowed after startup grace`() {
        assertTrue(
            TunnelReadinessPolicy.canRestartAfterStartupGrace(
                nowMs = 40_000L,
                startAttemptAtMs = 10_000L,
                graceMs = 30_000L,
            )
        )
    }

    @Test
    fun `cleared startup marker allows recovery after confirmed readiness`() {
        assertTrue(
            TunnelReadinessPolicy.canRestartAfterStartupGrace(
                nowMs = 20_000L,
                startAttemptAtMs = 0L,
                graceMs = 30_000L,
            )
        )
    }
}
