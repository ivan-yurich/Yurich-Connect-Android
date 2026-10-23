package com.tecclub.flutter_singbox.bg

internal data class ResourcePressureState(
    val consecutiveCriticalSamples: Int = 0,
)

internal object ResourcePressurePolicy {
    const val WARNING_FDS = 512
    const val CRITICAL_FDS = 1_024
    const val EMERGENCY_FDS = 8_192
    const val REQUIRED_CRITICAL_SAMPLES = 2

    fun observed(previous: ResourcePressureState, fileDescriptors: Int): ResourcePressureState =
        if (fileDescriptors >= CRITICAL_FDS) {
            previous.copy(
                consecutiveCriticalSamples =
                    (previous.consecutiveCriticalSamples + 1).coerceAtMost(REQUIRED_CRITICAL_SAMPLES),
            )
        } else {
            ResourcePressureState()
        }

    fun shouldReport(fileDescriptors: Int): Boolean = fileDescriptors >= WARNING_FDS

    fun shouldRestart(state: ResourcePressureState, fileDescriptors: Int): Boolean =
        fileDescriptors >= EMERGENCY_FDS ||
            state.consecutiveCriticalSamples >= REQUIRED_CRITICAL_SAMPLES
}
