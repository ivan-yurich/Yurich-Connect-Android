package com.tecclub.flutter_singbox.bg

import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class VpnCommandFenceTest {
    private val first = "s:00000000-0000-4000-8000-000000000001"
    private val stop = "x:00000000-0000-4000-8000-000000000002"
    private val replacement = "s:00000000-0000-4000-8000-000000000003"

    @Test
    fun dispatchedStartAndItsRecoveryAreRejectedAfterStopOrReplacement() {
        val start = VpnCommandFence.Kind.Start
        assertTrue(VpnCommandFence.accepts(first, first, start))
        assertFalse(VpnCommandFence.accepts(stop, first, start))
        assertFalse(VpnCommandFence.accepts(replacement, first, start))
        assertTrue(VpnCommandFence.accepts(replacement, replacement, start))
    }

    @Test
    fun delayedCloseCannotStopAReplacementRuntime() {
        val close = VpnCommandFence.Kind.Stop
        assertTrue(VpnCommandFence.accepts(stop, stop, close))
        assertFalse(VpnCommandFence.accepts(replacement, stop, close))
        assertFalse(VpnCommandFence.accepts(first, first, close))
    }

    @Test
    fun missingOrMalformedTokenCannotAuthorizeAFencedIntent() {
        val start = VpnCommandFence.Kind.Start
        assertFalse(VpnCommandFence.accepts(null, first, start))
        assertFalse(VpnCommandFence.accepts(first, null, start))
        assertFalse(VpnCommandFence.accepts("s:corrupt", "s:corrupt", start))
    }
}
