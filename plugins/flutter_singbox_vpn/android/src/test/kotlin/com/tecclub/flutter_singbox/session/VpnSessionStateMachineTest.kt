package com.tecclub.flutter_singbox.session

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class VpnSessionStateMachineTest {
    @Test
    fun `manual stop invalidates a late start result`() {
        val state = VpnSessionStateMachine()
        val start = state.requestStart("user-connect")
        val stop = state.requestStop("user-disconnect")

        assertFalse(state.markConnected(start.generation, "late-core-start"))
        assertTrue(state.markStopped(stop.generation, "core-stopped", clearDesiredRunning = true))
        assertEquals(VpnSessionPhase.Stopped, state.snapshot().phase)
        assertFalse(state.snapshot().desiredRunning)
    }

    @Test
    fun `latest profile switch generation wins`() {
        val state = VpnSessionStateMachine()
        val first = state.requestStart("profile-a")
        val second = state.requestStart("profile-b")

        assertFalse(state.markConnected(first.generation, "profile-a-connected"))
        assertTrue(state.markConnected(second.generation, "profile-b-connected"))
        assertEquals(VpnSessionPhase.Connected, state.snapshot().phase)
        assertEquals("profile-b-connected", state.snapshot().reason)
    }

    @Test
    fun `reconnect is rejected after manual stop`() {
        val state = VpnSessionStateMachine()
        val start = state.requestStart("connect")
        assertTrue(state.markConnected(start.generation, "connected"))
        state.requestStop("manual-stop")

        assertNull(state.requestReconnect("watchdog"))
    }

    @Test
    fun `reconnect keeps desired running and accepts only its generation`() {
        val state = VpnSessionStateMachine()
        val start = state.requestStart("connect")
        assertTrue(state.markConnected(start.generation, "connected"))

        val reconnect = assertNotNull(state.requestReconnect("network-change"))
        assertEquals(VpnSessionPhase.Reconnecting, reconnect.phase)
        assertTrue(reconnect.desiredRunning)
        assertFalse(state.markConnected(start.generation, "stale-connected"))
        assertTrue(state.markConnected(reconnect.generation, "recovered"))
    }

    @Test
    fun `failed startup can clear automatic restart intent`() {
        val state = VpnSessionStateMachine()
        val start = state.requestStart("connect")

        assertTrue(
            state.markFailed(
                start.generation,
                reason = "invalid-config",
                keepDesiredRunning = false,
            ),
        )
        assertEquals(VpnSessionPhase.Failed, state.snapshot().phase)
        assertFalse(state.snapshot().desiredRunning)
        assertNull(state.requestReconnect("watchdog"))
    }
}
