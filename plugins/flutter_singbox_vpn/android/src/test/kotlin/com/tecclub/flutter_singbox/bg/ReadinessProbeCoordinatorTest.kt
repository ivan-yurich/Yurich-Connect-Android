package com.tecclub.flutter_singbox.bg

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import java.util.concurrent.atomic.AtomicInteger
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class ReadinessProbeCoordinatorTest {
    @Test
    fun `coordinator never overlaps attempts`() = runBlocking {
        val coordinator = ReadinessProbeCoordinator()
        val active = AtomicInteger(0)
        val maximum = AtomicInteger(0)
        val releaseFirst = CompletableDeferred<Unit>()
        val firstStarted = CompletableDeferred<Unit>()

        val first = async {
            coordinator.run {
                maximum.updateAndGet { maxOf(it, active.incrementAndGet()) }
                firstStarted.complete(Unit)
                releaseFirst.await()
                active.decrementAndGet()
            }
        }
        firstStarted.await()
        val second = async {
            coordinator.run {
                maximum.updateAndGet { maxOf(it, active.incrementAndGet()) }
                active.decrementAndGet()
            }
        }
        delay(25)
        assertEquals(1, maximum.get())
        releaseFirst.complete(Unit)
        first.await()
        second.await()
        assertEquals(1, maximum.get())
    }

    @Test
    fun `quorum returns after two successes without waiting for laggard`() = runBlocking {
        val result = runReadinessQuorum(total = 3, required = 2, deadlineMs = 1_000) { index ->
            if (index == 2) delay(10_000)
            index != 2
        }
        assertEquals(2, result.successes)
        assertEquals(2, result.completed)
        assertFalse(result.deadlineExceeded)
    }

    @Test
    fun `quorum returns when two failures make success impossible`() = runBlocking {
        val result = runReadinessQuorum(total = 3, required = 2, deadlineMs = 1_000) { index ->
            if (index == 2) delay(10_000)
            false
        }
        assertEquals(0, result.successes)
        assertEquals(2, result.completed)
        assertFalse(result.deadlineExceeded)
    }

    @Test
    fun `quorum deadline cancels unfinished probes`() = runBlocking {
        val cleanedUp = AtomicInteger(0)
        val result = runReadinessQuorum(total = 3, required = 2, deadlineMs = 25) {
            try {
                delay(10_000)
                true
            } finally {
                cleanedUp.incrementAndGet()
            }
        }
        assertEquals(0, result.completed)
        assertTrue(result.deadlineExceeded)
        assertEquals(3, cleanedUp.get())
    }
}
