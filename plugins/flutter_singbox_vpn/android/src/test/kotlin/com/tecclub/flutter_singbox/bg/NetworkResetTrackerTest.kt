package com.tecclub.flutter_singbox.bg

import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class NetworkResetTrackerTest {
    @Test
    fun `duplicate callbacks for the active network do not reset runtime`() {
        val tracker = NetworkResetTracker<String>()

        tracker.markCurrent("wifi")

        assertFalse(tracker.onNetworkEvent("wifi"))
        assertFalse(tracker.onNetworkEvent("wifi"))
        assertFalse(tracker.hasRecoveryAllowance())
    }

    @Test
    fun `new network resets runtime exactly once`() {
        val tracker = NetworkResetTracker<String>()
        tracker.markCurrent("wifi")

        assertTrue(tracker.onNetworkEvent("cellular"))
        assertFalse(tracker.onNetworkEvent("cellular"))
        assertTrue(tracker.hasRecoveryAllowance())
        assertTrue(tracker.consumeRecoveryAllowance())
        assertFalse(tracker.consumeRecoveryAllowance())
    }

    @Test
    fun `network loss makes the restored network eligible for reset`() {
        val tracker = NetworkResetTracker<String>()
        tracker.markCurrent("cellular")

        assertFalse(tracker.onNetworkEvent(null))
        assertTrue(tracker.onNetworkEvent("cellular"))
        assertFalse(tracker.onNetworkEvent("cellular"))
        assertTrue(tracker.hasRecoveryAllowance())
    }

    @Test
    fun `clear forgets the previous runtime network`() {
        val tracker = NetworkResetTracker<String>()
        tracker.markCurrent("wifi")
        tracker.clear()

        assertTrue(tracker.onNetworkEvent("wifi"))
    }

    @Test
    fun `confirmed recovery clears unused restart allowance`() {
        val tracker = NetworkResetTracker<String>()
        tracker.markCurrent("wifi")
        assertTrue(tracker.onNetworkEvent("cellular"))

        tracker.markCurrent("cellular")

        assertFalse(tracker.hasRecoveryAllowance())
    }
}
