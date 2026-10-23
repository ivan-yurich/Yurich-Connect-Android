package com.tecclub.flutter_singbox.bg

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class PackageReplaceRestorePolicyTest {
    @Test fun `transient not ready is retried and stops after success`() {
        val attempts = mutableListOf<Int>()
        val sleeps = mutableListOf<Long>()
        var now = 100L
        PackageReplaceRestoreRunner(
            sleeper = { sleeps += it; now += it },
            monotonicMs = { now },
        ).execute(PACKAGE_REPLACED) { attempt ->
            attempts += attempt
            if (attempt == 2) RestoreAttemptResult.STARTED else RestoreAttemptResult.NOT_READY
        }
        assertEquals(listOf(1, 2), attempts)
        assertEquals(listOf(250L), sleeps)
    }

    @Test fun `four bounded attempts use exact absolute offsets`() {
        val attempts = mutableListOf<Int>()
        val sleeps = mutableListOf<Long>()
        var now = 100L
        PackageReplaceRestoreRunner(
            sleeper = { sleeps += it; now += it },
            monotonicMs = { now },
        ).execute(PACKAGE_REPLACED) { attempt ->
            attempts += attempt
            RestoreAttemptResult.NOT_READY
        }
        assertEquals(listOf(1, 2, 3, 4), attempts)
        assertEquals(listOf(250L, 750L, 2_000L), sleeps)
        assertEquals(
            listOf(0L, 250L, 1_000L, 3_000L),
            PackageReplaceRestorePolicy.absoluteAttemptOffsetsMs,
        )
    }

    @Test fun `attempt work is subtracted from the next absolute deadline`() {
        val sleeps = mutableListOf<Long>()
        val attempts = mutableListOf<Int>()
        var now = 10_000L
        PackageReplaceRestoreRunner(
            sleeper = { sleeps += it; now += it },
            monotonicMs = { now },
        ).execute(PACKAGE_REPLACED) { attempt ->
            attempts += attempt
            now += when (attempt) {
                1 -> 100L
                2 -> 800L
                else -> 0L
            }
            if (attempt == 3) RestoreAttemptResult.STARTED else RestoreAttemptResult.NOT_READY
        }
        assertEquals(listOf(1, 2, 3), attempts)
        assertEquals(listOf(150L), sleeps)
    }

    @Test fun `start failure can recover on a later attempt`() {
        var attempts = 0
        var now = 100L
        PackageReplaceRestoreRunner(
            sleeper = { now += it },
            monotonicMs = { now },
        ).execute(PACKAGE_REPLACED) {
            attempts++
            if (attempts == 3) RestoreAttemptResult.STARTED else RestoreAttemptResult.START_FAILED
        }
        assertEquals(3, attempts)
    }

    @Test fun `first success neither sleeps nor duplicates start`() {
        var attempts = 0
        val sleeps = mutableListOf<Long>()
        PackageReplaceRestoreRunner(
            sleeper = { sleeps += it },
            monotonicMs = { 100L },
        ).execute(PACKAGE_REPLACED) {
            attempts++
            RestoreAttemptResult.STARTED
        }
        assertEquals(1, attempts)
        assertTrue(sleeps.isEmpty())
    }

    @Test fun `other restore actions keep a single immediate attempt`() {
        var attempts = 0
        val sleeps = mutableListOf<Long>()
        PackageReplaceRestoreRunner(
            sleeper = { sleeps += it },
            monotonicMs = { 100L },
        ).execute("android.intent.action.BOOT_COMPLETED") {
            attempts++
            RestoreAttemptResult.NOT_READY
        }
        assertEquals(1, attempts)
        assertTrue(sleeps.isEmpty())
    }

    @Test fun `manual disconnect never requests restore`() {
        assertFalse(PackageReplaceRestorePolicy.restoreRequested(
            autoStart = false,
            startedByUser = false,
        ))
        assertFalse(PackageReplaceRestorePolicy.restoreRequested(
            autoStart = true,
            startedByUser = true,
            manualDisconnectRequested = true,
        ))
        assertTrue(PackageReplaceRestorePolicy.restoreRequested(
            autoStart = true,
            startedByUser = false,
        ))
        assertTrue(PackageReplaceRestorePolicy.restoreRequested(
            autoStart = false,
            startedByUser = true,
        ))
    }

    @Test fun `interruption stops retries without another attempt`() {
        var attempts = 0
        try {
            PackageReplaceRestoreRunner(
                sleeper = { throw InterruptedException("test") },
                monotonicMs = { 100L },
            )
                .execute(PACKAGE_REPLACED) {
                    attempts++
                    RestoreAttemptResult.NOT_READY
                }
            assertEquals(1, attempts)
            assertTrue(Thread.currentThread().isInterrupted)
        } finally {
            Thread.interrupted()
        }
    }

    private companion object {
        const val PACKAGE_REPLACED = PackageReplaceRestorePolicy.PACKAGE_REPLACED_ACTION
    }
}
