package com.tecclub.flutter_singbox.bg

import android.os.IBinder
import android.content.Context
import android.content.Intent
import android.content.ComponentName
import android.os.Build
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import kotlin.coroutines.resume

/** No cached 'enabled' flag: missing/dead runtime response means unknown. */
internal object KillSwitchStatus {
    suspend fun query(context: Context): Map<String, Any?> = withContext(Dispatchers.Main) {
        val requested = withContext(Dispatchers.IO) {
            com.tecclub.flutter_singbox.config.KillSwitchIntentStore.requested(context)
        }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return@withContext mapOf("supported" to false, "known" to false, "requested" to requested)
        val system = systemState(context)
        val runtime = NativeProtectionQuery.read(context)
        mapOf<String, Any?>(
            "supported" to true,
            "known" to (system != null && (!requested || system.values.any { it } || runtime?.get("tunOpen") == true)),
            "requested" to requested,
            "runtimeKnown" to (runtime != null),
            "alwaysOn" to system?.get("alwaysOn"),
            "lockdown" to system?.get("lockdown"),
            "strictRuntime" to (runtime?.get("strictRuntime") == true),
            "vpnActive" to (runtime?.get("vpnActive") == true),
        )
    }

    suspend fun systemState(context: Context): Map<String, Boolean>? = withContext(Dispatchers.Main) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return@withContext null
        bindRead(context, Intent(context, ProtectionQueryService::class.java), Context.BIND_AUTO_CREATE) {
            (it as? ProtectionQueryService.QueryBinder)?.snapshot()
        }
    }

    private suspend fun bindRead(context: Context, intent: Intent, flags: Int,
                                 read: (IBinder) -> Map<String, Boolean>?): Map<String, Boolean>? =
        withTimeoutOrNull(900L) {
            suspendCancellableCoroutine { continuation ->
                var bound = false
                lateinit var connection: android.content.ServiceConnection
                fun cleanup() {
                    if (bound) {
                        bound = false
                        runCatching { context.unbindService(connection) }
                    }
                }
                fun finish(value: Map<String, Boolean>?) {
                    cleanup()
                    if (continuation.isActive) continuation.resume(value)
                }
                connection = object : android.content.ServiceConnection {
                    override fun onServiceConnected(name: ComponentName, binder: IBinder) =
                        finish(runCatching { read(binder) }.getOrNull())
                    override fun onServiceDisconnected(name: ComponentName) = finish(null)
                    override fun onNullBinding(name: ComponentName) = finish(null)
                    override fun onBindingDied(name: ComponentName) = finish(null)
                }
                bound = runCatching { context.bindService(intent, connection, flags) }.getOrDefault(false)
                if (!bound) finish(null)
                continuation.invokeOnCancellation {
                    android.os.Handler(android.os.Looper.getMainLooper()).post { cleanup() }
                }
            }
        }
}
