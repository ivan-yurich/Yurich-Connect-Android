package com.tecclub.flutter_singbox.constant

import java.util.Locale

/**
 * Helper class for traffic statistics formatting
 */
class TrafficStats {
    /**
     * Formats a number of bytes into a human-readable format (KB, MB, GB)
     */
    companion object {
        fun formatBytes(bytes: Long): String {
            return when {
                bytes < 1024 -> "$bytes B"
                bytes < 1024 * 1024 -> String.format(Locale.ROOT, "%.2f KB", bytes / 1024.0)
                bytes < 1024 * 1024 * 1024 -> String.format(Locale.ROOT, "%.2f MB", bytes / (1024.0 * 1024.0))
                else -> String.format(Locale.ROOT, "%.2f GB", bytes / (1024.0 * 1024.0 * 1024.0))
            }
        }
    }
}
