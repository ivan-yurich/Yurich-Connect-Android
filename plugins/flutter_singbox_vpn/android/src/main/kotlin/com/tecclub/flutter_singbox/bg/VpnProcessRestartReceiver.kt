package com.tecclub.flutter_singbox.bg

import android.app.ActivityManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Process
import android.os.SystemClock
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
        val previousPid = intent.getIntExtra(EXTRA_PREVIOUS_VPN_PID, -1)
        thread(name = "yurich-vpn-core-switch") {
            try {
                val receiverPid = Process.myPid()
                val activityManager = appContext.getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager
                    ?: error("Process observer unavailable")
                val waitingAt = SystemClock.elapsedRealtime()
                val exited = VpnProcessRestartPolicy.awaitPreviousProcessExit(
                    previousPid = previousPid,
                    receiverPid = receiverPid,
                    elapsedRealtime = SystemClock::elapsedRealtime,
                    sleep = Thread::sleep,
                    processExists = { pid ->
                        val ownPids = activityManager.runningAppProcesses
                            ?.filter { it.uid == Process.myUid() }?.map { it.pid }?.toSet()
                        VpnProcessRestartPolicy.previousProcessExists(pid, receiverPid, ownPids)
                    },
                )
                if (!exited) {
                    Log.w(TAG, "Clean VPN restart skipped: previous process exit not confirmed")
                    return@thread
                }
                Log.i(TAG, "Previous VPN process exit confirmed after ${SystemClock.elapsedRealtime() - waitingAt}ms")
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
        const val EXTRA_PREVIOUS_VPN_PID = "previous_vpn_pid"
        private const val TAG = "VpnProcessRestart"
    }
}
