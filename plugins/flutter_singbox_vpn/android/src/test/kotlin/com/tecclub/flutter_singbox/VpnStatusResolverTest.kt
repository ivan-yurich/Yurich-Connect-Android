package com.tecclub.flutter_singbox

import com.tecclub.flutter_singbox.constant.Status
import kotlin.test.Test
import kotlin.test.assertEquals

class VpnStatusResolverTest {
    @Test
    fun staleServiceWithoutUserStartIsStopped() {
        assertEquals(
            Status.Stopped,
            resolve(startedByUser = false, currentStatus = Status.Stopped)
        )
    }

    @Test
    fun shutdownWinsWhileServiceIsStillAlive() {
        assertEquals(
            Status.Stopping,
            resolve(
                startedByUser = false,
                isShuttingDown = true,
                currentStatus = Status.Started
            )
        )
    }

    @Test
    fun startupWinsOverAStaleStoppedState() {
        assertEquals(
            Status.Starting,
            resolve(
                startedByUser = true,
                isStarting = true,
                currentStatus = Status.Stopped
            )
        )
    }

    @Test
    fun xrayWaitsForAnActiveVpnNetwork() {
        assertEquals(
            Status.Starting,
            resolve(
                startedByUser = true,
                currentStatus = Status.Started,
                requiresActiveVpnNetwork = true,
                hasActiveVpnNetwork = false
            )
        )
    }

    @Test
    fun activeStartedServiceIsStarted() {
        assertEquals(
            Status.Started,
            resolve(startedByUser = true, currentStatus = Status.Started)
        )
    }

    private fun resolve(
        startedByUser: Boolean,
        isStarting: Boolean = false,
        isShuttingDown: Boolean = false,
        currentStatus: Status,
        requiresActiveVpnNetwork: Boolean = false,
        hasActiveVpnNetwork: Boolean = true
    ): Status = VpnStatusResolver.resolveRunningServiceStatus(
        startedByUser = startedByUser,
        isStarting = isStarting,
        isShuttingDown = isShuttingDown,
        currentStatus = currentStatus,
        requiresActiveVpnNetwork = requiresActiveVpnNetwork,
        hasActiveVpnNetwork = hasActiveVpnNetwork
    )
}
