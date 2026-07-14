package online.dnsai.ivanvpn.qa

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Base64
import android.util.Log
import androidx.core.content.ContextCompat
import com.tecclub.flutter_singbox.Application
import com.tecclub.flutter_singbox.bg.BoxService
import com.tecclub.flutter_singbox.config.SimpleConfigManager
import com.tecclub.flutter_singbox.constant.Action
import com.tecclub.flutter_singbox.database.Settings
import org.json.JSONObject
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.util.zip.GZIPInputStream
import kotlin.concurrent.thread

class SoakControlReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val pendingResult = goAsync()
        val appContext = context.applicationContext
        thread(name = "yurich-soak-control") {
            try {
                SoakControlCommandHandler.handle(appContext, intent)
            } catch (error: Throwable) {
                Log.e(TAG, "QA command failed: ${error.message}", error)
            } finally {
                pendingResult.finish()
            }
        }
    }

    companion object {
        private const val TAG = "SoakControlReceiver"
    }
}

internal object SoakControlCommandHandler {
    fun handle(context: Context, intent: Intent) {
        Application.initializeIfNeeded(context)
        when (intent.getStringExtra(EXTRA_COMMAND)?.trim()?.lowercase()) {
            COMMAND_ACTIVATE -> activate(context, intent)
            COMMAND_STOP -> {
                BoxService.stop()
                Log.i(TAG, "QA stop requested")
            }
            COMMAND_RESTART -> {
                context.sendBroadcast(
                    Intent(Action.SERVICE_RESTART).apply {
                        `package` = context.packageName
                        putExtra(Action.EXTRA_USER_INITIATED, true)
                    },
                )
                Log.i(TAG, "QA notification-equivalent restart requested")
            }
            COMMAND_STATUS -> {
                Log.i(
                    TAG,
                    "QA status validConfig=${SimpleConfigManager.hasValidConfig()} " +
                        "startedByUser=${SimpleConfigManager.getStartedByUser()}",
                )
            }
            else -> error("Unsupported or missing QA command")
        }
    }

    private fun activate(context: Context, intent: Intent) {
        val encoded = intent.getStringExtra(EXTRA_CONFIG_GZIP_BASE64)
            ?: error("Missing compressed runtime config")
        val config = decodeConfig(encoded)
        JSONObject(config)

        check(SimpleConfigManager.saveConfig(config)) {
            "Unable to persist QA runtime config"
        }
        SimpleConfigManager.setStartedByUser(true)
        SimpleConfigManager.setManualDisconnectRequested(false)

        val label = intent.getStringExtra(EXTRA_PROFILE_LABEL)
            ?.replace(Regex("[\\r\\n\\t]"), " ")
            ?.trim()
            ?.take(MAX_LABEL_LENGTH)
            .orEmpty()
        if (label.isNotEmpty()) {
            SimpleConfigManager.setNotificationDescription(label)
        }

        val serviceIntent = Intent(context, Settings.serviceClass()).apply {
            action = BoxService.ACTION_START
            putExtra(BoxService.EXTRA_CONFIG_CONTENT, config)
        }
        ContextCompat.startForegroundService(context, serviceIntent)
        Log.i(TAG, "QA activate requested label=$label configLength=${config.length}")
    }

    private fun decodeConfig(encoded: String): String {
        val compressed = Base64.decode(encoded, Base64.NO_WRAP)
        require(compressed.size <= MAX_COMPRESSED_BYTES) {
            "Compressed runtime config is too large"
        }

        val output = ByteArrayOutputStream()
        GZIPInputStream(ByteArrayInputStream(compressed)).use { input ->
            val buffer = ByteArray(BUFFER_SIZE)
            while (true) {
                val count = input.read(buffer)
                if (count < 0) break
                output.write(buffer, 0, count)
                require(output.size() <= MAX_CONFIG_BYTES) {
                    "Runtime config exceeds QA limit"
                }
            }
        }
        return output.toString(Charsets.UTF_8.name()).also {
            require(it.isNotBlank()) { "Runtime config is empty" }
        }
    }

    private const val TAG = "SoakControlCommandHandler"
        private const val EXTRA_COMMAND = "command"
        private const val EXTRA_CONFIG_GZIP_BASE64 = "configGzipB64"
        private const val EXTRA_PROFILE_LABEL = "profileLabel"
        private const val COMMAND_ACTIVATE = "activate"
        private const val COMMAND_STOP = "stop"
        private const val COMMAND_RESTART = "restart"
        private const val COMMAND_STATUS = "status"
        private const val MAX_COMPRESSED_BYTES = 256 * 1024
        private const val MAX_CONFIG_BYTES = 1024 * 1024
        private const val MAX_LABEL_LENGTH = 96
        private const val BUFFER_SIZE = 8192
}
