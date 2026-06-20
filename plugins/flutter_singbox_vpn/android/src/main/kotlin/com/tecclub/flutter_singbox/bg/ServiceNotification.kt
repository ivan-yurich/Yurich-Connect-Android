package com.tecclub.flutter_singbox.bg

import android.app.Service
import android.os.Build
import com.tecclub.flutter_singbox.constant.Status
import androidx.lifecycle.MutableLiveData
import com.tecclub.flutter_singbox.model.ConnectionUiState

class ServiceNotification(
    private val statusLiveData: MutableLiveData<Status>,
    private val service: Service
) {
    companion object {
        const val CHANNEL_ID = VpnNotificationHelper.CHANNEL_ID
        const val NOTIFICATION_ID = VpnNotificationHelper.NOTIFICATION_ID
    }

    private val helper = VpnNotificationHelper(service)

    init {
        helper.createNotificationChannel()
    }
    
    fun show(profileName: String, details: String) {
        val state = when {
            details.contains("Подключ", ignoreCase = true) &&
                !details.contains("...", ignoreCase = true) -> ConnectionUiState.connected(
                    profileName = profileName.takeIf { it.isNotBlank() },
                    protocolDisplayName = null,
                    countryName = null,
                    uploadSpeed = "0 B/s",
                    downloadSpeed = "0 B/s",
                    totalTraffic = "0 B"
                )
            details.contains("Отключ", ignoreCase = true) -> ConnectionUiState.disconnected()
            else -> ConnectionUiState.connecting(
                profileName = profileName.takeIf { it.isNotBlank() }
            )
        }
        show(state)
    }

    fun show(state: ConnectionUiState) {
        service.startForeground(NOTIFICATION_ID, helper.buildNotification(state))
    }

    fun update(state: ConnectionUiState) {
        helper.updateNotification(state)
    }
    
    fun start() {
        // This method is called when the service is successfully started
        statusLiveData.postValue(Status.Started)
    }
    
    fun stop() {
        // This method is called when the service is stopping
        statusLiveData.postValue(Status.Stopped)
        
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            service.stopForeground(Service.STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            service.stopForeground(true)
        }
    }
}
