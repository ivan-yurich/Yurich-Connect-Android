package com.tecclub.flutter_singbox.bg

import android.content.Intent
import android.os.Binder
import android.os.RemoteException
import androidx.lifecycle.LiveData
import androidx.lifecycle.MutableLiveData
import com.tecclub.flutter_singbox.Application
import com.tecclub.flutter_singbox.constant.Action
import com.tecclub.flutter_singbox.constant.Alert
import com.tecclub.flutter_singbox.constant.Status

class ServiceBinder(
    private val statusLiveData: MutableLiveData<Status>
) : Binder() {
    
    companion object {
        private val callbackList = mutableListOf<ServiceCallback>()
        
        // Broadcast alert to all listeners
        fun broadcastAlert(alert: Alert, message: String? = null) {
            Application.application.sendBroadcast(
                Intent(Action.BROADCAST_ALERT).apply {
                    `package` = Application.application.packageName
                    putExtra(Action.EXTRA_ALERT, alert.ordinal)
                    putExtra(Action.EXTRA_ALERT_MESSAGE, message)
                }
            )
        }
    }
    
    private val statusValue: Int
        get() = statusLiveData.value?.ordinal ?: Status.Stopped.ordinal
        
    // Method to get the current status as an enum
    fun getStatusEnum(): Status {
        return statusLiveData.value ?: Status.Stopped
    }
    
    fun close() {
        synchronized(callbackList) {
            callbackList.clear()
        }
    }
    
    // Broadcast to all registered callbacks
    fun broadcast(action: (ServiceCallback) -> Unit) {
        synchronized(callbackList) {
            for (callback in callbackList.toList()) {
                try {
                    action(callback)
                } catch (e: Exception) {
                    callbackList.remove(callback)
                }
            }
        }
    }
    
    // Service methods
    fun getStatus(): Int = statusValue
    
    fun getUploadBytes(): Long = 0 // We're using StatusClient for traffic stats now
    
    fun getDownloadBytes(): Long = 0 // We're using StatusClient for traffic stats now
    
    fun registerCallback(callback: ServiceCallback) {
        synchronized(callbackList) {
            callbackList.add(callback)
            try {
                callback.onServiceStatusChanged(statusValue)
                // Still call this for consistency
                callback.onTrafficUpdate(0, 0) 
            } catch (e: Exception) {
                callbackList.remove(callback)
            }
        }
    }
    
    fun unregisterCallback(callback: ServiceCallback) {
        synchronized(callbackList) {
            callbackList.remove(callback)
        }
    }
    
    // Interface for callbacks
    interface Callback {
        fun onServiceStatusChanged(status: Status)
        fun onServiceAlert(type: Alert, message: String? = null) {}
    }
}
