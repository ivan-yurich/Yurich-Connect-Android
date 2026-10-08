package com.tecclub.flutter_singbox.bg

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class VpnProcessRestartPolicyTest {
    @Test
    fun `own process observer distinguishes previous pid from receiver`() {
        assertTrue(VpnProcessRestartPolicy.previousProcessExists(41, 42, setOf(41, 42)))
        assertFalse(VpnProcessRestartPolicy.previousProcessExists(41, 42, setOf(42)))
    }

    @Test
    fun `missing process list is not evidence of exit`() {
        assertFailsWith<IllegalStateException> {
            VpnProcessRestartPolicy.previousProcessExists(41, 42, null)
        }
    }

    @Test
    fun `observer must include its own running process`() {
        assertFailsWith<IllegalStateException> {
            VpnProcessRestartPolicy.previousProcessExists(41, 42, setOf(41))
        }
    }

    @Test
    fun `invalid or receiver pid never starts a replacement`() {
        for (pid in listOf(-1, 0, 42)) {
            assertFalse(VpnProcessRestartPolicy.awaitPreviousProcessExit(
                pid, 42, { error("must not check time") },
                { error("must not sleep") }, { error("must not inspect process") },
            ))
        }
    }

    @Test
    fun `already exited process needs no artificial delay`() {
        assertTrue(VpnProcessRestartPolicy.awaitPreviousProcessExit(
            41, 42, { 1_000L }, { error("must not sleep") }, { false },
        ))
    }

    @Test
    fun `normal exit starts replacement after actual exit`() {
        var time = 1_000L
        assertTrue(VpnProcessRestartPolicy.awaitPreviousProcessExit(
            41, 42, { time }, { time += it }, { time < 1_600L },
        ))
        assertEquals(1_600L, time)
    }

    @Test
    fun `slower exit does not reuse old process after old fixed delay`() {
        var time = 1_000L
        assertTrue(VpnProcessRestartPolicy.awaitPreviousProcessExit(
            41, 42, { time }, { time += it }, { time < 3_500L },
        ))
        assertEquals(3_500L, time)
    }

    @Test
    fun `hung old process cannot trigger a same-process restart`() {
        var time = 1_000L
        assertFalse(VpnProcessRestartPolicy.awaitPreviousProcessExit(
            41, 42, { time }, { time += it }, { true },
        ))
        assertEquals(1_000L + VpnProcessRestartPolicy.EXIT_TIMEOUT_MS, time)
    }

    @Test
    fun `clock regression stops waiting safely`() {
        var time = 1_000L
        assertFalse(VpnProcessRestartPolicy.awaitPreviousProcessExit(
            41, 42, { time }, { time = 900L }, { true },
        ))
    }

    @Test
    fun `inspection failure is not interpreted as process exit`() {
        assertFailsWith<SecurityException> {
            VpnProcessRestartPolicy.awaitPreviousProcessExit(
                41, 42, { 1_000L }, {}, { throw SecurityException() },
            )
        }
    }

    @Test
    fun `interrupted waiter does not start replacement`() {
        assertFailsWith<InterruptedException> {
            VpnProcessRestartPolicy.awaitPreviousProcessExit(
                41, 42, { 1_000L }, { throw InterruptedException() }, { true },
            )
        }
    }
}
