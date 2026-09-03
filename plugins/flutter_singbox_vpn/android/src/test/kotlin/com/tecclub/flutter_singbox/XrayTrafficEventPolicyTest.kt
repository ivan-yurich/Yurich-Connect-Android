package com.tecclub.flutter_singbox

import com.tecclub.flutter_singbox.constant.Status
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class XrayTrafficEventPolicyTest {
    @Test
    fun `collects only for a started Xray runtime`() {
        assertTrue(XrayTrafficEventPolicy.shouldCollect(Status.Started, true))
        assertFalse(XrayTrafficEventPolicy.shouldCollect(Status.Started, false))
        assertFalse(XrayTrafficEventPolicy.shouldCollect(Status.Starting, true))
        assertFalse(XrayTrafficEventPolicy.shouldCollect(Status.Stopped, true))
    }

    @Test
    fun `maps UID counters to the Flutter traffic contract`() {
        val stats = XrayTrafficEventPolicy.build(
            sample = XrayUidTrafficSample(
                txTotal = 10_000L,
                rxTotal = 20_000L,
                txSpeed = 1_024L,
                rxSpeed = 2_048L,
                sessionTx = 3_000L,
                sessionRx = 7_000L,
            ),
            networkSnapshot = mapOf("networkType" to "wifi", "generation" to 4),
        )

        assertEquals(1_024L, stats["uplinkSpeed"])
        assertEquals(2_048L, stats["downlinkSpeed"])
        assertEquals(3_000L, stats["sessionUplink"])
        assertEquals(7_000L, stats["sessionDownlink"])
        assertEquals(10_000L, stats["sessionTotal"])
        assertEquals("1.00 KB/s", stats["formattedUplinkSpeed"])
        assertEquals("2.00 KB/s", stats["formattedDownlinkSpeed"])
        assertEquals("9.77 KB", stats["formattedSessionTotal"])
        assertEquals("wifi", stats["networkType"])
        assertEquals(4, stats["generation"])
    }

    @Test
    fun `clamps unsupported counters instead of publishing negative traffic`() {
        val stats = XrayTrafficEventPolicy.build(
            sample = XrayUidTrafficSample(-1L, -1L, -1L, -1L, -1L, -1L),
            networkSnapshot = emptyMap(),
        )

        assertEquals(0L, stats["uplinkSpeed"])
        assertEquals(0L, stats["downlinkSpeed"])
        assertEquals(0L, stats["sessionTotal"])
        assertEquals("0 B", stats["formattedSessionTotal"])
    }

    @Test
    fun `idle event preserves totals and clears the last speed`() {
        val stats = XrayTrafficEventPolicy.build(
            sample = XrayUidTrafficSample(
                txTotal = 10_000L,
                rxTotal = 20_000L,
                txSpeed = 1_024L,
                rxSpeed = 2_048L,
                sessionTx = 3_000L,
                sessionRx = 7_000L,
            ),
            networkSnapshot = emptyMap(),
            active = false,
        )

        assertEquals(0L, stats["uplinkSpeed"])
        assertEquals(0L, stats["downlinkSpeed"])
        assertEquals(10_000L, stats["sessionTotal"])
        assertEquals("0 B/s", stats["formattedUplinkSpeed"])
        assertEquals("0 B/s", stats["formattedDownlinkSpeed"])
        assertEquals("9.77 KB", stats["formattedSessionTotal"])
    }
}
