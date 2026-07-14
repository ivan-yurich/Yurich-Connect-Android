package com.tecclub.flutter_singbox

import com.tecclub.flutter_singbox.constant.Status
import com.tecclub.flutter_singbox.model.ConnectionStatus
import kotlin.test.Test
import kotlin.test.assertEquals

class ConnectionNotificationStatusPolicyTest {
    @Test
    fun `stale disconnected update cannot overwrite a ready tunnel`() {
        assertEquals(
            ConnectionStatus.Connected,
            ConnectionNotificationStatusPolicy.resolve(
                requestedStatus = ConnectionStatus.Disconnected,
                nativeStatus = Status.Started,
            ),
        )
    }

    @Test
    fun `stale connected update cannot overwrite recovery state`() {
        assertEquals(
            ConnectionStatus.Connecting,
            ConnectionNotificationStatusPolicy.resolve(
                requestedStatus = ConnectionStatus.Connected,
                nativeStatus = Status.Starting,
            ),
        )
    }

    @Test
    fun `stopped native service always resolves to disconnected`() {
        assertEquals(
            ConnectionStatus.Disconnected,
            ConnectionNotificationStatusPolicy.resolve(
                requestedStatus = ConnectionStatus.Connected,
                nativeStatus = Status.Stopped,
            ),
        )
    }

    @Test
    fun `matching connected state stays connected`() {
        assertEquals(
            ConnectionStatus.Connected,
            ConnectionNotificationStatusPolicy.resolve(
                requestedStatus = ConnectionStatus.Connected,
                nativeStatus = Status.Started,
            ),
        )
    }
}
