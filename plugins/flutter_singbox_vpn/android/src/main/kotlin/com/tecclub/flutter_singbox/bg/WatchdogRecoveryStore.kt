package com.tecclub.flutter_singbox.bg

import android.content.Context
import android.os.SystemClock
import android.provider.Settings
import android.util.Log

// Only the VPN process writes this file. UI flag commits cannot erase the budget.
internal object WatchdogRecoveryStore {
    private const val PREFS = "watchdog_recovery"

    private fun boot(context: Context): Int = runCatching {
        Settings.Global.getInt(context.contentResolver, Settings.Global.BOOT_COUNT)
    }.getOrDefault(-1)

    @Synchronized
    fun read(context: Context, fingerprint: String,
             nowMs: Long = SystemClock.elapsedRealtime()): WatchdogRecoveryState? = runCatching {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val last = prefs.getLong("lastRestart", 0L).coerceAtLeast(0L)
        if (prefs.getString("fingerprint", null) != fingerprint ||
            prefs.getInt("boot", -1) != boot(context) || nowMs < last) {
            WatchdogRecoveryState()
        } else WatchdogRecoveryState(last, prefs.getInt("attempts", 0).coerceIn(0, 5),
            prefs.getLong("healthySince", 0L).coerceAtLeast(0L),
            prefs.getLong("lastHealthy", 0L).coerceAtLeast(0L))
    }.onFailure { Log.w("BoxService", "Recovery budget unavailable: ${it.javaClass.simpleName}") }
        .getOrNull()

    @Synchronized
    fun write(context: Context, fingerprint: String, state: WatchdogRecoveryState): Boolean = runCatching {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putString("fingerprint", fingerprint).putInt("boot", boot(context))
            .putLong("lastRestart", state.lastRestartAtMs).putInt("attempts", state.attempts)
            .putLong("healthySince", state.healthySinceMs).putLong("lastHealthy", state.lastHealthyAtMs)
            .commit()
    }.onFailure { Log.w("BoxService", "Recovery budget write failed: ${it.javaClass.simpleName}") }
        .getOrDefault(false)

    @Synchronized
    fun observe(context: Context, fingerprint: String, nowMs: Long, healthy: Boolean) {
        val previous = read(context, fingerprint, nowMs) ?: return
        val next = WatchdogRecoveryPolicy.observed(previous, nowMs, healthy)
        if (next != previous) write(context, fingerprint, next)
    }
}
