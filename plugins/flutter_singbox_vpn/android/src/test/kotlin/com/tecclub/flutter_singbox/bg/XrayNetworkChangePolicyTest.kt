package com.tecclub.flutter_singbox.bg

import com.tecclub.flutter_singbox.session.VpnSessionPhase
import com.tecclub.flutter_singbox.session.VpnSessionStateMachine
import kotlin.test.*

class XrayNetworkChangePolicyTest {
    @Test fun readyXrayRebindsOnceForAnAvailableChangedNetwork() {
        assertTrue(XrayNetworkChangePolicy.shouldRebind(VpnRuntimeCore.Xray, VpnSessionPhase.Connected, "ready", true, true, true))
        assertTrue(XrayNetworkChangePolicy.shouldRebind(VpnRuntimeCore.Xray, VpnSessionPhase.Reconnecting, "readiness:default-network", true, true, true))
    }
    @Test fun coldStartManualReconnectAndStoppedIntentDoNotRebind() {
        for (phase in VpnSessionPhase.entries.filter { it != VpnSessionPhase.Connected }) {
            assertFalse(XrayNetworkChangePolicy.shouldRebind(VpnRuntimeCore.Xray, phase, "service-reload", true, true, true))
        }
        assertFalse(XrayNetworkChangePolicy.shouldRebind(VpnRuntimeCore.Xray, VpnSessionPhase.Connected, "ready", true, true, false))
    }
    @Test fun duplicateMissingNetworkAndOtherCoreDoNotRebind() {
        assertFalse(XrayNetworkChangePolicy.shouldRebind(VpnRuntimeCore.Xray, VpnSessionPhase.Connected, "ready", false, true, true))
        assertFalse(XrayNetworkChangePolicy.shouldRebind(VpnRuntimeCore.Xray, VpnSessionPhase.Connected, "ready", true, false, true))
        assertFalse(XrayNetworkChangePolicy.shouldRebind(VpnRuntimeCore.SingBox, VpnSessionPhase.Connected, "ready", true, true, true))
    }
    @Test fun delayedRebindCannotSupersedeANewerProfileOrManualStop() {
        val state = VpnSessionStateMachine()
        val old = state.requestStart("first")
        val next = state.requestReconnect("profile-switch")!!
        assertNull(state.requestReconnect("network-rebind", old.generation))
        assertEquals(next, state.snapshot())
        val stopped = state.requestStop("manual")
        assertNull(state.requestReconnect("network-rebind", stopped.generation))
        assertEquals(stopped, state.snapshot())
    }
}
