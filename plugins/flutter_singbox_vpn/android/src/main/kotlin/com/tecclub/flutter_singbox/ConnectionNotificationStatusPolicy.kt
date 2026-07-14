package com.tecclub.flutter_singbox

import com.tecclub.flutter_singbox.constant.Status
import com.tecclub.flutter_singbox.model.ConnectionStatus

internal object ConnectionNotificationStatusPolicy {
    fun resolve(
        requestedStatus: ConnectionStatus,
        nativeStatus: Status,
    ): ConnectionStatus = when (nativeStatus) {
        Status.Started -> ConnectionStatus.Connected
        Status.Starting,
        Status.Stopping -> ConnectionStatus.Connecting
        Status.Stopped -> ConnectionStatus.Disconnected
    }
}
