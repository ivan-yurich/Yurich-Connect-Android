package com.tecclub.flutter_singbox.bg

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import androidx.core.content.ContextCompat

internal class NativeSoakObserver(
    private val context: Context,
    private val snapshot: (includeNetwork: Boolean) -> NativeSoakSnapshot,
) {
    private var registered = false
    private val action = "${context.packageName}.action.SOAK_NATIVE_SNAPSHOT"
    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            val request = intent.getStringExtra("request")
            val version = intent.getIntExtra("version", 1)
            if (intent.action != action || !isOrderedBroadcast ||
                !NativeSoakSnapshot.validRequest(request) || version !in 1..3
            ) return
            val response = runCatching { snapshot(version >= 2).encode(requireNotNull(request), version) }
                .getOrNull() ?: return
            setResult(1, response, null)
        }
    }

    @Suppress("DEPRECATION")
    val enabled = runCatching {
        context.packageManager.getApplicationInfo(
            context.packageName, PackageManager.GET_META_DATA,
        ).metaData?.getBoolean("online.dnsai.ivanvpn.SOAK_NATIVE_OBSERVER", false) == true
    }.getOrDefault(false)

    fun register() {
        if (!enabled || registered) return
        // Dynamic only: observing a stopped VPN must not start its process.
        // No timer, Flutter binding, network request or wake lock is created.
        ContextCompat.registerReceiver(
            context, receiver, IntentFilter(action), "android.permission.DUMP", null,
            ContextCompat.RECEIVER_EXPORTED,
        )
        registered = true
    }

    fun unregister() {
        if (!registered) return
        context.unregisterReceiver(receiver)
        registered = false
    }
}
