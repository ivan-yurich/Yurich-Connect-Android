package com.tecclub.flutter_singbox.bg

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import androidx.core.content.ContextCompat
import com.tecclub.flutter_singbox.Application
import com.tecclub.flutter_singbox.config.SimpleConfigManager
import com.tecclub.flutter_singbox.constant.Action
import com.tecclub.flutter_singbox.database.Settings
import java.util.concurrent.atomic.AtomicBoolean

class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action ?: return
        if (action !in RESTORE_ACTIONS) {
            return
        }

        val appContext = context.applicationContext
        if (action == Intent.ACTION_MY_PACKAGE_REPLACED) {
            val pendingResult = goAsync()
            val finished = AtomicBoolean(false)
            val finishOnce = {
                if (finished.compareAndSet(false, true)) pendingResult.finish()
            }
            val worker = Thread({
                try {
                    PackageReplaceRestoreRunner().execute(action) { attempt ->
                        attemptRestore(appContext, action, attempt)
                    }
                } finally {
                    finishOnce()
                }
            }, "YurichPackageRestore").apply { isDaemon = true }
            try {
                worker.start()
            } catch (error: Exception) {
                Log.w(
                    TAG,
                    "restore action=package_replaced result=worker_failed " +
                        "error=${error.javaClass.simpleName}",
                )
                finishOnce()
            }
            return
        }

        attemptRestore(appContext, action, attempt = 1)
    }

    private fun attemptRestore(
        context: Context,
        action: String,
        attempt: Int,
    ): RestoreAttemptResult = try {
        Application.initializeBaseIfNeeded(context)

        val autoStart = SimpleConfigManager.getAutoStart(context)
        val manualDisconnect = if (action == Intent.ACTION_MY_PACKAGE_REPLACED) {
            SimpleConfigManager.getManualDisconnectRequested()
        } else {
            null
        }
        val shouldRestore = PackageReplaceRestorePolicy.restoreRequested(
            autoStart = autoStart,
            startedByUser = SimpleConfigManager.getStartedByUser(context),
            manualDisconnectRequested = manualDisconnect,
        )
        if (!shouldRestore || !SimpleConfigManager.hasValidConfig(context)) {
            logResult(action, attempt, RestoreAttemptResult.NOT_READY)
            RestoreAttemptResult.NOT_READY
        } else {
            val stillRequested = PackageReplaceRestorePolicy.restoreRequested(
                autoStart = SimpleConfigManager.getAutoStart(context),
                startedByUser = SimpleConfigManager.getStartedByUser(context),
                manualDisconnectRequested = SimpleConfigManager.getManualDisconnectRequested(),
            )
            if (!stillRequested) {
                logResult(action, attempt, RestoreAttemptResult.NOT_READY)
                RestoreAttemptResult.NOT_READY
            } else {
                if (autoStart) {
                    SimpleConfigManager.setStartedByUser(true)
                    SimpleConfigManager.setManualDisconnectRequested(false)
                }

                val serviceIntent = Intent(context, Settings.serviceClass()).apply {
                    this.action = BoxService.ACTION_START
                    putExtra(Action.EXTRA_BACKGROUND_RESTORE, true)
                    if (autoStart) {
                        putExtra(Action.EXTRA_USER_INITIATED, true)
                    }
                }
                ContextCompat.startForegroundService(context, serviceIntent)
                logResult(action, attempt, RestoreAttemptResult.STARTED)
                RestoreAttemptResult.STARTED
            }
        }
    } catch (error: Exception) {
        Log.w(
            TAG,
            "restore action=${actionLabel(action)} attempt=$attempt result=start_failed " +
                "error=${error.javaClass.simpleName}",
        )
        RestoreAttemptResult.START_FAILED
    }

    private fun logResult(action: String, attempt: Int, result: RestoreAttemptResult) {
        Log.i(
            TAG,
            "restore action=${actionLabel(action)} attempt=$attempt result=${result.name.lowercase()}",
        )
    }

    private fun actionLabel(action: String): String = when (action) {
        Intent.ACTION_MY_PACKAGE_REPLACED -> "package_replaced"
        Intent.ACTION_BOOT_COMPLETED -> "boot_completed"
        "android.intent.action.LOCKED_BOOT_COMPLETED" -> "locked_boot_completed"
        else -> "quickboot"
    }

    private companion object {
        private const val TAG = "BootReceiver"
        private val RESTORE_ACTIONS = setOf(
            Intent.ACTION_BOOT_COMPLETED,
            "android.intent.action.LOCKED_BOOT_COMPLETED",
            Intent.ACTION_MY_PACKAGE_REPLACED,
            "android.intent.action.QUICKBOOT_POWERON",
        )
    }
}
