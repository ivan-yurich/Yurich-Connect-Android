package com.tecclub.flutter_singbox

import com.tecclub.flutter_singbox.constant.Status
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class VpnStatusResolverTest {
    @Test
    fun duplicateStopJoinsOnlyCurrentCleanup() {
        assertTrue(VpnStopLifecyclePolicy.canJoinStop(true, 9, 9, true))
        assertFalse(VpnStopLifecyclePolicy.canJoinStop(true, 8, 9, true))
        assertFalse(VpnStopLifecyclePolicy.canJoinStop(true, 9, 9, false))
        assertFalse(VpnStopLifecyclePolicy.canJoinStop(false, 9, 9, true))
        assertFalse(VpnStopLifecyclePolicy.canJoinStop(true, 0, 0, true))
    }
    @Test
    fun systemAlwaysOnOwnsIntentDespiteStaleMainProcessPreferences() {
        assertEquals(Status.Started, VpnStatusResolver.resolveRunningServiceStatus(
            startedByUser = false, isShuttingDown = false, nativeStatus = Status.Started,
            requiresActiveVpnNetwork = false, hasActiveVpnNetwork = true, systemAlwaysOn = true,
        ))
    }

    @Test
    fun systemAlwaysOnCannotInventReadinessOrOverrideAnExplicitStop() {
        for (native in listOf(null, Status.Starting, Status.Stopped)) {
            assertEquals(native ?: Status.Starting, VpnStatusResolver.resolveRunningServiceStatus(
                startedByUser = false, isShuttingDown = false, nativeStatus = native,
                requiresActiveVpnNetwork = true, hasActiveVpnNetwork = true, systemAlwaysOn = true,
            ))
        }
        assertEquals(Status.Stopping, VpnStatusResolver.resolveRunningServiceStatus(
            startedByUser = false, isShuttingDown = true, nativeStatus = Status.Started,
            requiresActiveVpnNetwork = true, hasActiveVpnNetwork = true, systemAlwaysOn = true,
        ))
    }
    @Test
    fun stopLifecycleUsesARealisticNativeCleanupWindow() {
        assertTrue(VpnStopLifecyclePolicy.GRACEFUL_TIMEOUT_MS >= 25_000L)
    }

    @Test
    fun runningServiceCannotFinalizeStopOrAcceptAReplacementStart() {
        assertFalse(VpnStopLifecyclePolicy.canFinalize(serviceRunning = true))
        assertFalse(VpnStopLifecyclePolicy.canStart(isShuttingDown = true))
    }

    @Test
    fun confirmedServiceAbsenceAllowsStopCompletionAndNextStart() {
        assertTrue(VpnStopLifecyclePolicy.canFinalize(serviceRunning = false))
        assertTrue(VpnStopLifecyclePolicy.canStart(isShuttingDown = false))
    }

    @Test
    fun delayedStartOrReloadCannotDispatchAfterStopOrReplacement() {
        assertTrue(VpnStopLifecyclePolicy.canDispatchStart(7, 7, isShuttingDown = false))
        assertFalse(VpnStopLifecyclePolicy.canDispatchStart(7, 7, isShuttingDown = true))
        assertFalse(VpnStopLifecyclePolicy.canDispatchStart(7, 8, isShuttingDown = true))
        assertFalse(VpnStopLifecyclePolicy.canDispatchStart(7, 9, isShuttingDown = false))
        assertTrue(VpnStopLifecyclePolicy.canDispatchStart(9, 9, isShuttingDown = false))
    }

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
