package com.tecclub.flutter_singbox

import com.tecclub.flutter_singbox.constant.Status

internal data class SessionTrafficTotals(val uplink: Long, val downlink: Long) {
    val total: Long get() = saturatedAdd(uplink, downlink)
}

internal data class SessionTrafficSnapshot(
    val lastUplink: Long,
    val lastDownlink: Long,
    val uplink: Long,
    val downlink: Long,
) {
    val isValid: Boolean
        get() = lastUplink >= 0L &&
            lastDownlink >= 0L &&
            uplink >= 0L &&
            downlink >= 0L
}

internal enum class SessionTrafficSource {
    SING_BOX,
    UID,
}

internal data class SessionTrafficStateSnapshot(
    val counters: SessionTrafficSnapshot,
    val source: SessionTrafficSource?,
)

private fun saturatedAdd(left: Long, right: Long): Long =
    if (left > Long.MAX_VALUE - right) Long.MAX_VALUE else left + right

internal class SessionTrafficAccumulator {
    private var lastUplink = 0L
    private var lastDownlink = 0L
    private var uplink = 0L
    private var downlink = 0L

    @Synchronized
    fun reset() {
        lastUplink = 0L
        lastDownlink = 0L
        uplink = 0L
        downlink = 0L
    }

    @Synchronized
    fun restore(snapshot: SessionTrafficSnapshot): SessionTrafficTotals {
        if (!snapshot.isValid) {
            reset()
            return SessionTrafficTotals(0L, 0L)
        }
        lastUplink = snapshot.lastUplink
        lastDownlink = snapshot.lastDownlink
        uplink = snapshot.uplink
        downlink = snapshot.downlink
        return SessionTrafficTotals(uplink, downlink)
    }

    @Synchronized
    fun snapshot(): SessionTrafficSnapshot = SessionTrafficSnapshot(
        lastUplink = lastUplink,
        lastDownlink = lastDownlink,
        uplink = uplink,
        downlink = downlink,
    )

    @Synchronized
    fun totals(): SessionTrafficTotals = SessionTrafficTotals(uplink, downlink)

    @Synchronized
    fun observe(rawUplink: Long, rawDownlink: Long): SessionTrafficTotals {
        val nextUplink = stableRawSample(rawUplink, lastUplink)
        val nextDownlink = stableRawSample(rawDownlink, lastDownlink)
        // A recycled runtime can reset provider counters while the UI session remains active.
        uplink = saturatedAdd(uplink, if (nextUplink >= lastUplink) nextUplink - lastUplink else nextUplink)
        downlink = saturatedAdd(downlink, if (nextDownlink >= lastDownlink) nextDownlink - lastDownlink else nextDownlink)
        lastUplink = nextUplink
        lastDownlink = nextDownlink
        return SessionTrafficTotals(uplink, downlink)
    }

    private fun stableRawSample(raw: Long, previous: Long): Long = when {
        raw < 0L -> previous
        // Some providers briefly publish zero while a command client is
        // reattaching. Do not treat that one sample as a reset: a real reset is
        // still recognized by the first subsequent positive value below the
        // previous raw counter.
        raw == 0L && previous > 0L -> previous
        else -> raw
    }

    companion object {
        fun shouldCollect(status: Status, isXrayRuntime: Boolean): Boolean =
            status == Status.Started && !isXrayRuntime
    }
}

/**
 * Rebases raw counters when a new explicit session or counter provider starts,
 * while preserving accumulated totals across runtime and UI recreation.
 */
internal class SessionTrafficTracker {
    private val accumulator = SessionTrafficAccumulator()
    private var source: SessionTrafficSource? = null

    @Synchronized
    fun reset() {
        source = null
        accumulator.reset()
    }

    @Synchronized
    fun restore(snapshot: SessionTrafficStateSnapshot): SessionTrafficTotals {
        if (!snapshot.counters.isValid || snapshot.source == null) {
            reset()
            return SessionTrafficTotals(0L, 0L)
        }
        source = snapshot.source
        return accumulator.restore(snapshot.counters)
    }

    @Synchronized
    fun snapshot(): SessionTrafficStateSnapshot = SessionTrafficStateSnapshot(
        counters = accumulator.snapshot(),
        source = source,
    )

    @Synchronized
    fun totals(): SessionTrafficTotals = accumulator.totals()

    @Synchronized
    fun currentSource(): SessionTrafficSource? = source

    @Synchronized
    fun observe(
        nextSource: SessionTrafficSource,
        rawUplink: Long,
        rawDownlink: Long,
    ): SessionTrafficTotals {
        if (rawUplink < 0L || rawDownlink < 0L) {
            return accumulator.totals()
        }
        if (source != nextSource) {
            val totals = accumulator.totals()
            accumulator.restore(
                SessionTrafficSnapshot(
                    lastUplink = rawUplink,
                    lastDownlink = rawDownlink,
                    uplink = totals.uplink,
                    downlink = totals.downlink,
                ),
            )
            source = nextSource
            return totals
        }
        return accumulator.observe(rawUplink, rawDownlink)
    }
}
