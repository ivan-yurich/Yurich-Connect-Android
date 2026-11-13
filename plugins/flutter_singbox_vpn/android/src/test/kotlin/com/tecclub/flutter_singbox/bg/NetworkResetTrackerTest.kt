package com.tecclub.flutter_singbox.bg

import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class NetworkResetTrackerTest {
    @Test
    fun `first observation from a wake event preserves the physical transition`() {
        val tracker = NetworkResetTracker<String>()
        tracker.markCurrent("wifi")
        val wake = tracker.observeNetwork("cellular")
        assertTrue(wake.changed)
        assertTrue(wake.resetRuntime)
        assertFalse(TunnelReadinessPolicy.shouldDebounceNetworkEvent(200L, 5_000L, wake.changed))
        val duplicate = tracker.observeNetwork("cellular")
        assertFalse(duplicate.changed)
        assertFalse(duplicate.resetRuntime)
    }

    @Test
    fun `loss and restoration remain distinct atomic observations`() {
        val tracker = NetworkResetTracker<String>()
        tracker.markCurrent("wifi")
        val lost = tracker.observeNetwork(null)
        assertTrue(lost.changed)
        assertFalse(lost.resetRuntime)
        val restored = tracker.observeNetwork("wifi")
        assertTrue(restored.changed)
        assertTrue(restored.resetRuntime)
    }

    @Test
    fun `network loss is a change even though it cannot reset onto a new network`() {
        val tracker = NetworkResetTracker<String>()
        tracker.markCurrent("wifi")
        assertTrue(tracker.isDifferentNetwork(null))
        assertFalse(tracker.onNetworkEvent(null))
        assertFalse(tracker.isDifferentNetwork(null))
        assertTrue(tracker.isDifferentNetwork("cellular"))
        assertTrue(tracker.onNetworkEvent("cellular"))
        assertFalse(tracker.isDifferentNetwork("cellular"))
    }

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
