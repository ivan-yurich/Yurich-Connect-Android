package com.tecclub.flutter_singbox.utils

import java.util.Locale
import kotlin.math.roundToInt

object TrafficFormatter {
    private val units = arrayOf("B", "KB", "MB", "GB", "TB")

    fun formatSpeed(bytesPerSecond: Long): String {
        return "${formatBytes(bytesPerSecond)}/s"
    }

    fun formatBytes(bytes: Long): String {
        var amount = bytes.coerceAtLeast(0L).toDouble()
        var index = 0
        while (amount >= 1024.0 && index < units.lastIndex) {
            amount /= 1024.0
            index += 1
        }

        if (index == 0) {
            return "${bytes.coerceAtLeast(0L)} ${units[index]}"
        }

        val value = if (amount >= 100.0 || amount == amount.roundToInt().toDouble()) {
            amount.roundToInt().toString()
        } else {
            String.format(Locale.US, "%.1f", amount)
        }
        return "$value ${units[index]}"
    }

    fun formatDuration(seconds: Long): String {
        val totalSeconds = seconds.coerceAtLeast(0L)
        val hours = totalSeconds / 3600
        val minutes = (totalSeconds % 3600) / 60
        val secs = totalSeconds % 60
        return "%02d:%02d:%02d".format(hours, minutes, secs)
    }
}
