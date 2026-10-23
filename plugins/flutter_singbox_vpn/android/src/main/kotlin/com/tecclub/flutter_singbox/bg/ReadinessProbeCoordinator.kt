package com.tecclub.flutter_singbox.bg

import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withTimeoutOrNull
import java.util.concurrent.atomic.AtomicLong

internal class ReadinessProbeCoordinator {
    private val mutex = Mutex()
    private val sequence = AtomicLong(0L)

    suspend fun <T> run(block: suspend (probeId: Long) -> T): T =
        mutex.withLock { block(sequence.incrementAndGet()) }
}

internal data class ReadinessQuorumResult(
    val successes: Int,
    val completed: Int,
    val total: Int,
    val deadlineExceeded: Boolean,
)

/**
 * Runs one bounded 2-of-N attempt. As soon as the result is known, all lagging
 * sockets are cancelled and joined so they cannot outlive the diagnostic event.
 */
internal suspend fun runReadinessQuorum(
    total: Int,
    required: Int,
    deadlineMs: Long,
    probe: suspend (index: Int) -> Boolean,
): ReadinessQuorumResult = coroutineScope {
    require(total > 0)
    require(required in 1..total)
    require(deadlineMs > 0L)

    val results = Channel<Boolean>(capacity = total)
    val jobs = (0 until total).map { index ->
        launch {
            results.send(probe(index))
        }
    }
    var successes = 0
    var completed = 0
    val completedWithinDeadline = try {
        withTimeoutOrNull(deadlineMs) {
            while (
                completed < total &&
                successes < required &&
                successes + (total - completed) >= required
            ) {
                if (results.receive()) successes += 1
                completed += 1
            }
            true
        } == true
    } finally {
        jobs.forEach { job ->
            if (job.isActive) job.cancelAndJoin() else job.join()
        }
        results.close()
    }
    ReadinessQuorumResult(
        successes = successes,
        completed = completed,
        total = total,
        deadlineExceeded = !completedWithinDeadline,
    )
}
