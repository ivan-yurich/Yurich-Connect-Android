package online.dnsai.ivanvpn.qa

import android.app.Service
import android.content.Intent
import android.os.IBinder
import android.util.Log
import kotlin.concurrent.thread

class SoakControlService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val commandName = intent?.getStringExtra(SoakControlCommandHandler.EXTRA_COMMAND)
            ?.trim()?.lowercase()
        if (commandName == PassiveSoakController.COMMAND_EXPORT) {
            val command = Intent(requireNotNull(intent))
            thread(name = "yurich-soak-export") {
                try {
                    SoakControlCommandHandler.handle(applicationContext, command)
                } catch (error: Throwable) {
                    Log.e(TAG, "QA command failed type=${error.javaClass.simpleName}")
                } finally {
                    stopSelfResult(startId)
                }
            }
            return START_NOT_STICKY
        }
        try {
            requireNotNull(intent) { "Missing QA control intent" }
            SoakControlCommandHandler.handle(applicationContext, intent)
        } catch (error: Throwable) {
            Log.e(TAG, "QA command failed type=${error.javaClass.simpleName}")
        } finally {
            stopSelf(startId)
        }
        return START_NOT_STICKY
    }

    companion object {
        private const val TAG = "SoakControlService"
    }
}
