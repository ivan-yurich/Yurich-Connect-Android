package com.tecclub.flutter_singbox

import com.tecclub.flutter_singbox.constant.Status

internal data class SessionTrafficTotals(val uplink: Long, val downlink: Long) {
    val total: Long get() = saturatedAdd(uplink, downlink)
}

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
    fun observe(rawUplink: Long, rawDownlink: Long): SessionTrafficTotals {
        val nextUplink = if (rawUplink >= 0L) rawUplink else lastUplink
        val nextDownlink = if (rawDownlink >= 0L) rawDownlink else lastDownlink
        // A recycled runtime can reset provider counters while the UI session remains active.
        uplink = saturatedAdd(uplink, if (nextUplink >= lastUplink) nextUplink - lastUplink else nextUplink)
        downlink = saturatedAdd(downlink, if (nextDownlink >= lastDownlink) nextDownlink - lastDownlink else nextDownlink)
        lastUplink = nextUplink
        lastDownlink = nextDownlink
        return SessionTrafficTotals(uplink, downlink)
    }

    companion object {
        fun shouldCollect(status: Status, isXrayRuntime: Boolean): Boolean =
            status == Status.Started && !isXrayRuntime
    }
}
