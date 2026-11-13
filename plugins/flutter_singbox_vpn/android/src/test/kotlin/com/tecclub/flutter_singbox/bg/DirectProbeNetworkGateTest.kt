package com.tecclub.flutter_singbox.bg

import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class DirectProbeNetworkGateTest {
    private val off = mapOf(
        "supported" to true, "known" to true, "requested" to false,
        "alwaysOn" to false, "lockdown" to false, "strictRuntime" to false, "vpnActive" to false,
    )

    @Test fun allowsOnlyKnownUnprotectedPhysicalNetwork() {
        assertTrue(DirectProbeNetworkGate.allows(off, physicalReady = true, vpnPresent = false))
        assertFalse(DirectProbeNetworkGate.allows(off, physicalReady = false, vpnPresent = false))
        assertFalse(DirectProbeNetworkGate.allows(off, physicalReady = true, vpnPresent = true))
    }

    @Test fun unknownAndAllProtectionSignalsFailClosed() {
        for (flag in listOf("requested", "alwaysOn", "lockdown", "strictRuntime", "vpnActive")) {
            assertFalse(DirectProbeNetworkGate.allows(off + (flag to true), true, false))
            assertFalse(DirectProbeNetworkGate.allows(off - flag, true, false))
        }
        assertFalse(DirectProbeNetworkGate.allows(off + ("known" to false), true, false))
        assertFalse(DirectProbeNetworkGate.allows(off + ("supported" to false), true, false))
    }

    @Test fun dnsAcceptsOnlyQualifiedNonLocalNames() {
        assertTrue(DirectProbeNetworkGate.isProbeDomain("vpn.example.org"))
        for (value in listOf("single", "test.LoCaL", "-x.example.org", "https://vpn.example.org", "vpn.example.org:443", "127.0.0.1")) {
            assertFalse(DirectProbeNetworkGate.isProbeDomain(value))
        }
    }
}
