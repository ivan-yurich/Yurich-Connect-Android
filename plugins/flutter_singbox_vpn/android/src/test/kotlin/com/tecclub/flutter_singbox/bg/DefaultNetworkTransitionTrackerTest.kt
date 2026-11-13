package com.tecclub.flutter_singbox.bg

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class DefaultNetworkTransitionTrackerTest {
    @Test
    fun `same physical handle becoming validated wakes once`() {
        val tracker = DefaultNetworkTransitionTracker<Int>()
        assertEquals(DefaultNetworkTransition.Changed, tracker.observe(1, false))
        assertNull(tracker.observe(1, false))
        assertEquals(DefaultNetworkTransition.Validated, tracker.observe(1, true))
        assertNull(tracker.observe(1, true))
    }

    @Test
    fun `unknown capabilities do not erase a previously validated observation`() {
        val tracker = DefaultNetworkTransitionTracker<Int>()
        assertEquals(DefaultNetworkTransition.Changed, tracker.observe(1, true))
        assertNull(tracker.observe(1, null))
        assertNull(tracker.observe(1, true))
    }

    @Test
    fun `loss and a different handle invalidate the old observation`() {
        val tracker = DefaultNetworkTransitionTracker<Int>()
        assertEquals(DefaultNetworkTransition.Changed, tracker.observe(1, true))
        assertEquals(DefaultNetworkTransition.Changed, tracker.observe(null, false))
        assertNull(tracker.observe(null, true))
        assertEquals(DefaultNetworkTransition.Changed, tracker.observe(2, null))
        assertEquals(DefaultNetworkTransition.Validated, tracker.observe(2, true))
        assertNull(tracker.observe(2, true))
    }

    @Test
    fun `a real validation loss allows one fresh edge when the same path returns`() {
        val tracker = DefaultNetworkTransitionTracker<Int>()
        assertEquals(DefaultNetworkTransition.Changed, tracker.observe(1, true))
        assertNull(tracker.observe(1, false))
        assertEquals(DefaultNetworkTransition.Validated, tracker.observe(1, true))
        assertNull(tracker.observe(1, true))
    }
}
