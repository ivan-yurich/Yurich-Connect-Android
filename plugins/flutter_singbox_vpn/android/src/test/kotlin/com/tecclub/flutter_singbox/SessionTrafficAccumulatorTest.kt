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
    fun `snapshot restore survives a collector recreation`() {
        val firstCollector = SessionTrafficAccumulator()
        firstCollector.observe(1_000L, 2_000L)
        firstCollector.observe(1_250L, 2_500L)

        val restoredCollector = SessionTrafficAccumulator()
        assertEquals(
            SessionTrafficTotals(1_250L, 2_500L),
            restoredCollector.restore(firstCollector.snapshot()),
        )
        assertEquals(
            SessionTrafficTotals(1_300L, 2_600L),
            restoredCollector.observe(1_300L, 2_600L),
        )
    }

    @Test
    fun `restored collector preserves totals when provider restarts at zero`() {
        val counters = SessionTrafficAccumulator()
        counters.restore(
            SessionTrafficSnapshot(
                lastUplink = 5_000L,
                lastDownlink = 8_000L,
                uplink = 5_000L,
                downlink = 8_000L,
            ),
        )

        assertEquals(SessionTrafficTotals(5_000L, 8_000L), counters.observe(0L, 0L))
        assertEquals(SessionTrafficTotals(5_010L, 8_020L), counters.observe(10L, 20L))
    }

    @Test
    fun `transient zero before restored raw total does not double count`() {
        val counters = SessionTrafficAccumulator()
        counters.restore(
            SessionTrafficSnapshot(
                lastUplink = 5_000L,
                lastDownlink = 8_000L,
                uplink = 5_000L,
                downlink = 8_000L,
            ),
        )

        assertEquals(SessionTrafficTotals(5_000L, 8_000L), counters.observe(0L, 0L))
        assertEquals(
            SessionTrafficTotals(5_010L, 8_020L),
            counters.observe(5_010L, 8_020L),
        )
    }

    @Test
    fun `invalid persisted snapshot fails closed to zero`() {
        val counters = SessionTrafficAccumulator()
        counters.observe(100L, 200L)

        assertEquals(
            SessionTrafficTotals(0L, 0L),
            counters.restore(SessionTrafficSnapshot(-1L, 2L, 3L, 4L)),
        )
        assertEquals(SessionTrafficSnapshot(0L, 0L, 0L, 0L), counters.snapshot())
    }

    @Test
    fun `persisted raw total accounts for delta after collector recreation`() {
        val firstCollector = SessionTrafficTracker()
        assertEquals(
            SessionTrafficTotals(0L, 0L),
            firstCollector.observe(SessionTrafficSource.SING_BOX, 1_000L, 2_000L),
        )
        assertEquals(
            SessionTrafficTotals(250L, 500L),
            firstCollector.observe(SessionTrafficSource.SING_BOX, 1_250L, 2_500L),
        )

        val recreatedCollector = SessionTrafficTracker()
        assertEquals(
            SessionTrafficTotals(250L, 500L),
            recreatedCollector.restore(firstCollector.snapshot()),
        )
        assertEquals(
            SessionTrafficTotals(300L, 600L),
            recreatedCollector.observe(SessionTrafficSource.SING_BOX, 1_300L, 2_600L),
        )
    }

    @Test
    fun `explicit new session primes provider totals without double count`() {
        val counters = SessionTrafficTracker()
        counters.observe(SessionTrafficSource.UID, 10_000L, 20_000L)
        assertEquals(
            SessionTrafficTotals(100L, 200L),
            counters.observe(SessionTrafficSource.UID, 10_100L, 20_200L),
        )

        counters.reset()

        assertEquals(
            SessionTrafficTotals(0L, 0L),
            counters.observe(SessionTrafficSource.UID, 50_000L, 70_000L),
        )
        assertEquals(
            SessionTrafficTotals(10L, 20L),
            counters.observe(SessionTrafficSource.UID, 50_010L, 70_020L),
        )
    }

    @Test
    fun `provider switch rebases raw totals without double count`() {
        val counters = SessionTrafficTracker()
        counters.observe(SessionTrafficSource.UID, 1_000L, 2_000L)
        counters.observe(SessionTrafficSource.UID, 1_100L, 2_200L)

        assertEquals(
            SessionTrafficTotals(100L, 200L),
            counters.observe(SessionTrafficSource.SING_BOX, 500L, 700L),
        )
        assertEquals(
            SessionTrafficTotals(150L, 300L),
            counters.observe(SessionTrafficSource.SING_BOX, 550L, 800L),
        )
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
