package com.tecclub.flutter_singbox.bg

internal object VpnProcessRestartPolicy {
    const val EXIT_TIMEOUT_MS = 6_000L
    private const val POLL_INTERVAL_MS = 100L

    fun previousProcessExists(previousPid: Int, receiverPid: Int, observedOwnPids: Set<Int>?): Boolean {
        check(observedOwnPids != null && receiverPid in observedOwnPids) {
            "Own process observer is unavailable"
        }
        return previousPid in observedOwnPids
    }

    fun awaitPreviousProcessExit(
        previousPid: Int,
        receiverPid: Int,
        elapsedRealtime: () -> Long,
        sleep: (Long) -> Unit,
        processExists: (Int) -> Boolean,
    ): Boolean {
        if (previousPid <= 0 || previousPid == receiverPid) return false
        val startedAt = elapsedRealtime()
        while (processExists(previousPid)) {
            val elapsed = elapsedRealtime() - startedAt
            if (elapsed < 0 || elapsed >= EXIT_TIMEOUT_MS) return false
            sleep(minOf(POLL_INTERVAL_MS, EXIT_TIMEOUT_MS - elapsed))
        }
        return true
    }
}
