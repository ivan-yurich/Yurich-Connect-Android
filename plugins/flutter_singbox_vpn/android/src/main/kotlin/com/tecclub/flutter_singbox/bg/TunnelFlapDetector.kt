package com.tecclub.flutter_singbox.bg

import java.util.ArrayDeque

internal class TunnelFlapDetector(
    private val threshold: Int,
    private val windowMs: Long,
) {
    private val degradedProbeTimes = ArrayDeque<Long>()

    init {
        require(threshold > 0) { "threshold must be positive" }
        require(windowMs >= 0L) { "windowMs must not be negative" }
    }

    @Synchronized
    fun record(
        nowMs: Long,
        successfulEndpoints: Int,
        totalEndpoints: Int,
    ): Boolean {
        prune(nowMs)
        if (totalEndpoints <= 0 || successfulEndpoints >= totalEndpoints) {
            return false
        }

        degradedProbeTimes.addLast(nowMs)
        if (degradedProbeTimes.size < threshold) {
            return false
        }

        degradedProbeTimes.clear()
        return true
    }

    @Synchronized
    fun reset() {
        degradedProbeTimes.clear()
    }

    private fun prune(nowMs: Long) {
        val cutoff = nowMs - windowMs
        while (degradedProbeTimes.isNotEmpty() && degradedProbeTimes.first < cutoff) {
            degradedProbeTimes.removeFirst()
        }
    }
}
