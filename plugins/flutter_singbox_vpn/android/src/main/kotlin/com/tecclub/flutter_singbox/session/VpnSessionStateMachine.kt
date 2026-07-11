package com.tecclub.flutter_singbox.session

internal enum class VpnSessionPhase {
    Stopped,
    Starting,
    Connected,
    Reconnecting,
    Stopping,
    Failed,
}

internal data class VpnSessionSnapshot(
    val generation: Long,
    val phase: VpnSessionPhase,
    val desiredRunning: Boolean,
    val reason: String,
)

internal class VpnSessionStateMachine {
    private val lock = Any()
    private var generation = 0L
    private var phase = VpnSessionPhase.Stopped
    private var desiredRunning = false
    private var reason = "initial"

    fun snapshot(): VpnSessionSnapshot = synchronized(lock) {
        snapshotLocked()
    }

    fun requestStart(reason: String): VpnSessionSnapshot = synchronized(lock) {
        generation += 1
        desiredRunning = true
        phase = VpnSessionPhase.Starting
        this.reason = reason
        snapshotLocked()
    }

    fun requestReconnect(reason: String): VpnSessionSnapshot? = synchronized(lock) {
        if (!desiredRunning || phase == VpnSessionPhase.Stopping) {
            return@synchronized null
        }
        generation += 1
        phase = VpnSessionPhase.Reconnecting
        this.reason = reason
        snapshotLocked()
    }

    fun requestStop(reason: String): VpnSessionSnapshot = synchronized(lock) {
        generation += 1
        desiredRunning = false
        phase = VpnSessionPhase.Stopping
        this.reason = reason
        snapshotLocked()
    }

    fun markConnected(generation: Long, reason: String): Boolean = synchronized(lock) {
        if (!isCurrentLocked(generation, requireDesiredRunning = true)) {
            return@synchronized false
        }
        phase = VpnSessionPhase.Connected
        this.reason = reason
        true
    }

    fun markStopped(
        generation: Long,
        reason: String,
        clearDesiredRunning: Boolean,
    ): Boolean = synchronized(lock) {
        if (generation != this.generation) {
            return@synchronized false
        }
        if (clearDesiredRunning) {
            desiredRunning = false
        }
        phase = VpnSessionPhase.Stopped
        this.reason = reason
        true
    }

    fun markFailed(
        generation: Long,
        reason: String,
        keepDesiredRunning: Boolean,
    ): Boolean = synchronized(lock) {
        if (generation != this.generation) {
            return@synchronized false
        }
        desiredRunning = keepDesiredRunning
        phase = VpnSessionPhase.Failed
        this.reason = reason
        true
    }

    fun forceStopped(reason: String, clearDesiredRunning: Boolean): VpnSessionSnapshot =
        synchronized(lock) {
            generation += 1
            if (clearDesiredRunning) {
                desiredRunning = false
            }
            phase = VpnSessionPhase.Stopped
            this.reason = reason
            snapshotLocked()
        }

    fun isCurrent(generation: Long, requireDesiredRunning: Boolean = true): Boolean =
        synchronized(lock) {
            isCurrentLocked(generation, requireDesiredRunning)
        }

    private fun isCurrentLocked(generation: Long, requireDesiredRunning: Boolean): Boolean {
        return generation == this.generation && (!requireDesiredRunning || desiredRunning)
    }

    private fun snapshotLocked() = VpnSessionSnapshot(
        generation = generation,
        phase = phase,
        desiredRunning = desiredRunning,
        reason = reason,
    )
}
