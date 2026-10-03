package com.tecclub.flutter_singbox

import com.tecclub.flutter_singbox.constant.Status
import kotlin.test.Test
import kotlin.test.assertEquals

class VpnStatusResolverTest {
    @Test
    fun shutdownDefersStoppedBroadcastUntilServiceExit() {
        assertEquals(
            Status.Stopping,
            VpnStatusResolver.resolveServiceBroadcastStatus(
                broadcastStatus = Status.Stopped,
                isShuttingDown = true
            )
        )
    }

    @Test
    fun stoppedBroadcastPassesThroughOutsideShutdown() {
        assertEquals(
            Status.Stopped,
            VpnStatusResolver.resolveServiceBroadcastStatus(
                broadcastStatus = Status.Stopped,
                isShuttingDown = false
            )
        )
    }

    @Test
    fun startupIgnoresStaleStoppedBroadcastWhileUserIntentRemains() {
        assertEquals(
            Status.Starting,
            VpnStatusResolver.resolveServiceBroadcastStatus(
                broadcastStatus = Status.Stopped,
                isShuttingDown = false,
                isStarting = true,
                startedByUser = true
            )
        )
    }

    @Test
    fun startupAcceptsStoppedBroadcastAfterIntentWasCleared() {
        assertEquals(
            Status.Stopped,
            VpnStatusResolver.resolveServiceBroadcastStatus(
                broadcastStatus = Status.Stopped,
                isShuttingDown = false,
                isStarting = true,
                startedByUser = false
            )
        )
    }

    @Test
    fun staleServiceWithoutUserStartIsStopped() {
        assertEquals(
            Status.Stopped,
            resolve(startedByUser = false, nativeStatus = Status.Stopped)
        )
    }

    @Test
    fun shutdownWinsWhileServiceIsStillAlive() {
        assertEquals(
            Status.Stopping,
            resolve(
                startedByUser = false,
                isShuttingDown = true,
                nativeStatus = Status.Started
            )
        )
    }

    @Test
    fun nativeStartupIsNotConnected() {
        assertEquals(
            Status.Starting,
            resolve(
                startedByUser = true,
                nativeStatus = Status.Starting
            )
        )
    }

    @Test
    fun xrayWaitsForAnActiveVpnNetwork() {
        assertEquals(
            Status.Starting,
            resolve(
                startedByUser = true,
                nativeStatus = Status.Started,
                requiresActiveVpnNetwork = true,
                hasActiveVpnNetwork = false
            )
        )
    }

    @Test
    fun activeStartedServiceIsStarted() {
        assertEquals(
            Status.Started,
            resolve(startedByUser = true, nativeStatus = Status.Started)
        )
    }

    @Test
    fun runningServicePreservesReadinessGate() {
        assertEquals(
            Status.Starting,
            resolve(startedByUser = true, nativeStatus = Status.Starting)
        )
    }

    @Test
    fun validatedNetworkDoesNotOverrideNativeStartup() {
        assertEquals(
            Status.Starting,
            resolve(
                startedByUser = true,
                nativeStatus = Status.Starting,
                requiresActiveVpnNetwork = true,
                hasActiveVpnNetwork = true
            )
        )
    }

    @Test
    fun missingNativeResponseCannotBeInferredFromUserIntentOrValidatedNetwork() {
        assertEquals(Status.Starting, resolve(
            startedByUser = true, nativeStatus = null,
            requiresActiveVpnNetwork = true, hasActiveVpnNetwork = true,
        ))
    }

    @Test
    fun observedNativeStopIsNotAConnectedService() {
        assertEquals(Status.Stopped, resolve(startedByUser = true, nativeStatus = Status.Stopped))
    }

    private fun resolve(
        startedByUser: Boolean,
        isShuttingDown: Boolean = false,
        nativeStatus: Status?,
        requiresActiveVpnNetwork: Boolean = false,
        hasActiveVpnNetwork: Boolean = true
    ): Status = VpnStatusResolver.resolveRunningServiceStatus(
        startedByUser = startedByUser,
        isShuttingDown = isShuttingDown,
        nativeStatus = nativeStatus,
        requiresActiveVpnNetwork = requiresActiveVpnNetwork,
        hasActiveVpnNetwork = hasActiveVpnNetwork
    )
}
