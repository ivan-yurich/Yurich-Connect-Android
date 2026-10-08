package com.tecclub.flutter_singbox

import com.tecclub.flutter_singbox.constant.Status
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class SessionTrafficAccumulatorTest {
    @Test
    fun `normal samples preserve byte totals`() {
        val counters = SessionTrafficAccumulator()
        assertEquals(300L, counters.observe(100L, 200L).total)
        assertEquals(SessionTrafficTotals(120L, 250L), counters.observe(120L, 250L))
    }

    @Test
    fun `repeated sample does not count twice`() {
        val counters = SessionTrafficAccumulator()
        counters.observe(100L, 200L)
        assertEquals(300L, counters.observe(100L, 200L).total)
    }

    @Test
    fun `provider reset preserves total and counts new traffic immediately`() {
        val counters = SessionTrafficAccumulator()
        counters.observe(100L, 200L)
        assertEquals(300L, counters.observe(0L, 0L).total)
        assertEquals(330L, counters.observe(10L, 20L).total)
    }

    @Test
    fun `direction resets are independent`() {
        val counters = SessionTrafficAccumulator()
        counters.observe(100L, 200L)
        assertEquals(SessionTrafficTotals(110L, 250L), counters.observe(10L, 250L))
    }

    @Test
    fun `explicit new session does not inherit old traffic`() {
        val counters = SessionTrafficAccumulator()
        counters.observe(1_000_000L, 2_000_000L)
        counters.reset()
        assertEquals(30L, counters.observe(10L, 20L).total)
    }

    @Test
    fun `negative samples and overflow cannot produce negative totals`() {
        val counters = SessionTrafficAccumulator()
        assertEquals(0L, counters.observe(-1L, -100L).total)
        assertEquals(Long.MAX_VALUE, counters.observe(Long.MAX_VALUE, Long.MAX_VALUE).total)
        counters.observe(0L, 0L)
        assertEquals(Long.MAX_VALUE, counters.observe(1L, 1L).total)
    }

    @Test
    fun `invalid samples do not turn into false provider resets`() {
        val counters = SessionTrafficAccumulator()
        counters.observe(100L, 200L)
        assertEquals(300L, counters.observe(-1L, -1L).total)
        assertEquals(300L, counters.observe(100L, 200L).total)
    }

    @Test
    fun `singbox traffic is accepted only after readiness`() {
        for (status in Status.entries) {
            assertEquals(status == Status.Started, SessionTrafficAccumulator.shouldCollect(status, false))
        }
        assertTrue(SessionTrafficAccumulator.shouldCollect(Status.Started, false))
    }

    @Test
    fun `stale singbox samples cannot replace xray statistics`() {
        for (status in Status.entries) {
            assertFalse(SessionTrafficAccumulator.shouldCollect(status, true))
        }
    }
}
