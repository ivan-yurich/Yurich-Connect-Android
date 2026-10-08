package com.tecclub.flutter_singbox.diagnostics

import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue
import kotlin.test.assertEquals

class DiagnosticPolicyTest {
    @Test fun `seven day deadline is exact`() {
        val start = 1_000_000_000L
        assertFalse(DiagnosticPolicy.expired(start, 100, 1, start + DiagnosticPolicy.DURATION_MS - 1, 101, 1))
        assertTrue(DiagnosticPolicy.expired(start, 100, 1, start + DiagnosticPolicy.DURATION_MS, 101, 1))
    }
    @Test fun `clock rollback cannot prolong same boot run`() {
        assertTrue(DiagnosticPolicy.expired(1000, 100, 1, 500, 100 + DiagnosticPolicy.DURATION_MS, 1))
    }
    @Test fun `reboot does not confuse elapsed realtime with previous boot`() {
        assertFalse(DiagnosticPolicy.expired(1000, 100, 1, 2000, DiagnosticPolicy.DURATION_MS, 2))
        assertTrue(DiagnosticPolicy.expired(1000, 100, 1, 1000 + DiagnosticPolicy.DURATION_MS, 0, 2))
    }
    @Test fun `free form secrets and unknown labels are rejected`() {
        assertFalse(DiagnosticPolicy.validate("log", emptyMap(), emptyMap()))
        assertFalse(DiagnosticPolicy.validate("session", emptyMap(), mapOf("profile" to "private")))
        assertFalse(DiagnosticPolicy.validate("network", emptyMap(), mapOf("source" to "https://private")))
        assertFalse(DiagnosticPolicy.validate("sample", mapOf("uuid" to 1), emptyMap()))
        assertFalse(DiagnosticPolicy.validate("sample", mapOf("pssKb" to -2), emptyMap()))
    }
    @Test fun `typed observation is valid`() {
        assertTrue(DiagnosticPolicy.validate("quorum", mapOf("success" to 2, "total" to 3), mapOf("core" to "xray")))
        assertTrue(DiagnosticPolicy.validate("session", mapOf("tun" to 1), mapOf("phase" to "Connected")))
    }
    @Test fun `only own process roles are disclosed`() {
        assertEquals("vpn", DiagnosticPolicy.role("example:vpn", "example"))
        assertEquals("main", DiagnosticPolicy.role("example", "example"))
        assertEquals("other", DiagnosticPolicy.role("private-name", "example"))
    }

    @Test fun `restart budget and process recycle are distinct safe observations`() {
        assertTrue(DiagnosticPolicy.validate("recovery_deferred",
            mapOf("attempt" to 5, "cooldownMs" to 900_000), emptyMap()))
        assertTrue(DiagnosticPolicy.validate("recycle", emptyMap(), mapOf("cause" to "core_switch")))
    }
}
