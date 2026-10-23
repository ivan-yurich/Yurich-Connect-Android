package com.tecclub.flutter_singbox.diagnostics

import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue
import kotlin.test.assertEquals

class DiagnosticPolicyTest {
    @Test fun `seven day deadline is exact`() {
        val start = 1_000_000_000L
        val elapsed = 100L
        assertFalse(DiagnosticPolicy.expired(
            start, elapsed, 1, start + DiagnosticPolicy.DURATION_MS - 1,
            elapsed + DiagnosticPolicy.DURATION_MS - 1, 1,
        ))
        assertTrue(DiagnosticPolicy.expired(
            start, elapsed, 1, start + DiagnosticPolicy.DURATION_MS,
            elapsed + DiagnosticPolicy.DURATION_MS, 1,
        ))
    }
    @Test fun `passive soak deadline is exactly twenty four hours`() {
        val start = 1_000_000_000L
        val duration = DiagnosticPolicy.PASSIVE_SOAK_DURATION_MS
        val elapsed = 100L
        assertTrue(DiagnosticPolicy.supportedDuration(duration))
        assertFalse(DiagnosticPolicy.expired(
            start, elapsed, 1, start + duration - 1, elapsed + duration - 1, 1, duration,
        ))
        assertTrue(DiagnosticPolicy.expired(
            start, elapsed, 1, start + duration, elapsed + duration, 1, duration,
        ))
    }
    @Test fun `unsupported persisted duration safely falls back to seven days`() {
        assertEquals(DiagnosticPolicy.DURATION_MS, DiagnosticPolicy.normalizedDuration(1234L))
    }
    @Test fun `standard and passive controls cannot mutate each other`() {
        assertFalse(DiagnosticPolicy.sameMode(
            DiagnosticPolicy.MODE_PASSIVE_24H, DiagnosticPolicy.MODE_STANDARD,
        ))
        assertFalse(DiagnosticPolicy.sameMode(
            DiagnosticPolicy.MODE_STANDARD, DiagnosticPolicy.MODE_PASSIVE_24H,
        ))
        assertTrue(DiagnosticPolicy.sameMode(
            DiagnosticPolicy.MODE_PASSIVE_24H, DiagnosticPolicy.MODE_PASSIVE_24H,
        ))
    }
    @Test fun `clock rollback cannot prolong same boot run`() {
        assertTrue(DiagnosticPolicy.expired(1000, 100, 1, 500, 100 + DiagnosticPolicy.DURATION_MS, 1))
    }
    @Test fun `clock jump cannot shorten same boot run`() {
        assertFalse(DiagnosticPolicy.expired(
            1000, 100, 1, 1000 + DiagnosticPolicy.DURATION_MS * 2, 101, 1,
        ))
    }
    @Test fun `reboot does not confuse elapsed realtime with previous boot`() {
        assertFalse(DiagnosticPolicy.expired(1000, 100, 1, 2000, DiagnosticPolicy.DURATION_MS, 2))
        assertTrue(DiagnosticPolicy.expired(1000, 100, 1, 1000 + DiagnosticPolicy.DURATION_MS, 0, 2))
    }
    @Test fun `same boot accepts event after start despite wall clock rollback`() {
        assertTrue(DiagnosticPolicy.belongsToRun(1000, 100, 1, 500, 101, 1))
    }
    @Test fun `same boot rejects queued event captured before start`() {
        assertFalse(DiagnosticPolicy.belongsToRun(1000, 100, 1, 2000, 99, 1))
    }
    @Test fun `changed boot falls back to wall clock`() {
        assertFalse(DiagnosticPolicy.belongsToRun(1000, 100, 1, 999, 9999, 2))
        assertTrue(DiagnosticPolicy.belongsToRun(1000, 100, 1, 1000, 0, 2))
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
        assertTrue(DiagnosticPolicy.validate("sample", mapOf(
            "cpuMs" to 12_345, "threads" to 42, "fds" to 64, "thermal" to 1,
        ), mapOf("role" to "vpn")))
        assertTrue(DiagnosticPolicy.validate("quorum", mapOf("probeId" to 7),
            mapOf("transport" to "cellular")))
        assertTrue(DiagnosticPolicy.validate("counter", mapOf(
            "uiGeneration" to 3, "nativeSessionBytes" to 1024, "displayBytes" to 1024,
        ), mapOf("role" to "main")))
        assertFalse(DiagnosticPolicy.validate("counter", emptyMap(),
            mapOf("transport" to "private-network")))
    }
    @Test fun `only own process roles are disclosed`() {
        assertEquals("vpn", DiagnosticPolicy.role("example:vpn", "example"))
        assertEquals("main", DiagnosticPolicy.role("example", "example"))
        assertEquals("other", DiagnosticPolicy.role("private-name", "example"))
    }

    @Test fun `restart budget and process recycle are distinct safe observations`() {
        assertTrue(DiagnosticPolicy.validate("recovery_deferred",
            mapOf("attempt" to 5, "cooldownMs" to 900_000), emptyMap()))
        assertTrue(DiagnosticPolicy.validate("recovery_deferred",
            mapOf("attempt" to 1), mapOf("cause" to "network_reset")))
        assertTrue(DiagnosticPolicy.validate("recycle", emptyMap(), mapOf("cause" to "core_switch")))
        assertTrue(DiagnosticPolicy.validate("resource_pressure",
            mapOf("fds" to 1024, "attempt" to 2), mapOf("cause" to "resource_pressure")))
    }
}
