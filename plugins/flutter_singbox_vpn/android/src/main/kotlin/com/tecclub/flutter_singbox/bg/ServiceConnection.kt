package com.tecclub.flutter_singbox.bg

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.os.IBinder
import android.os.RemoteException
import android.util.Log
import com.tecclub.flutter_singbox.bg.VPNService
import com.tecclub.flutter_singbox.constant.Action
import com.tecclub.flutter_singbox.constant.Alert
import com.tecclub.flutter_singbox.constant.Status

class ServiceConnection(
    private val context: Context,
    private val callback: Callback,
    private val register: Boolean = true,
) : ServiceConnection {

    companion object {
        private const val TAG = "ServiceConnection"
        private const val BIND_AUTO_CREATE = Context.BIND_AUTO_CREATE
    }

    // Create a callback handler for the service
    private var service: IBinder? = null
    var isBound = false
        private set
    
    // Flag to track intentional disconnect (suppress callbacks)
    private var isIntentionalDisconnect = false
    
    val binder: ServiceBinder?
        get() = service as? ServiceBinder

    private var _status = Status.Stopped
    val status get() = _status

    fun connect() {
        android.util.Log.e(TAG, "Connecting to service")
        
        // Reset intentional disconnect flag when connecting
        isIntentionalDisconnect = false
        
        // If already bound, don't reconnect
        if (isBound) {
            android.util.Log.e(TAG, "Already bound to service, skipping connect")
            return
        }
        
        // Create intent to bind to the service
        val intent = serviceIntent()
        
        // Try to bind to the service - BIND_AUTO_CREATE will create it if needed
        val bound = try {
            context.bindService(intent, this, BIND_AUTO_CREATE)
        } catch (e: Exception) {
            android.util.Log.e(TAG, "Failed to bind to service", e)
            false
        }
        
        android.util.Log.e(TAG, "Connect binding result: $bound")
        
        // Don't set status to Stopped here - let the service callbacks handle status
        // The service will send broadcasts when it actually starts/stops
    }

    fun disconnect() {
        android.util.Log.e(TAG, "Disconnecting from service")
        
        // Mark as intentional disconnect to suppress callbacks
        isIntentionalDisconnect = true
        
        // Only try to unbind if we're bound
        if (isBound) {
            // First update status to Stopping (not Stopped) - will become Stopped after actual disconnect
            _status = Status.Stopping
            
            try {
                android.util.Log.e(TAG, "Unbinding from service")
                // Now unbind
                context.unbindService(this)
            } catch (e: IllegalArgumentException) {
                android.util.Log.e(TAG, "Error unbinding from service", e)
            } finally {
                // Even if unbinding fails, mark as unbound
                isBound = false
                _status = Status.Stopped
            }
        } else {
            android.util.Log.e(TAG, "Not bound to service, nothing to disconnect")
        }
        
        // Clear service reference
        service = null
        
        android.util.Log.e(TAG, "Disconnected from service")
    }

    fun reconnect() {
        android.util.Log.e(TAG, "Reconnecting to service")
        
        // First disconnect properly
        try {
            context.unbindService(this)
            android.util.Log.e(TAG, "Unbound from previous service connection")
        } catch (e: IllegalArgumentException) {
            android.util.Log.e(TAG, "No existing service binding to unbind", e)
        }
        
        // Clear service reference
        service = null
        
        // Create new connection intent
        val intent = serviceIntent()
        
        // Attempt to bind to the service
        val bound = try {
            context.bindService(intent, this, BIND_AUTO_CREATE)
        } catch (e: Exception) {
            android.util.Log.e(TAG, "Failed to bind during reconnect", e)
            false
        }
        
        android.util.Log.e(TAG, "Reconnect binding result: $bound")
        
        // If binding fails, service is probably not running, so update status
        if (!bound) {
            android.util.Log.e(TAG, "Service not running, updating status to Stopped")
            callback.onServiceStatusChanged(Status.Stopped)
        }
    }

    override fun onServiceConnected(name: ComponentName, binder: IBinder) {
        android.util.Log.e(TAG, "Service connected")
        this.service = binder
        this.isBound = true
        
        try {
            _status = Status.Starting
            
            // Get the service status through the ServiceBinder
            val serviceBinder = binder as? ServiceBinder
            if (serviceBinder != null) {
                android.util.Log.e(TAG, "Got ServiceBinder")
                // In the plugin version, we can't directly access the status
                // Instead, we'll use our assumption that the service is running
            } else {
                android.util.Log.e(TAG, "Service is connected but binder is not ServiceBinder")
            }
            
        } catch (e: Exception) {
            android.util.Log.e(TAG, "Error initializing service connection", e)
            _status = Status.Stopped
            callback.onServiceStatusChanged(Status.Stopped)
        }
    }

    override fun onServiceDisconnected(name: ComponentName?) {
        android.util.Log.e(TAG, "Service disconnected (intentional=$isIntentionalDisconnect)")
        this.service = null
        this.isBound = false
        
        // Update our local status
        _status = Status.Stopped
        
        // Only notify callback if this was NOT an intentional disconnect
        // (intentional disconnects are handled by the caller)
        if (!isIntentionalDisconnect) {
            callback.onServiceStatusChanged(Status.Stopped)
        }
    }

    override fun onBindingDied(name: ComponentName?) {
        reconnect()
        Log.d(TAG, "service dead")
    }

    private fun serviceIntent(): Intent =
        Intent(context, VPNService::class.java).setAction(Action.SERVICE)

    interface Callback {
        fun onServiceStatusChanged(status: Status)
        fun onServiceAlert(type: Alert, message: String?) {}
        // Traffic updates are now handled by StatusClient
    }

    // Removed ServiceCallback inner class as we now use the separate ServiceCallback interface
}
