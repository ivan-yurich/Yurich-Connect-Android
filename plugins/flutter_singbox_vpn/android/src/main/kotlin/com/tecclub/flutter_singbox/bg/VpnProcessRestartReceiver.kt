package com.tecclub.flutter_singbox.bg

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log
import androidx.core.content.ContextCompat
import com.tecclub.flutter_singbox.Application
import com.tecclub.flutter_singbox.config.SimpleConfigManager
import com.tecclub.flutter_singbox.database.Settings
import kotlin.concurrent.thread

class VpnProcessRestartReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != ACTION_RESTART_CLEAN_PROCESS) {
            return
        }

        val pendingResult = goAsync()
        val appContext = context.applicationContext
        thread(name = "yurich-vpn-core-switch") {
            try {
                Thread.sleep(RESTART_DELAY_MS)
                Application.initializeBaseIfNeeded(appContext)
                val shouldRestart = SimpleConfigManager.getStartedByUser(appContext) &&
                    SimpleConfigManager.hasValidConfig(appContext)
                if (!shouldRestart) {
                    Log.w(TAG, "Clean VPN process restart skipped: user flag/config missing")
                    return@thread
                }

                val serviceIntent = Intent(appContext, Settings.serviceClass()).apply {
                    action = BoxService.ACTION_START
                }
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    ContextCompat.startForegroundService(appContext, serviceIntent)
                } else {
                    appContext.startService(serviceIntent)
                }
                Log.i(TAG, "Clean VPN process restart requested")
            } catch (error: Throwable) {
                Log.e(TAG, "Unable to restart VPN in a clean process", error)
            } finally {
                pendingResult.finish()
            }
        }
    }

    companion object {
        const val ACTION_RESTART_CLEAN_PROCESS =
            "com.tecclub.flutter_singbox.action.RESTART_CLEAN_VPN_PROCESS"
        private const val TAG = "VpnProcessRestart"
        private const val RESTART_DELAY_MS = 1_800L
    }
}
