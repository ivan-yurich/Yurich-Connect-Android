package online.dnsai.ivanvpn.qa

import android.app.Activity
import android.os.Bundle
import android.util.Log

class SoakControlActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        try {
            SoakControlCommandHandler.handle(applicationContext, intent)
        } catch (error: Throwable) {
            Log.e(TAG, "QA command failed: ${error.message}", error)
        } finally {
            finish()
        }
    }

    companion object {
        private const val TAG = "SoakControlActivity"
    }
}
