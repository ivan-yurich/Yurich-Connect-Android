package com.tecclub.flutter_singbox.bg

import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class TunnelFlapDetectorTest {
    @Test
    fun `repeated degraded quorums trigger recovery inside the window`() {
        val detector = TunnelFlapDetector(threshold = 4, windowMs = 300_000L)

        assertFalse(detector.record(0L, 2, 3))
        assertFalse(detector.record(60_000L, 2, 3))
        assertFalse(detector.record(120_000L, 3, 3))
        assertFalse(detector.record(180_000L, 1, 3))
        assertTrue(detector.record(240_000L, 2, 3))
    }

    @Test
    fun `sparse endpoint failures do not trigger recovery`() {
        val detector = TunnelFlapDetector(threshold = 3, windowMs = 60_000L)

        assertFalse(detector.record(0L, 2, 3))
        assertFalse(detector.record(61_000L, 2, 3))
        assertFalse(detector.record(122_000L, 1, 3))
    }

    @Test
    fun `reset discards previous degradation history`() {
        val detector = TunnelFlapDetector(threshold = 2, windowMs = 60_000L)

        assertFalse(detector.record(0L, 1, 3))
        detector.reset()
        assertFalse(detector.record(10_000L, 1, 3))
        assertTrue(detector.record(20_000L, 1, 3))
    }

    @Test
    fun `full quorum and invalid totals are ignored`() {
        val detector = TunnelFlapDetector(threshold = 1, windowMs = 60_000L)

        assertFalse(detector.record(0L, 3, 3))
        assertFalse(detector.record(1L, 0, 0))
    }
}
