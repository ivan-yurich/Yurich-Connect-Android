package online.dnsai.ivanvpn.qa

import android.app.Service
import android.content.Intent
import android.os.IBinder
import android.util.Log

class SoakControlService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        try {
            requireNotNull(intent) { "Missing QA control intent" }
            SoakControlCommandHandler.handle(applicationContext, intent)
        } catch (error: Throwable) {
            Log.e(TAG, "QA command failed: ${error.message}", error)
        } finally {
            stopSelf(startId)
        }
        return START_NOT_STICKY
    }

    companion object {
        private const val TAG = "SoakControlService"
    }
}
