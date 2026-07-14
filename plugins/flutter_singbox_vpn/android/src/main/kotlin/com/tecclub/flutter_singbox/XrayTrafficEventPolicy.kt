package com.tecclub.flutter_singbox

import com.tecclub.flutter_singbox.constant.Status
import com.tecclub.flutter_singbox.constant.TrafficStats

internal data class XrayUidTrafficSample(
    val txTotal: Long,
    val rxTotal: Long,
    val txSpeed: Long,
    val rxSpeed: Long,
    val sessionTx: Long,
    val sessionRx: Long,
)

internal object XrayTrafficEventPolicy {
    fun shouldCollect(status: Status, isXrayRuntime: Boolean): Boolean =
        status == Status.Started && isXrayRuntime

    fun build(
        sample: XrayUidTrafficSample,
        networkSnapshot: Map<String, Any>,
        active: Boolean = true,
    ): Map<String, Any> {
        val uplinkSpeed = if (active) sample.txSpeed.coerceAtLeast(0L) else 0L
        val downlinkSpeed = if (active) sample.rxSpeed.coerceAtLeast(0L) else 0L
        val uplinkTotal = sample.txTotal.coerceAtLeast(0L)
        val downlinkTotal = sample.rxTotal.coerceAtLeast(0L)
        val sessionUplink = sample.sessionTx.coerceAtLeast(0L)
        val sessionDownlink = sample.sessionRx.coerceAtLeast(0L)
        val sessionTotal = sessionUplink + sessionDownlink

        return networkSnapshot.toMutableMap().apply {
            putAll(
                mapOf(
                    "uplinkSpeed" to uplinkSpeed,
                    "downlinkSpeed" to downlinkSpeed,
                    "uplinkTotal" to uplinkTotal,
                    "downlinkTotal" to downlinkTotal,
                    "connectionsIn" to 0,
                    "connectionsOut" to 0,
                    "sessionUplink" to sessionUplink,
                    "sessionDownlink" to sessionDownlink,
                    "sessionTotal" to sessionTotal,
                    "formattedUplinkSpeed" to TrafficStats.formatBytes(uplinkSpeed) + "/s",
                    "formattedDownlinkSpeed" to TrafficStats.formatBytes(downlinkSpeed) + "/s",
                    "formattedUplinkTotal" to TrafficStats.formatBytes(uplinkTotal),
                    "formattedDownlinkTotal" to TrafficStats.formatBytes(downlinkTotal),
                    "formattedSessionUplink" to TrafficStats.formatBytes(sessionUplink),
                    "formattedSessionDownlink" to TrafficStats.formatBytes(sessionDownlink),
                    "formattedSessionTotal" to TrafficStats.formatBytes(sessionTotal),
                ),
            )
        }
    }
}
