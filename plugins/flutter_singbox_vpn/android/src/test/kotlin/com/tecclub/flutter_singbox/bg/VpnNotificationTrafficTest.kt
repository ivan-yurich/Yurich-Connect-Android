package com.tecclub.flutter_singbox.bg

import com.tecclub.flutter_singbox.model.ConnectionStatus
import com.tecclub.flutter_singbox.model.ConnectionUiState
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class VpnNotificationTrafficTest {
    private val connected = ConnectionUiState.connected(
        uploadSpeed = "12.50 KB/s", downloadSpeed = "2.25 MB/s", pingMs = 84,
    )

    @Test fun showsReceivedAndSentRatesOnlyForConnectedTunnel() {
        assertEquals("↓ 2.25 MB/s · ↑ 12.50 KB/s", VpnNotificationTraffic.line(connected, 100_000))
        assertNull(VpnNotificationTraffic.line(connected.copy(status = ConnectionStatus.Connecting), 100_000))
        assertNull(VpnNotificationTraffic.line(connected.copy(status = ConnectionStatus.Disconnected), 100_000))
    }

    @Test fun optionalLatencyNeedsARecentTimestampAndExpiresWithoutNewProbe() {
        val timed = connected.copy(pingObservedAtMs = 40_001)
        assertEquals("↓ 2.25 MB/s · ↑ 12.50 KB/s · 84 ms", VpnNotificationTraffic.line(timed, 100_000))
        assertEquals("↓ 2.25 MB/s · ↑ 12.50 KB/s", VpnNotificationTraffic.line(timed, 100_001))
        assertNull(VpnNotificationTraffic.freshPing(timed, 40_000))
        assertNull(VpnNotificationTraffic.freshPing(timed.copy(pingMs = 0), 100_000))
    }

    @Test fun invalidRateNeverBecomesNotificationTextAndZeroIsDisplayed() {
        val rates = connected.copy(uploadSpeed = "not a rate", downloadSpeed = "0 B/s")
        assertEquals("↓ 0 B/s · ↑ —", VpnNotificationTraffic.line(rates, 100_000))
    }

    @Test fun timestampComesFromExplicitNumericFieldInFlutterPayload() {
        val state = ConnectionUiState.fromMap(mapOf(
            "status" to "connected", "pingMs" to 84, "pingObservedAtMs" to 40_001L,
        ))
        assertEquals(84L, VpnNotificationTraffic.freshPing(state, 100_000))
        val withoutTimestamp = ConnectionUiState.fromMap(mapOf("status" to "connected", "pingMs" to 84))
        assertNull(VpnNotificationTraffic.freshPing(withoutTimestamp, 100_000))
    }
}
