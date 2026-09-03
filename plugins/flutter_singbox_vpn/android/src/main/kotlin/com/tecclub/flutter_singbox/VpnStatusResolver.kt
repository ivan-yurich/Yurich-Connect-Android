package com.tecclub.flutter_singbox

import com.tecclub.flutter_singbox.constant.Status

internal object VpnStatusResolver {
    fun resolveServiceBroadcastStatus(
        broadcastStatus: Status,
        isShuttingDown: Boolean,
        isStarting: Boolean = false,
        startedByUser: Boolean = false
    ): Status = when {
        isShuttingDown && broadcastStatus == Status.Stopped -> Status.Stopping
        isStarting && startedByUser && broadcastStatus == Status.Stopped -> Status.Starting
        else -> broadcastStatus
    }

    fun resolveRunningServiceStatus(
        startedByUser: Boolean,
        isStarting: Boolean,
        isShuttingDown: Boolean,
        currentStatus: Status,
        requiresActiveVpnNetwork: Boolean,
        hasActiveVpnNetwork: Boolean
    ): Status = when {
        isStarting -> Status.Starting
        isShuttingDown -> Status.Stopping
        currentStatus == Status.Stopping -> Status.Stopping
        !startedByUser -> Status.Stopped
        requiresActiveVpnNetwork && !hasActiveVpnNetwork -> Status.Starting
        currentStatus == Status.Starting && !requiresActiveVpnNetwork -> Status.Starting
        else -> Status.Started
    }
}
