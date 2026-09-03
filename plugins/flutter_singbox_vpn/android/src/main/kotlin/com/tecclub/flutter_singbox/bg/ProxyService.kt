package com.tecclub.flutter_singbox.bg

import android.app.Service
import android.content.Intent
import com.tecclub.flutter_singbox.Application
import io.nekohasekai.libbox.Notification

class ProxyService : Service(), PlatformInterfaceWrapper {

    private val service = BoxService(this, this)

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        Application.initializeBaseIfNeeded(applicationContext)
        return service.onStartCommand()
    }

    override fun onBind(intent: Intent) = service.onBind()
    override fun onDestroy() = service.onDestroy()

    fun writeLog(message: String) = service.writeLog(message)
    
    override fun sendNotification(notification: Notification) =
        service.sendNotification(notification)
}
