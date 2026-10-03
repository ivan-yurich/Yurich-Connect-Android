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
        isShuttingDown: Boolean,
        nativeStatus: Status?,
        requiresActiveVpnNetwork: Boolean,
        hasActiveVpnNetwork: Boolean
    ): Status = when {
        isShuttingDown -> Status.Stopping
        !startedByUser -> Status.Stopped
        nativeStatus == null -> Status.Starting
        nativeStatus == Status.Started && requiresActiveVpnNetwork && !hasActiveVpnNetwork -> Status.Starting
        else -> nativeStatus
    }
}
