package com.tecclub.flutter_singbox

import com.tecclub.flutter_singbox.constant.Status

internal object VpnStatusResolver {
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
        currentStatus == Status.Starting -> Status.Starting
        requiresActiveVpnNetwork && !hasActiveVpnNetwork -> Status.Starting
        else -> Status.Started
    }
}
