package com.tecclub.flutter_singbox.bg

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import com.tecclub.flutter_singbox.constant.Action
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withTimeoutOrNull
import kotlin.coroutines.resume

/** Same private, registered-only IPC as NativeStatusQuery. No service creation. */
internal object NativeProtectionQuery {
    const val PRESENT = 1
    const val INCLUDE_APP_ROUTING = "includeAppRouting"
    const val APPLIED_EXCLUSIONS = "appliedAppExclusions"
    const val MAX_REPORTED_EXCLUSIONS = 192
    val keys = setOf("alwaysOn", "lockdown", "strictRuntime", "vpnActive", "tunOpen")

    data class AppRouting(val excludedPackages: List<String>?, val strict: Boolean)
    private data class Snapshot(val flags: Map<String, Boolean>, val exclusions: List<String>?)

    fun decode(code: Int, flags: Map<String, Boolean>?): Map<String, Boolean>? =
        flags?.takeIf { code == PRESENT && it.keys.containsAll(keys) }?.filterKeys { it in keys }

    suspend fun read(context: Context): Map<String, Boolean>? = observe(context, false)?.flags

    suspend fun readAppRouting(context: Context): AppRouting? = observe(context, true)?.let {
        AppRouting(
            excludedPackages = it.exclusions.takeIf { _ ->
                it.flags["tunOpen"] == true && it.flags["vpnActive"] == true
            },
            strict = it.flags["strictRuntime"] == true || it.flags["alwaysOn"] == true ||
                it.flags["lockdown"] == true,
        )
    }

    private suspend fun observe(context: Context, includeApps: Boolean): Snapshot? = withTimeoutOrNull(750L) {
        suspendCancellableCoroutine { continuation ->
            val reply = object : BroadcastReceiver() {
                override fun onReceive(context: Context?, intent: Intent?) {
                    val extras = getResultExtras(false)
                    val flags = extras?.let { bundle ->
                        keys.filter { bundle.containsKey(it) }.associateWith { bundle.getBoolean(it) }
                    }
                    val decoded = decode(resultCode, flags)
                    val exclusions = if (includeApps) extras?.getStringArrayList(APPLIED_EXCLUSIONS)
                        ?.takeIf { it.size <= MAX_REPORTED_EXCLUSIONS && it.all { id -> id.length in 1..255 } }
                        ?.toList() else null
                    if (continuation.isActive) {
                        continuation.resume(decoded?.let { Snapshot(it, exclusions) })
                    }
                }
            }
            try {
                context.sendOrderedBroadcast(
                    Intent(Action.SERVICE_PROTECTION_QUERY).setPackage(context.packageName)
                        .putExtra(INCLUDE_APP_ROUTING, includeApps)
                        .addFlags(Intent.FLAG_RECEIVER_REGISTERED_ONLY),
                    null, reply, Handler(Looper.getMainLooper()), 0, null, null,
                )
            } catch (_: Exception) {
                if (continuation.isActive) continuation.resume(null)
            }
        }
    }
}
