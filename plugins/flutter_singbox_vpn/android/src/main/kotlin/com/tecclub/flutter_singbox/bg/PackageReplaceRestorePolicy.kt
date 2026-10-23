package com.tecclub.flutter_singbox.bg

internal enum class RestoreAttemptResult {
    STARTED,
    NOT_READY,
    START_FAILED,
}

internal object PackageReplaceRestorePolicy {
    const val PACKAGE_REPLACED_ACTION = "android.intent.action.MY_PACKAGE_REPLACED"
    val absoluteAttemptOffsetsMs = listOf(0L, 250L, 1_000L, 3_000L)

    fun restoreRequested(
        autoStart: Boolean,
        startedByUser: Boolean,
        manualDisconnectRequested: Boolean? = null,
    ): Boolean = manualDisconnectRequested != true && (autoStart || startedByUser)

    fun attemptOffsetsMs(action: String): List<Long> =
        if (action == PACKAGE_REPLACED_ACTION) absoluteAttemptOffsetsMs else listOf(0L)
}

internal class PackageReplaceRestoreRunner(
    private val sleeper: (Long) -> Unit = Thread::sleep,
    private val monotonicMs: () -> Long = { System.nanoTime() / 1_000_000L },
) {
    fun execute(
        action: String,
        attempt: (attemptNumber: Int) -> RestoreAttemptResult,
    ) {
        val startedAt = monotonicMs()
        PackageReplaceRestorePolicy.attemptOffsetsMs(action).forEachIndexed { index, offset ->
            val delay = (startedAt + offset - monotonicMs()).coerceAtLeast(0L)
            if (delay > 0L) {
                try {
                    sleeper(delay)
                } catch (_: InterruptedException) {
                    Thread.currentThread().interrupt()
                    return
                }
            }
            if (attempt(index + 1) == RestoreAttemptResult.STARTED) {
                return
            }
        }
    }
}
