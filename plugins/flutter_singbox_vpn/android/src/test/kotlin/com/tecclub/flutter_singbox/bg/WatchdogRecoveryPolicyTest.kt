package com.tecclub.flutter_singbox.bg

import com.tecclub.flutter_singbox.session.VpnSessionPhase
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class WatchdogRecoveryPolicyTest {
    @Test fun `repeated failures back off and remain capped`() {
        assertEquals(listOf(90_000L, 180_000L, 360_000L, 720_000L, 900_000L, 900_000L),
            (1..6).map(WatchdogRecoveryPolicy::cooldownMs))
        assertEquals(900_000L, WatchdogRecoveryPolicy.cooldownMs(Int.MAX_VALUE))
        assertEquals(90_000L, WatchdogRecoveryPolicy.cooldownMs(Int.MIN_VALUE))
    }

    @Test fun `budget survives a reconstructed VPN instance`() {
        val persisted = WatchdogRecoveryPolicy.restarted(WatchdogRecoveryState(attempts = 2), 100_000L)
        assertFalse(WatchdogRecoveryPolicy.canRestart(persisted.copy(), 190_000L, false))
        assertTrue(WatchdogRecoveryPolicy.canRestart(persisted.copy(), 460_000L, false))
    }

    @Test fun `brief success does not reset restart pressure`() {
        val state = WatchdogRecoveryState(100_000L, 4)
        val healthy = WatchdogRecoveryPolicy.observed(state, 110_000L, true)
        assertEquals(4, WatchdogRecoveryPolicy.observed(healthy, 200_000L, true).attempts)
        assertEquals(0L, WatchdogRecoveryPolicy.observed(healthy, 201_000L, false).healthySinceMs)
    }

    @Test fun `ten observed healthy minutes reset the pressure`() {
        var state = WatchdogRecoveryState(100_000L, 5)
        for (now in 110_000L..650_000L step 60_000L) {
            state = WatchdogRecoveryPolicy.observed(state, now, true)
            assertEquals(5, state.attempts)
        }
        assertEquals(0, WatchdogRecoveryPolicy.observed(state, 710_000L, true).attempts)
    }

    @Test fun `suspended observation is not ten healthy minutes`() {
        val state = WatchdogRecoveryState(100_000L, 5, 110_000L, 110_000L)
        val resumed = WatchdogRecoveryPolicy.observed(state, 900_000L, true)
        assertEquals(5, resumed.attempts)
        assertEquals(900_000L, resumed.healthySinceMs)
    }

    @Test fun `new physical network gets bounded early recovery`() {
        val state = WatchdogRecoveryState(100_000L, 5)
        assertFalse(WatchdogRecoveryPolicy.canRestart(state, 114_999L, true))
        assertTrue(WatchdogRecoveryPolicy.canRestart(state, 115_000L, true))
        assertFalse(WatchdogRecoveryPolicy.canRestart(state, 115_000L, false))
    }

    @Test fun `first recovery and elapsed rollback are allowed`() {
        assertTrue(WatchdogRecoveryPolicy.canRestart(WatchdogRecoveryState(), 1000, false))
        assertTrue(WatchdogRecoveryPolicy.canRestart(WatchdogRecoveryState(100_000, 5), 1000, false))
        assertFalse(WatchdogRecoveryPolicy.canRestart(WatchdogRecoveryState(), -1, false))
    }

    @Test fun `readiness probes use short cadence independent of restart cooldown`() {
        assertEquals(
            listOf(12_000L, 20_000L, 30_000L, 60_000L, 60_000L),
            (1..5).map { WatchdogRecoveryPolicy.readinessRetryDelayMs(it, false) },
        )
        assertEquals(
            listOf(30_000L, 60_000L, 90_000L, 90_000L),
            (1..4).map { WatchdogRecoveryPolicy.readinessRetryDelayMs(it, true) },
        )
        assertEquals(12_000L, WatchdogRecoveryPolicy.readinessRetryDelayMs(Int.MIN_VALUE, false))
    }

    @Test fun `hysteria2 on cellular requires a second failed readiness cycle`() {
        assertFalse(WatchdogRecoveryPolicy.canAttemptReadinessRestart(
            failedCycles = 1,
            usesHysteria2 = true,
            cellular = true,
        ))
        assertTrue(WatchdogRecoveryPolicy.canAttemptReadinessRestart(
            failedCycles = 2,
            usesHysteria2 = true,
            cellular = true,
        ))
    }

    @Test fun `other protocols and wifi retain immediate recovery`() {
        assertTrue(WatchdogRecoveryPolicy.canAttemptReadinessRestart(
            failedCycles = 1,
            usesHysteria2 = false,
            cellular = true,
        ))
        assertTrue(WatchdogRecoveryPolicy.canAttemptReadinessRestart(
            failedCycles = 1,
            usesHysteria2 = true,
            cellular = false,
        ))
        assertFalse(WatchdogRecoveryPolicy.canAttemptReadinessRestart(
            failedCycles = 0,
            usesHysteria2 = false,
            cellular = false,
        ))
    }

    @Test fun `hysteria2 cellular periodic health gets one soft reset before restart`() {
        assertTrue(WatchdogRecoveryPolicy.shouldAttemptHysteria2CellularSoftReset(
            failedCycles = 1,
            usesHysteria2 = true,
            cellular = true,
            periodicHealthCheck = true,
            sawDefaultNetwork = true,
            hasDefaultNetwork = true,
            runtimeWasReady = true,
            alreadyAttempted = false,
        ))
        assertFalse(WatchdogRecoveryPolicy.shouldAttemptHysteria2CellularSoftReset(
            failedCycles = 2,
            usesHysteria2 = true,
            cellular = true,
            periodicHealthCheck = true,
            sawDefaultNetwork = true,
            hasDefaultNetwork = true,
            runtimeWasReady = true,
            alreadyAttempted = false,
        ))
        assertFalse(WatchdogRecoveryPolicy.shouldAttemptHysteria2CellularSoftReset(
            failedCycles = 1,
            usesHysteria2 = true,
            cellular = true,
            periodicHealthCheck = true,
            sawDefaultNetwork = true,
            hasDefaultNetwork = true,
            runtimeWasReady = true,
            alreadyAttempted = true,
        ))
    }

    @Test fun `soft reset is excluded from startup wifi and non hysteria recovery`() {
        fun eligible(
            usesHysteria2: Boolean = true,
            cellular: Boolean = true,
            periodic: Boolean = true,
            sawNetwork: Boolean = true,
            hasNetwork: Boolean = true,
            runtimeWasReady: Boolean = true,
        ) = WatchdogRecoveryPolicy.shouldAttemptHysteria2CellularSoftReset(
            failedCycles = 1,
            usesHysteria2 = usesHysteria2,
            cellular = cellular,
            periodicHealthCheck = periodic,
            sawDefaultNetwork = sawNetwork,
            hasDefaultNetwork = hasNetwork,
            runtimeWasReady = runtimeWasReady,
            alreadyAttempted = false,
        )

        assertFalse(eligible(usesHysteria2 = false))
        assertFalse(eligible(cellular = false))
        assertFalse(eligible(periodic = false))
        assertFalse(eligible(sawNetwork = false))
        assertFalse(eligible(hasNetwork = false))
        assertFalse(eligible(runtimeWasReady = false))
    }

    @Test fun `new reconnect phase grace cannot suppress the established tunnel soft reset`() {
        val reconnectStartedAt = 100_000L
        val reconnectGraceElapsed = TunnelReadinessPolicy.canRestartAfterPhaseGrace(
            nowMs = reconnectStartedAt + 14_000L,
            currentGeneration = 3L,
            currentPhase = VpnSessionPhase.Reconnecting,
            phaseStamp = LifecyclePhaseStamp(
                generation = 3L,
                phase = VpnSessionPhase.Reconnecting,
                startedAtElapsedMs = reconnectStartedAt,
            ),
            graceMs = 30_000L,
        )

        assertFalse(reconnectGraceElapsed)
        assertTrue(WatchdogRecoveryPolicy.shouldAttemptHysteria2CellularSoftReset(
            failedCycles = 1,
            usesHysteria2 = true,
            cellular = true,
            periodicHealthCheck = true,
            sawDefaultNetwork = true,
            hasDefaultNetwork = true,
            runtimeWasReady = true,
            alreadyAttempted = false,
        ))
    }
}
