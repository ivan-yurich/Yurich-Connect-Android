package com.tecclub.flutter_singbox.bg

import android.content.Intent
import android.net.VpnService
import android.os.Binder
import android.os.Build
import android.os.IBinder

/** Bind-only query in the caller UID. No VPN intent-filter, TUN, config or core.
 * Public VpnService getters query the caller UID, not a specific VPN instance.
 */
class ProtectionQueryService : VpnService() {
    inner class QueryBinder : Binder() {
        fun snapshot(): Map<String, Boolean> {
            check(Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q)
            val identity = Binder.clearCallingIdentity()
            return try {
                mapOf("alwaysOn" to isAlwaysOn, "lockdown" to isLockdownEnabled)
            } finally { Binder.restoreCallingIdentity(identity) }
        }
    }
    override fun onBind(intent: Intent): IBinder = QueryBinder()
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        stopSelf(startId)
        return START_NOT_STICKY
    }
}
