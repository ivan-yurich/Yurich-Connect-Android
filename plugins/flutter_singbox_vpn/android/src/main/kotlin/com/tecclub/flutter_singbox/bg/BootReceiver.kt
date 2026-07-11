package com.tecclub.flutter_singbox.bg

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import androidx.core.content.ContextCompat
import com.tecclub.flutter_singbox.Application
import com.tecclub.flutter_singbox.config.SimpleConfigManager
import com.tecclub.flutter_singbox.constant.Action
import com.tecclub.flutter_singbox.database.Settings

class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action !in RESTORE_ACTIONS) {
            return
        }

        Application.initializeIfNeeded(context.applicationContext)

        val autoStart = SimpleConfigManager.getAutoStart(context)
        val shouldRestore = autoStart || SimpleConfigManager.getStartedByUser(context)
        if (!shouldRestore || !SimpleConfigManager.hasValidConfig(context)) {
            return
        }
        if (autoStart) {
            SimpleConfigManager.setStartedByUser(true)
            SimpleConfigManager.setManualDisconnectRequested(false)
        }

        val serviceIntent = Intent(context, Settings.serviceClass()).apply {
            action = BoxService.ACTION_START
            if (autoStart) {
                putExtra(Action.EXTRA_USER_INITIATED, true)
            }
        }
        ContextCompat.startForegroundService(context, serviceIntent)
    }

    private companion object {
        private val RESTORE_ACTIONS = setOf(
            Intent.ACTION_BOOT_COMPLETED,
            "android.intent.action.LOCKED_BOOT_COMPLETED",
            Intent.ACTION_MY_PACKAGE_REPLACED,
            "android.intent.action.QUICKBOOT_POWERON",
        )
    }
}
