package com.tecclub.flutter_singbox.bg

import com.tecclub.flutter_singbox.model.ConnectionStatus
import com.tecclub.flutter_singbox.model.ConnectionUiState

/** Display only; reuses the existing foreground notification updates. */
internal object VpnNotificationTraffic {
    private const val MAX_PING_AGE_MS = 60_000L
    private val rate = Regex("[0-9]{1,12}(?:[.,][0-9]{1,2})? (?:B|KB|MB|GB|TB)/s")

    fun line(state: ConnectionUiState, nowMs: Long): String? {
        if (state.status != ConnectionStatus.Connected) return null
        return buildString {
            append("↓ ${formatRate(state.downloadSpeed)} · ↑ ${formatRate(state.uploadSpeed)}")
            freshPing(state, nowMs)?.let { append(" · $it ms") }
        }
    }

    fun freshPing(state: ConnectionUiState, nowMs: Long): Long? {
        if (state.status != ConnectionStatus.Connected) return null
        val observedAt = state.pingObservedAtMs ?: return null
        val ping = state.pingMs ?: return null
        return ping.takeIf {
            ping in 1L..120_000L && observedAt in 1L..nowMs && nowMs - observedAt < MAX_PING_AGE_MS
        }
    }

    private fun formatRate(value: String): String = value.takeIf(rate::matches) ?: "—"
}
