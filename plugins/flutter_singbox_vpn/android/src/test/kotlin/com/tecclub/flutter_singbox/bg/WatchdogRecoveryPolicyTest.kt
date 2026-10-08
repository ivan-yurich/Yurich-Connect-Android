package com.tecclub.flutter_singbox.bg

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

    @Test fun `retry probes wait without sleeping past the recovery budget`() {
        val state = WatchdogRecoveryState(100_000L, 5)
        assertEquals(60_000L, WatchdogRecoveryPolicy.retryDelayMs(state, 200_000L, false))
        assertEquals(90_000L, WatchdogRecoveryPolicy.retryDelayMs(state, 200_000L, true))
        assertEquals(20_000L, WatchdogRecoveryPolicy.retryDelayMs(state, 999_000L, false))
    }
}
