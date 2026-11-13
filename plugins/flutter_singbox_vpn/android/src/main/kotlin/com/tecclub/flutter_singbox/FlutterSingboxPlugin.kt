package com.tecclub.flutter_singbox

import android.Manifest
import android.app.Activity
import android.app.ActivityManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.VpnService
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.os.SystemClock
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.getSystemService
import androidx.core.content.ContextCompat
import androidx.core.app.ActivityCompat
import androidx.lifecycle.LiveData
import androidx.lifecycle.Observer
import com.tecclub.flutter_singbox.bg.BoxService
import com.tecclub.flutter_singbox.bg.DirectProbeNetworkGate
import com.tecclub.flutter_singbox.bg.NativeConfigBinding
import com.tecclub.flutter_singbox.bg.NativeStatusQuery
import com.tecclub.flutter_singbox.bg.RuntimeConfigReload
import com.tecclub.flutter_singbox.bg.ServiceConnection
import com.tecclub.flutter_singbox.bg.ServiceNotification
import com.tecclub.flutter_singbox.bg.VpnCommandFence
import com.tecclub.flutter_singbox.bg.VpnNotificationHelper
import com.tecclub.flutter_singbox.database.Settings
import com.tecclub.flutter_singbox.config.SimpleConfigManager
import com.tecclub.flutter_singbox.constant.Action
import com.tecclub.flutter_singbox.constant.Alert
import com.tecclub.flutter_singbox.constant.Status
import com.tecclub.flutter_singbox.constant.ServiceMode
import com.tecclub.flutter_singbox.constant.TrafficStats
import com.tecclub.flutter_singbox.model.ConnectionStatus
import com.tecclub.flutter_singbox.model.ConnectionUiState
import com.tecclub.flutter_singbox.utils.StatusClient
import com.tecclub.flutter_singbox.utils.LogClient
import com.tecclub.flutter_singbox.utils.TrafficFormatter
import com.tecclub.flutter_singbox.xray.XrayRuntimeConfig
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import io.flutter.plugin.common.PluginRegistry
import io.nekohasekai.libbox.StatusMessage
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import java.util.concurrent.atomic.AtomicLong

/**
 * Compatibility facade for older plugin code paths.
 */
class ApplicationHelper {
    companion object {
        // Instance of the application context
        lateinit var application: Context
            private set
        
        // Quick access to common system services
        val powerManager: PowerManager by lazy { 
            application.getSystemService(Context.POWER_SERVICE) as PowerManager 
        }
        
        val connectivity by lazy { 
            application.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager 
        }
        
        val packageManager by lazy { 
            application.packageManager 
        }
        
        val notificationManager by lazy { 
            application.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager 
        }
        
        val wifiManager by lazy { 
            application.getSystemService(Context.WIFI_SERVICE) as WifiManager 
        }
        
        val clipboard by lazy { 
            application.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager 
        }
        
        // Version info for the app
        val versionName by lazy {
            try {
                application.packageManager.getPackageInfo(application.packageName, 0).versionName
            } catch (e: PackageManager.NameNotFoundException) {
                "com.tecclub.flutter_singbox"
            }
        }
        
        val versionCode: Long by lazy {
            try {
                if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.P) {
                    application.packageManager.getPackageInfo(application.packageName, 0).longVersionCode
                } else {
                    @Suppress("DEPRECATION")
                    application.packageManager.getPackageInfo(application.packageName, 0).versionCode.toLong()
                }
            } catch (e: PackageManager.NameNotFoundException) {
                0L
            }
        }
        
        /**
         * Initialize the application with the given context
         * This is called from the FlutterSingboxPlugin when the plugin is attached to the engine
         */
        fun initialize(context: Context) {
            application = context.applicationContext
            Application.initialize(application)
        }
    }
}

private const val APP_ALERT_CHANNEL_ID = "yurich_connect_alerts"

internal object VpnStopLifecyclePolicy {
    const val GRACEFUL_TIMEOUT_MS = 25_000L
    const val FORCE_STOP_TIMEOUT_MS = 4_000L
    const val PROCESS_EXIT_CONFIRM_TIMEOUT_MS = 2_000L

    fun canStart(isShuttingDown: Boolean): Boolean = !isShuttingDown

    fun canDispatchStart(generation: Long, currentGeneration: Long, isShuttingDown: Boolean): Boolean =
        generation == currentGeneration && canStart(isShuttingDown)

    fun canFinalize(serviceRunning: Boolean): Boolean = !serviceRunning

    fun canJoinStop(isShuttingDown: Boolean, activeGeneration: Long,
                    currentGeneration: Long, cleanupRunning: Boolean): Boolean =
        isShuttingDown && cleanupRunning && activeGeneration != 0L && activeGeneration == currentGeneration
}

/** FlutterSingboxPlugin */
class FlutterSingboxPlugin :
    FlutterPlugin,
    MethodCallHandler,
    ActivityAware,
    StatusClient.Handler,
    LogClient.Handler,
    ServiceConnection.Callback,
    PluginRegistry.ActivityResultListener {

    // Method channel for Flutter to native communication
    private lateinit var methodChannel: MethodChannel
    
    // Event channel for broadcasting status updates to Flutter
    private lateinit var statusEventChannel: EventChannel
    private lateinit var trafficEventChannel: EventChannel
    private lateinit var logEventChannel: EventChannel
    
    // Context and Activity references
    private lateinit var context: Context
    private var activity: Activity? = null
    
    // Service connection
    private val connection by lazy { ServiceConnection(context, this, false) }
    private val statusClient by lazy { StatusClient(coroutineScope, this) }
    private val logClient by lazy { LogClient(coroutineScope, this) }
    private val coroutineScope = CoroutineScope(Dispatchers.Main + Job())
    private val directProbeDns = mutableMapOf<Long, Job>()
    
    // Status tracking
    private val _vpnStatus = MutableStateFlow(Status.Stopped)
    val vpnStatus: StateFlow<Status> = _vpnStatus
    
    // For checking the initial status upon startup
    private var statusInitialized = false
    
    // Flag to prevent reconnection during shutdown
    private var isShuttingDown = false
    private var lastKnownSystemAlwaysOn: Boolean? = null
    
    // Flag to prevent Stopped status during startup
    private var isStarting = false
    
    // Flag to track if there was a startup error
    private var hasStartupError = false
    
    // Job for stop cleanup - can be cancelled when starting new connection
    private var stopCleanupJob: kotlinx.coroutines.Job? = null
    @Volatile private var stopCleanupCompleted = false
    private val lifecycleGeneration = AtomicLong(0L)
    @Volatile private var pendingVpnPermissionGeneration = 0L
    @Volatile private var activeStopGeneration = 0L
    private var earliestStopConfirmationAt = 0L
    private val configSaveGeneration = AtomicLong(0L)
    private val configSaveMutex = Mutex()
    private var periodicStatusJob: kotlinx.coroutines.Job? = null
    private var xrayTrafficJob: Job? = null
    @Volatile private var serviceStatusCheckInFlight = false
    private var networkGenerationId = 0
    private var lastNetworkFingerprint = ""
    private var lastNetworkChangedAtMs = 0L

    // Traffic stats
    private var _trafficStats = MutableStateFlow<Map<String, Any>>(
        mapOf(
            "uplinkSpeed" to 0L,
            "downlinkSpeed" to 0L,
            "uplinkTotal" to 0L,
            "downlinkTotal" to 0L,
            "connectionsIn" to 0,
            "connectionsOut" to 0,
            "sessionUplink" to 0L,
            "sessionDownlink" to 0L
        )
    )
    val trafficStats: StateFlow<Map<String, Any>> = _trafficStats
    
    // Session data tracking
    private var sessionStartUidTxBytes = -1L
    private var sessionStartUidRxBytes = -1L
    private var lastUidTxBytes = -1L
    private var lastUidRxBytes = -1L
    private var lastUidTrafficSampleAt = 0L
    private var lastNotificationUpdateAt = 0L
    private var sessionStartedAt = 0L
    private var connectionUiState = ConnectionUiState.disconnected()
    private val vpnNotificationHelper by lazy { VpnNotificationHelper(context) }
    
    // VPN permission request code
    private val VPN_REQUEST_CODE = 24
    private var pendingVpnPermissionResult: Result? = null
    
    // Event sink for status updates
    private var statusEventSink: EventChannel.EventSink? = null
    private var trafficEventSink: EventChannel.EventSink? = null
    private var logEventSink: EventChannel.EventSink? = null
    
    // Log buffer to store recent logs
    private val logBuffer = java.util.LinkedList<String>()
    private val maxLogBufferSize = 500
    
    // Periodic status check
    private fun startPeriodicStatusCheck() {
        if (periodicStatusJob?.isActive == true) {
            return
        }
        periodicStatusJob = coroutineScope.launch {
            while (isActive) {
                try {
                    // Wait 15 seconds between checks
                    kotlinx.coroutines.delay(15000)
                    
                    // If status is Started, verify it's actually running
                    if (_vpnStatus.value == Status.Started) {
                        android.util.Log.e("FlutterSingboxPlugin", "Performing periodic status check")
                        checkServiceStatus()
                    }
                } catch (e: CancellationException) {
                    throw e
                } catch (e: Exception) {
                    android.util.Log.e("FlutterSingboxPlugin", "Error in periodic status check", e)
                }
            }
        }
    }

    // Status broadcast receiver
    private val statusReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action == Action.BROADCAST_STATUS_CHANGED) {
                if (intent.hasExtra(Action.EXTRA_SYSTEM_ALWAYS_ON)) {
                    lastKnownSystemAlwaysOn = intent.getBooleanExtra(Action.EXTRA_SYSTEM_ALWAYS_ON, false)
                }
                val statusOrdinal = intent.getIntExtra(Action.EXTRA_STATUS, Status.Stopped.ordinal)
                val reportedStatus = Status.values().getOrNull(statusOrdinal) ?: return
                val status = if (reportedStatus == Status.Started && !NativeStatusQuery.matchesConfig(
                    intent.getStringExtra(Action.EXTRA_CONFIG_FINGERPRINT), expectedConfigFingerprint(),
                )) Status.Starting else reportedStatus
                val manualDisconnectRequested = if (
                    intent.hasExtra(Action.EXTRA_MANUAL_DISCONNECT_REQUESTED)
                ) {
                    intent.getBooleanExtra(Action.EXTRA_MANUAL_DISCONNECT_REQUESTED, false)
                } else {
                    null
                }
                val sessionReason = intent.getStringExtra(Action.EXTRA_SESSION_REASON)
                val desiredRunning = if (intent.hasExtra(Action.EXTRA_DESIRED_RUNNING)) {
                    intent.getBooleanExtra(Action.EXTRA_DESIRED_RUNNING, false)
                } else {
                    null
                }
                
                android.util.Log.e("FlutterSingboxPlugin", "Received broadcast status change: ${status.name}, isStarting=$isStarting, hasStartupError=$hasStartupError")

                val guardedStatus = VpnStatusResolver.resolveServiceBroadcastStatus(
                    broadcastStatus = status,
                    isShuttingDown = isShuttingDown,
                    isStarting = isStarting,
                    startedByUser = runCatching {
                        SimpleConfigManager.getStartedByUser() || lastKnownSystemAlwaysOn == true
                    }.getOrDefault(false),
                )
                if (guardedStatus != status) {
                    if (guardedStatus == Status.Stopping) {
                        // libbox can publish Stopped before Android has destroyed
                        // the VpnService and released its TUN. Release every client
                        // binding so stopSelf() can finish; the cleanup job owns the
                        // final service check and user-visible Stopped state.
                        android.util.Log.i(
                            "FlutterSingboxPlugin",
                            "Deferring Stopped broadcast until VPN service exit",
                        )
                        statusClient.disconnect()
                        logClient.disconnect()
                        connection.disconnect()
                    } else {
                        // A clean Xray/sing-box process switch emits Stopped from
                        // the old process after the new startup intent is active.
                        android.util.Log.i(
                            "FlutterSingboxPlugin",
                            "Ignoring stale Stopped broadcast during startup",
                        )
                    }
                    _vpnStatus.value = guardedStatus
                    statusInitialized = true
                    sendStatusUpdate(
                        guardedStatus,
                        manualDisconnectRequested = manualDisconnectRequested,
                        sessionReason = sessionReason,
                        desiredRunning = desiredRunning,
                    )
                    return
                }
                
                // Skip if we're shutting down and receive Started status
                if (isShuttingDown && status == Status.Started) {
                    android.util.Log.e("FlutterSingboxPlugin", "Ignoring broadcast status $status during shutdown")
                    return
                }
                
                // If we receive Stopped during startup, mark it as a startup error
                // This handles the case where the alert broadcast hasn't been processed yet
                if (isStarting && status == Status.Stopped) {
                    android.util.Log.e("FlutterSingboxPlugin", "Received Stopped during startup - marking as startup error")
                    hasStartupError = true
                    isStarting = false
                    // Don't return - let the status update flow through
                }

                // Readiness can be confirmed before the delayed service bind
                // finishes. Treat the service's Started broadcast as the
                // authoritative end of startup so a concurrent status poll
                // cannot regress the tunnel back to Starting indefinitely.
                if (status == Status.Started) {
                    isStarting = false
                    hasStartupError = false
                }
                
                // Update the status
                _vpnStatus.value = status
                
                // We've now initialized the status
                statusInitialized = true
                
                // Connect or disconnect clients based on status
                when (status) {
                    Status.Started -> {
                        if (sessionStartedAt == 0L) {
                            sessionStartedAt = System.currentTimeMillis()
                        }
                        connectionUiState = connectionUiState.copy(
                            status = ConnectionStatus.Connected,
                            sessionDuration = currentSessionDuration()
                        )
                        vpnNotificationHelper.updateNotification(connectionUiState)
                        if (!isCurrentXrayRuntime() && !statusClient.isConnected()) {
                            statusClient.connect()
                        }
                        if (!isCurrentXrayRuntime() && logEventSink != null && !logClient.isConnected()) {
                            logClient.connect()
                        }
                    }
                    Status.Stopped -> {
                        sessionStartedAt = 0L
                        connectionUiState = ConnectionUiState.disconnected()
                        if (isShuttingDown) {
                            _vpnStatus.value = Status.Stopping
                            sendStatusUpdate(Status.Stopping)
                            return
                        }
                    }
                    else -> {
                        connectionUiState = connectionUiState.copy(
                            status = if (status == Status.Starting) {
                                ConnectionStatus.Connecting
                            } else {
                                ConnectionStatus.Disconnected
                            }
                        )
                        vpnNotificationHelper.updateNotification(connectionUiState)
                    }
                }
                
                // Send status update via the helper method
                sendStatusUpdate(
                    status,
                    manualDisconnectRequested = manualDisconnectRequested,
                    sessionReason = sessionReason,
                    desiredRunning = desiredRunning,
                )
            }
        }
    }
    
    // Alert broadcast receiver
    private val alertReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action == Action.BROADCAST_ALERT) {
                val alertOrdinal = intent.getIntExtra(Action.EXTRA_ALERT, -1)
                val message = intent.getStringExtra(Action.EXTRA_ALERT_MESSAGE)
                
                // Mark that we had a startup error - this prevents ignoring the Stopped status
                hasStartupError = true
                isStarting = false
                
                // Update status to Stopped since there was an error
                _vpnStatus.value = Status.Stopped
                
                val alertMessage = if (alertOrdinal >= 0 && alertOrdinal < Alert.values().size) {
                    when (Alert.values()[alertOrdinal]) {
                        Alert.EmptyConfiguration -> "Empty configuration"
                        Alert.StartService -> "Failed to start service${if (message?.isNotEmpty() == true) ": $message" else ""}"
                        Alert.CreateService -> "Failed to create service${if (message?.isNotEmpty() == true) ": $message" else ""}"
                        Alert.VpnNoAddress -> "No VPN address configured"
                        else -> "Error: ${if (message?.isNotEmpty() == true) message else "Unknown issue"}"
                    }
                } else {
                    "Unknown error"
                }
                
                // Send alert to Flutter
                val alertMap = mapOf(
                    "type" to "alert",
                    "alert" to alertOrdinal,
                    "message" to alertMessage
                )
                
                val handler = Handler(Looper.getMainLooper())
                handler.post {
                    statusEventSink?.success(alertMap)
                    // Also send the Stopped status update
                    sendStatusUpdate(Status.Stopped)
                }
            }
        }
    }

    override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        android.util.Log.e("FlutterSingboxPlugin", "Plugin attaching to engine")
        context = flutterPluginBinding.applicationContext
        val restoredTraffic = SessionTrafficRepository.initialize(
            context = context,
            restoreActiveSession = SimpleConfigManager.getStartedByUser(context),
        )
        if (restoredTraffic.total > 0L) {
            _trafficStats.value = _trafficStats.value.toMutableMap().apply {
                put("sessionUplink", restoredTraffic.uplink)
                put("sessionDownlink", restoredTraffic.downlink)
                put("sessionTotal", restoredTraffic.total)
                put("formattedSessionUplink", TrafficStats.formatBytes(restoredTraffic.uplink))
                put("formattedSessionDownlink", TrafficStats.formatBytes(restoredTraffic.downlink))
                put("formattedSessionTotal", TrafficStats.formatBytes(restoredTraffic.total))
            }
        }
        
        // Initialize service state
        _vpnStatus.value = Status.Stopped
        
        // Setup method channel
        methodChannel = MethodChannel(flutterPluginBinding.binaryMessenger, "com.tecclub.flutter_singbox/methods")
        methodChannel.setMethodCallHandler(this)
        
        // Setup status event channel
        statusEventChannel = EventChannel(flutterPluginBinding.binaryMessenger, "com.tecclub.flutter_singbox/status_events")
        statusEventChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                android.util.Log.e("FlutterSingboxPlugin", "Status event channel - onListen called")
                statusEventSink = events
                
                // Just send the current status - don't disconnect or cause issues
                coroutineScope.launch {
                    // Check if service is actually running
                    val manager = context.getSystemService(Context.ACTIVITY_SERVICE) as android.app.ActivityManager
                    val isServiceRunning = withContext(Dispatchers.IO) {
                        manager.getRunningServices(Integer.MAX_VALUE).any { 
                            it.service.className.contains("BoxService") || 
                            it.service.className.contains("VPNService")
                        }
                    }
                    
                    if (isServiceRunning) {
                        val inferredStatus = if (isShuttingDown) {
                            Status.Stopping
                        } else {
                            inferredRunningStatus()
                        }
                        _vpnStatus.value = inferredStatus
                        
                        if (inferredStatus == Status.Started && !isCurrentXrayRuntime()) {
                            if (!statusClient.isConnected()) {
                                statusClient.connect()
                            }
                            if (logEventSink != null && !logClient.isConnected()) {
                                logClient.connect()
                            }
                        }
                    } else {
                        // Service is not running
                        _vpnStatus.value = Status.Stopped
                    }
                    
                    // Send current status to Flutter
                    android.util.Log.e("FlutterSingboxPlugin", "Sending initial status: ${_vpnStatus.value}")
                    sendStatusUpdate(_vpnStatus.value)
                }
            }
            
            override fun onCancel(arguments: Any?) {
                android.util.Log.e("FlutterSingboxPlugin", "Status event channel - onCancel called")
                statusEventSink = null
            }
        })
        
        // Setup traffic stats event channel
        trafficEventChannel = EventChannel(flutterPluginBinding.binaryMessenger, "com.tecclub.flutter_singbox/traffic_events")
        trafficEventChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                android.util.Log.e("FlutterSingboxPlugin", "Traffic event channel - onListen called")
                trafficEventSink = events
                events?.success(_trafficStats.value)
                syncXrayTrafficSampler(_vpnStatus.value)
            }
            
            override fun onCancel(arguments: Any?) {
                android.util.Log.e("FlutterSingboxPlugin", "Traffic event channel - onCancel called")
                trafficEventSink = null
            }
        })
        
        // Setup log event channel
        logEventChannel = EventChannel(flutterPluginBinding.binaryMessenger, "com.tecclub.flutter_singbox/log_events")
        logEventChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                android.util.Log.e("FlutterSingboxPlugin", "Log event channel - onListen called")
                logEventSink = events
                
                // Send any buffered logs
                synchronized(logBuffer) {
                    if (logBuffer.isNotEmpty()) {
                        val bufferedLogs = logBuffer.toList()
                        Handler(Looper.getMainLooper()).post {
                            bufferedLogs.forEach { log ->
                                logEventSink?.success(mapOf("type" to "log", "message" to log))
                            }
                        }
                    }
                }
                
                // Connect log client when listener is attached and VPN is running
                if (_vpnStatus.value == Status.Started &&
                    !isCurrentXrayRuntime() &&
                    !logClient.isConnected()
                ) {
                    logClient.connect()
                }
            }
            
            override fun onCancel(arguments: Any?) {
                android.util.Log.e("FlutterSingboxPlugin", "Log event channel - onCancel called")
                logEventSink = null
                logClient.disconnect()
            }
        })
        
        // Initialize Application class once; duplicate libbox setup can destabilize
        // long-running sessions and reconnects.
        Application.initialize(context)
        
        // Register broadcast receivers
        ContextCompat.registerReceiver(
            context,
            statusReceiver,
            IntentFilter(Action.BROADCAST_STATUS_CHANGED),
            ContextCompat.RECEIVER_NOT_EXPORTED,
        )
        ContextCompat.registerReceiver(
            context,
            alertReceiver,
            IntentFilter(Action.BROADCAST_ALERT),
            ContextCompat.RECEIVER_NOT_EXPORTED,
        )
            
        // Initialize status - ensure it's accurate
        checkServiceStatus()
        startPeriodicStatusCheck()
    }
    
    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        android.util.Log.e("FlutterSingboxPlugin", "Plugin detaching from engine")
        
        // Clear event channel handlers
        statusEventChannel.setStreamHandler(null)
        trafficEventChannel.setStreamHandler(null)
        logEventChannel.setStreamHandler(null)
        methodChannel.setMethodCallHandler(null)
        
        // Clear event sinks
        statusEventSink = null
        trafficEventSink = null
        logEventSink = null
        
        // Disconnect from service
        try {
            SessionTrafficRepository.flush()
            periodicStatusJob?.cancel()
            periodicStatusJob = null
            stopXrayTrafficSampler()
            serviceStatusCheckInFlight = false
            connection.disconnect()
            statusClient.disconnect()
            logClient.disconnect()
            android.util.Log.e("FlutterSingboxPlugin", "Disconnected from service during detach")
        } catch (e: Exception) {
            android.util.Log.e("FlutterSingboxPlugin", "Error disconnecting from service during detach", e)
        }
        
        // Unregister receivers
        try {
            context.unregisterReceiver(statusReceiver)
            context.unregisterReceiver(alertReceiver)
            android.util.Log.e("FlutterSingboxPlugin", "Unregistered broadcast receivers during detach")
        } catch (e: Exception) {
            android.util.Log.e("FlutterSingboxPlugin", "Error unregistering receivers during detach", e)
            // Ignore if receivers not registered
        }
        
        // Cancel coroutine scope
        coroutineScope.cancel()
    }
    
    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        binding.addActivityResultListener(this)
        
        // Check if service is already running
        checkServiceStatus()
    }
    
    override fun onDetachedFromActivityForConfigChanges() {
        activity = null
    }
    
    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activity = binding.activity
        binding.addActivityResultListener(this)
    }
    
    override fun onDetachedFromActivity() {
        activity = null
    }
    
    private fun checkServiceStatus() {
        android.util.Log.e("FlutterSingboxPlugin", "Checking service status")
        
        // Don't check if we're shutting down
        if (isShuttingDown) {
            android.util.Log.e("FlutterSingboxPlugin", "Skipping service check - shutting down")
            return
        }
        if (serviceStatusCheckInFlight) {
            android.util.Log.e("FlutterSingboxPlugin", "Skipping service check - already in flight")
            return
        }
        serviceStatusCheckInFlight = true
        val queryGeneration = lifecycleGeneration.get()
        
        coroutineScope.launch {
            try {
                // Check if the VPN service is actually running
                val manager = context.getSystemService(Context.ACTIVITY_SERVICE) as android.app.ActivityManager
                val isServiceRunning = withContext(Dispatchers.IO) {
                    manager.getRunningServices(Integer.MAX_VALUE).any { 
                        it.service.className.contains("BoxService") || 
                        it.service.className.contains("VPNService")
                    }
                }
                
                if (queryGeneration != lifecycleGeneration.get() || isShuttingDown) return@launch
                android.util.Log.e("FlutterSingboxPlugin", "VPN service running check: $isServiceRunning")
                
                if (isServiceRunning) {
                    val inferredStatus = inferredRunningStatus()
                    if (queryGeneration != lifecycleGeneration.get() || isShuttingDown) return@launch
                    _vpnStatus.value = inferredStatus
                    
                    if (inferredStatus == Status.Stopped) {
                        statusClient.disconnect()
                        logClient.disconnect()
                    } else if (inferredStatus == Status.Started && !isCurrentXrayRuntime()) {
                        if (!statusClient.isConnected()) {
                            statusClient.connect()
                        }
                        if (logEventSink != null && !logClient.isConnected()) {
                            logClient.connect()
                        }
                    }
                } else {
                    // Service is not running
                    _vpnStatus.value = Status.Stopped
                    
                    // Disconnect clients to clean up any stale connections
                    statusClient.disconnect()
                    logClient.disconnect()
                }
                
                // Send status update to Flutter
                sendStatusUpdate(_vpnStatus.value)
                statusInitialized = true
                
            } catch (e: Exception) {
                android.util.Log.e("FlutterSingboxPlugin", "Error checking service status: ${e.message}")
            } finally {
                serviceStatusCheckInFlight = false
            }
        }
    }
    
    // Helper method to send status updates to Flutter
    private fun sendStatusUpdate(
        status: Status,
        manualDisconnectRequested: Boolean? = null,
        sessionReason: String? = null,
        desiredRunning: Boolean? = null,
    ) {
        if (status != Status.Started) {
            clearNotificationPing(refresh = status != Status.Stopped)
        }
        syncXrayTrafficSampler(status)
        android.util.Log.e("FlutterSingboxPlugin", "Sending status update to Flutter: ${status.name}")
        val statusMap = currentNetworkSnapshot().toMutableMap()
        statusMap.putAll(mapOf(
            "status" to status.name,
            "statusCode" to status.ordinal
        ))
        (manualDisconnectRequested ?: (if (lastKnownSystemAlwaysOn == true && !isShuttingDown) false else null)
            ?: runCatching { SimpleConfigManager.getManualDisconnectRequested() }.getOrNull())
            ?.let { statusMap["manualDisconnectRequested"] = it }
        sessionReason?.let { statusMap["sessionReason"] = it }
        desiredRunning?.let { statusMap["desiredRunning"] = it }
        
        val handler = Handler(Looper.getMainLooper())
        handler.post {
            statusEventSink?.success(statusMap)
        }
    }

    private suspend fun isVpnServiceRunning(): Boolean = withContext(Dispatchers.IO) {
        val manager = context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        manager.getRunningServices(Integer.MAX_VALUE).any {
            it.service.className.contains("BoxService") ||
                    it.service.className.contains("VPNService")
        }
    }

    private suspend fun killVpnServiceProcess(reason: String, canKill: () -> Boolean): Boolean {
        try {
            val pid = withContext(Dispatchers.IO) {
                val manager = context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
                manager.runningAppProcesses
                    ?.firstOrNull { it.processName == "${context.packageName}:vpn" }?.pid
            } ?: return false
            return withContext(Dispatchers.Main.immediate) {
                if (!canKill()) return@withContext false
                android.util.Log.w("FlutterSingboxPlugin", "Stopping stale VPN process: $reason")
                android.os.Process.killProcess(pid)
                true
            }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            android.util.Log.e("FlutterSingboxPlugin", "Failed to kill VPN service process", e)
            return false
        }
    }

    private fun expectedConfigFingerprint(): String? = runCatching {
        val config = SimpleConfigManager.getConfig()
        config.takeIf { it.isNotBlank() && it != "{}" }?.let(NativeConfigBinding::fingerprint)
    }.getOrNull()

    private suspend fun inferredRunningStatus(): Status {
        val systemOwnsConnection = observeSystemAlwaysOn()
        val queryGeneration = lifecycleGeneration.get()
        val expected = expectedConfigFingerprint()
        val requiresActiveVpnNetwork = isCurrentXrayRuntime()
        val reply = NativeStatusQuery.read(context, expected)
        val nativeStatus = reply.takeIf {
            queryGeneration == lifecycleGeneration.get() && expected == expectedConfigFingerprint()
        }
        val startedByUser = runCatching { SimpleConfigManager.getStartedByUser() }
            .getOrDefault(false)
        if (nativeStatus != null) {
            isStarting = nativeStatus == Status.Starting
            if (nativeStatus == Status.Started) hasStartupError = false
        }
        return VpnStatusResolver.resolveRunningServiceStatus(
            startedByUser = startedByUser,
            isShuttingDown = isShuttingDown,
            nativeStatus = nativeStatus,
            requiresActiveVpnNetwork = requiresActiveVpnNetwork,
            hasActiveVpnNetwork = !requiresActiveVpnNetwork || hasActiveVpnNetwork(),
            systemAlwaysOn = systemOwnsConnection,
        )
    }

    private suspend fun observeSystemAlwaysOn(): Boolean {
        val snapshot = com.tecclub.flutter_singbox.bg.KillSwitchStatus.systemState(context)
        lastKnownSystemAlwaysOn = snapshot?.get("alwaysOn")
        return lastKnownSystemAlwaysOn == true
    }

    private fun isCurrentXrayRuntime(): Boolean =
        runCatching { XrayRuntimeConfig.isXray(SimpleConfigManager.getConfig()) }
            .getOrDefault(false)

    private fun hasActiveVpnNetwork(): Boolean {
        return try {
            val connectivity = context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
            connectivity.allNetworks.any { network ->
                val capabilities = connectivity.getNetworkCapabilities(network) ?: return@any false
                capabilities.hasTransport(NetworkCapabilities.TRANSPORT_VPN) &&
                    capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) &&
                    capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)
            }
        } catch (e: Exception) {
            android.util.Log.w("FlutterSingboxPlugin", "VPN network snapshot failed", e)
            false
        }
    }

    private fun currentNetworkSnapshot(): Map<String, Any> {
        val snapshot = readNetworkSnapshot().toMutableMap()
        val fingerprint = snapshot["fingerprint"]?.toString() ?: "none"
        if (lastNetworkFingerprint.isNotEmpty() && lastNetworkFingerprint != fingerprint) {
            networkGenerationId += 1
            lastNetworkChangedAtMs = System.currentTimeMillis()
            clearNotificationPing(refresh = _vpnStatus.value == Status.Started)
        }
        lastNetworkFingerprint = fingerprint
        snapshot["generation"] = networkGenerationId
        return snapshot
    }

    private fun readNetworkSnapshot(): Map<String, Any> {
        return try {
            val connectivity = context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
            val networks = connectivity.allNetworks
            val candidates = networks
                .mapNotNull { network ->
                    val capabilities = connectivity.getNetworkCapabilities(network) ?: return@mapNotNull null
                    if (!capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)) {
                        return@mapNotNull null
                    }
                    if (capabilities.hasTransport(NetworkCapabilities.TRANSPORT_VPN)) {
                        return@mapNotNull null
                    }
                    val linkProperties = connectivity.getLinkProperties(network)
                    val type = networkType(capabilities)
                    val validated = capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)
                    val metered = !capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED)
                    val score = when (type) {
                        "wifi" -> 40
                        "cellular" -> 35
                        "ethernet" -> 45
                        else -> 20
                    } + if (validated) 10 else 0
                    NetworkSnapshotCandidate(
                        type = type,
                        handle = network.networkHandle,
                        interfaceName = linkProperties?.interfaceName ?: "",
                        validated = validated,
                        metered = metered,
                        score = score
                    )
                }
            val defaultHandle = connectivity.activeNetwork?.networkHandle
            val physicalDefault = candidates.firstOrNull { it.handle == defaultHandle }
            val candidate = physicalDefault ?: candidates.maxByOrNull { it.score }
            val validatedPhysical = candidates.filter { it.validated }

            if (candidate == null) {
                return mapOf(
                    "type" to "none",
                    "interfaceName" to "",
                    "validated" to false,
                    "metered" to false,
                    "probePhysicalNetwork" to "",
                    "fingerprint" to "none"
                )
            }

            val fingerprint = listOf(
                candidate.type,
                candidate.interfaceName,
                candidate.validated,
                candidate.metered
            ).joinToString("|")
            mapOf(
                "type" to candidate.type,
                "interfaceName" to candidate.interfaceName,
                "validated" to candidate.validated,
                "metered" to candidate.metered,
                "probePhysicalNetwork" to candidate.handle.toString(),
                // A VPN can hide the actual underlay from the app process.
                // In that case the score is a hint, not a proven route switch.
                "autoPhysicalRouteConfirmed" to (physicalDefault != null ||
                    (validatedPhysical.size == 1 && validatedPhysical[0] == candidate)),
                "autoValidatedPhysicalKeys" to validatedPhysical.map { it.handle.toString() },
                "fingerprint" to fingerprint
            )
        } catch (e: Exception) {
            android.util.Log.w("FlutterSingboxPlugin", "Network snapshot failed", e)
            mapOf(
                "type" to "unknown",
                "interfaceName" to "",
                "validated" to false,
                "metered" to false,
                "probePhysicalNetwork" to "",
                "fingerprint" to "unknown"
            )
        }
    }

    private fun networkType(capabilities: NetworkCapabilities): String {
        return when {
            capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> "wifi"
            capabilities.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> "cellular"
            capabilities.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> "ethernet"
            capabilities.hasTransport(NetworkCapabilities.TRANSPORT_BLUETOOTH) -> "bluetooth"
            else -> "other"
        }
    }

    private data class NetworkSnapshotCandidate(
        val type: String,
        val handle: Long,
        val interfaceName: String,
        val validated: Boolean,
        val metered: Boolean,
        val score: Int
    )

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            "getPlatformVersion" -> {
                result.success("Android ${android.os.Build.VERSION.RELEASE}")
            }
            "saveConfig" -> {
                val config = call.argument<String>("config") ?: ""
                saveConfig(
                    config, result,
                    managedSmartRoute = call.argument<Boolean>("smartRouteApps") == true,
                    managedHermes = call.argument<Boolean>("hermesManagedXhttp") == true,
                )
            }
            "getConfig" -> {
                getConfig(result)
            }
            "startVPN" -> {
                startVPN(result)
            }
            "stopVPN" -> {
                stopVPN(result)
            }
            "reloadVPN" -> {
                reloadVPN(result)
            }
            "getVPNStatus" -> {
                getVPNStatus(result)
            }
            "getManualDisconnectRequested" -> {
                coroutineScope.launch {
                    result.success(if (observeSystemAlwaysOn()) false else SimpleConfigManager.getManualDisconnectRequested())
                }
            }
            "getNetworkSnapshot" -> {
                result.success(currentNetworkSnapshot())
            }
            "getKillSwitchState" -> {
                coroutineScope.launch {
                    result.success(com.tecclub.flutter_singbox.bg.KillSwitchStatus.query(context))
                }
            }
            "getDirectProbeNetwork" -> {
                coroutineScope.launch {
                    result.success(DirectProbeNetworkGate.read(context))
                }
            }
            "resolveDirectProbeHost" -> {
                val request = call.argument<Number>("request")?.toLong()
                val host = call.argument<String>("host")
                val network = call.argument<String>("network")
                if (request == null || request <= 0 || host == null || network.isNullOrEmpty() ||
                    directProbeDns.size >= 8 || directProbeDns.containsKey(request)) {
                    result.success(null)
                    return
                }
                fun finish(addresses: List<String>?) {
                    if (directProbeDns.remove(request) == null) return
                    result.success(addresses)
                }
                val job = coroutineScope.launch(start = CoroutineStart.LAZY) {
                    finish(DirectProbeNetworkGate.resolve(context, host, network))
                }
                directProbeDns[request] = job
                job.invokeOnCompletion { failure ->
                    if (failure != null) Handler(Looper.getMainLooper()).post { finish(null) }
                }
                job.start()
            }
            "cancelDirectProbeDns" -> {
                call.argument<Number>("request")?.toLong()?.let { directProbeDns[it]?.cancel() }
                result.success(null)
            }
            "initializeSmartRouteInstallDefault" -> {
                coroutineScope.launch {
                    val clean = withContext(Dispatchers.IO) {
                        try {
                            configSaveMutex.withLock {
                                com.tecclub.flutter_singbox.config.SmartRouteApps.initializeInstallDefault(context)
                            }
                        } catch (error: Exception) {
                            if (error is kotlinx.coroutines.CancellationException) throw error
                            false
                        }
                    }
                    result.success(clean)
                }
            }
            "getSmartRouteApps" -> {
                coroutineScope.launch {
                    try {
                        result.success(com.tecclub.flutter_singbox.config.SmartRouteApps.snapshot(context))
                    } catch (error: Exception) {
                        if (error is kotlinx.coroutines.CancellationException) throw error
                        result.error("SMART_ROUTE_APPS_UNAVAILABLE", "App route status unavailable", null)
                    }
                }
            }
            "saveSmartRouteApps" -> {
                val packages = call.argument<List<*>>("packages")
                if (packages == null || packages.size > com.tecclub.flutter_singbox.config.SmartRouteAppPolicy.MAX_CANDIDATES) {
                    result.error("BAD_ARGUMENT", "Invalid Smart Route selection", null)
                    return
                }
                coroutineScope.launch {
                    try {
                        withContext(Dispatchers.IO) {
                            com.tecclub.flutter_singbox.config.SmartRouteApps.saveSelection(context, packages)
                        }
                        result.success(true)
                    } catch (error: Exception) {
                        if (error is kotlinx.coroutines.CancellationException) throw error
                        result.error("SMART_ROUTE_APPS_WRITE_FAILED", "Unable to save app selection", null)
                    }
                }
            }
            "clearSmartRouteAppBinding" -> {
                coroutineScope.launch {
                    try {
                        withContext(Dispatchers.IO) {
                            configSaveMutex.withLock {
                                com.tecclub.flutter_singbox.config.SmartRouteApps.bindManagedConfig(context, null)
                            }
                        }
                        result.success(true)
                    } catch (error: Exception) {
                        if (error is kotlinx.coroutines.CancellationException) throw error
                        result.error("SMART_ROUTE_APPS_WRITE_FAILED", "Unable to revoke app routing", null)
                    }
                }
            }
            "openVpnSettings" -> {
                try {
                    context.startActivity(Intent(android.provider.Settings.ACTION_VPN_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                    result.success(true)
                } catch (_: Exception) {
                    result.error("VPN_SETTINGS_UNAVAILABLE", "Open Android VPN settings manually", null)
                }
            }
            "setKillSwitchRequested" -> {
                val enabled = call.argument<Boolean>("enabled")
                if (enabled == null) {
                    result.error("BAD_ARGUMENT", "Protection intent must be boolean", null)
                    return
                }
                coroutineScope.launch {
                    if (!enabled) {
                        val snapshot = com.tecclub.flutter_singbox.bg.KillSwitchStatus.query(context)
                        if (snapshot["supported"] != false &&
                            (snapshot["known"] != true || snapshot["alwaysOn"] == true || snapshot["lockdown"] == true)) {
                            result.error("ANDROID_PROTECTION_ACTIVE_OR_UNKNOWN", "Disable Android protection first and verify the running VPN", null)
                            return@launch
                        }
                    }
                    try {
                        withContext(Dispatchers.IO) {
                            com.tecclub.flutter_singbox.config.KillSwitchIntentStore.setRequested(context, enabled)
                        }
                        result.success(true)
                    } catch (_: Exception) {
                        result.error("PROTECTION_INTENT_WRITE_FAILED", "Unable to persist protection intent", null)
                    }
                }
            }
            // Per-App Tunneling Methods
            "setPerAppProxyMode" -> {
                val mode = call.argument<String>("mode") ?: Settings.PER_APP_PROXY_OFF
                setPerAppProxyMode(mode, result)
            }
            "getPerAppProxyMode" -> {
                getPerAppProxyMode(result)
            }
            "setPerAppProxyList" -> {
                val appList = call.argument<List<String>>("appList") ?: emptyList()
                setPerAppProxyList(appList, result)
            }
            "getPerAppProxyList" -> {
                getPerAppProxyList(result)
            }
            "getInstalledApps" -> {
                getInstalledApps(result)
            }
            "getLogs" -> {
                getLogs(result)
            }
            "clearLogs" -> {
                clearLogBuffer(result)
            }
            "setNotificationTitle" -> {
                val title = call.argument<String>("title") ?: "Yurich Connect"
                setNotificationTitle(title, result)
            }
            "setNotificationDescription" -> {
                val description = call.argument<String>("description") ?: "Connected"
                setNotificationDescription(description, result)
            }
            "updateConnectionNotification" -> {
                val state = call.argument<Map<String, Any?>>("state")
                updateConnectionNotification(state, result)
            }
            "requestNotificationPermission" -> {
                requestNotificationPermission(result)
            }
            "showAppNotification" -> {
                val title = call.argument<String>("title") ?: "Yurich Connect"
                val body = call.argument<String>("body") ?: ""
                val id = call.argument<Int>("id") ?: 7001
                showAppNotification(title, body, id, result)
            }
            "getNotificationTitle" -> {
                getNotificationTitle(result)
            }
            "getNotificationDescription" -> {
                getNotificationDescription(result)
            }
            else -> {
                result.notImplemented()
            }
        }
    }

    private fun setNotificationTitle(title: String, result: Result) {
        try {
            SimpleConfigManager.setNotificationTitle(title)
            result.success(true)
        } catch (e: Exception) {
            result.error("NOTIFICATION_ERROR", e.message, null)
        }
    }
    
    private fun setNotificationDescription(description: String, result: Result) {
        try {
            SimpleConfigManager.setNotificationDescription(description)
            result.success(true)
        } catch (e: Exception) {
            result.error("NOTIFICATION_ERROR", e.message, null)
        }
    }
    
    private fun getNotificationTitle(result: Result) {
        try {
            val title = SimpleConfigManager.getNotificationTitle()
            result.success(title)
        } catch (e: Exception) {
            result.error("NOTIFICATION_ERROR", e.message, null)
        }
    }
    
    private fun getNotificationDescription(result: Result) {
        try {
            val description = SimpleConfigManager.getNotificationDescription()
            result.success(description)
        } catch (e: Exception) {
            result.error("NOTIFICATION_ERROR", e.message, null)
        }
    }

    private fun updateConnectionNotification(state: Map<*, *>?, result: Result) {
        try {
            val nativeStatus = _vpnStatus.value
            val requestedState = ConnectionUiState.fromMap(state)
            val resolvedStatus = ConnectionNotificationStatusPolicy.resolve(
                requestedStatus = requestedState.status,
                nativeStatus = nativeStatus,
            )
            if (requestedState.status != resolvedStatus) {
                android.util.Log.w(
                    "FlutterSingboxPlugin",
                    "Ignoring stale notification status ${requestedState.status}; native=$nativeStatus",
                )
            }
            val observedAt = requestedState.pingObservedAtMs
            val keepPing = nativeStatus == Status.Started && resolvedStatus == ConnectionStatus.Connected &&
                observedAt != null && observedAt >= lastNetworkChangedAtMs
            connectionUiState = requestedState.copy(
                status = resolvedStatus,
                pingMs = requestedState.pingMs.takeIf { keepPing },
                pingObservedAtMs = requestedState.pingObservedAtMs.takeIf { keepPing },
            )
            requestedState.profileName
                ?.takeIf { it.isNotBlank() }
                ?.let(SimpleConfigManager::setActiveProfileName)
            if (nativeStatus != Status.Stopped) {
                vpnNotificationHelper.updateNotification(connectionUiState)
            }
            result.success(true)
        } catch (e: Exception) {
            result.error("NOTIFICATION_UPDATE_ERROR", e.message, null)
        }
    }

    private fun clearNotificationPing(refresh: Boolean) {
        if (connectionUiState.pingMs == null && connectionUiState.pingObservedAtMs == null) return
        connectionUiState = connectionUiState.copy(pingMs = null, pingObservedAtMs = null)
        if (refresh) runCatching { vpnNotificationHelper.updateNotification(connectionUiState) }
    }

    private fun requestNotificationPermission(result: Result) {
        try {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
                result.success(true)
                return
            }

            if (NotificationManagerCompat.from(context).areNotificationsEnabled()) {
                result.success(true)
                return
            }

            val currentActivity = activity
            if (currentActivity == null) {
                result.success(false)
                return
            }

            ActivityCompat.requestPermissions(
                currentActivity,
                arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                25
            )
            result.success(false)
        } catch (e: Exception) {
            result.error("NOTIFICATION_PERMISSION_ERROR", e.message, null)
        }
    }

    private fun showAppNotification(title: String, body: String, id: Int, result: Result) {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
                ContextCompat.checkSelfPermission(
                    context,
                    Manifest.permission.POST_NOTIFICATIONS
                ) != PackageManager.PERMISSION_GRANTED
            ) {
                result.success(false)
                return
            }

            ensureAppAlertChannel()

            val launchIntent = context.packageManager
                .getLaunchIntentForPackage(context.packageName)
                ?.apply {
                    flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
                }

            val pendingIntent = launchIntent?.let {
                PendingIntent.getActivity(
                    context,
                    7001,
                    it,
                    PendingIntent.FLAG_UPDATE_CURRENT or
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                            PendingIntent.FLAG_IMMUTABLE
                        } else {
                            0
                        }
                )
            }

            val notification = NotificationCompat.Builder(context, APP_ALERT_CHANNEL_ID)
                .setSmallIcon(R.drawable.ic_notification_shield)
                .setContentTitle(title)
                .setContentText(body)
                .setStyle(NotificationCompat.BigTextStyle().bigText(body))
                .setPriority(NotificationCompat.PRIORITY_DEFAULT)
                .setAutoCancel(true)
                .apply {
                    if (pendingIntent != null) {
                        setContentIntent(pendingIntent)
                    }
                }
                .build()

            NotificationManagerCompat.from(context).notify(id, notification)
            result.success(true)
        } catch (e: Exception) {
            result.error("APP_NOTIFICATION_ERROR", e.message, null)
        }
    }

    private fun ensureAppAlertChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return
        }

        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (manager.getNotificationChannel(APP_ALERT_CHANNEL_ID) != null) {
            return
        }

        val channel = NotificationChannel(
            APP_ALERT_CHANNEL_ID,
            "Yurich Connect Alerts",
            NotificationManager.IMPORTANCE_DEFAULT
        ).apply {
            description = "Subscription and account reminders"
        }
        manager.createNotificationChannel(channel)
    }
    
    @Volatile private var configContent: String? = null
    @Volatile private var hermesSavedFingerprint: String? = null
    
    private fun saveConfig(
        config: String,
        result: Result,
        managedSmartRoute: Boolean = false,
        managedHermes: Boolean = false,
    ) {
        com.tecclub.flutter_singbox.config.RuntimeTlsPolicy.validationError(config)?.let { error ->
            result.error("CONFIG_TLS_POLICY", error, null)
            return
        }
        android.util.Log.e("FlutterSingboxPlugin", "Saving config: ${config.length} bytes")
        val generation = configSaveGeneration.incrementAndGet()
        hermesSavedFingerprint = null
        if (!SimpleConfigManager.cacheConfig(config)) {
            result.error("CONFIG_SAVE_FAILED", "Configuration is empty", null)
            return
        }
        configContent = config

        coroutineScope.launch(Dispatchers.IO) {
            try {
                var superseded = false
                val success = configSaveMutex.withLock {
                    if (generation != configSaveGeneration.get()) {
                        superseded = true
                        false
                    } else {
                        // Bind opt-ins out of band. Raw configs and saved profile
                        // JSON never receive a new field or an extra exclusion.
                        com.tecclub.flutter_singbox.config.SmartRouteApps.bindManagedConfig(context, null)
                        val persisted = SimpleConfigManager.persistConfig(config)
                        if (persisted && managedSmartRoute &&
                            Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q &&
                            generation == configSaveGeneration.get()
                        ) {
                            val fingerprint = com.tecclub.flutter_singbox.bg.NativeConfigBinding.fingerprint(config)
                            com.tecclub.flutter_singbox.config.SmartRouteApps.bindManagedConfig(context, fingerprint)
                        }
                        persisted
                    }
                }
                android.util.Log.e("FlutterSingboxPlugin", "Config save result: $success")
                withContext(Dispatchers.Main) {
                    if (superseded || generation != configSaveGeneration.get()) {
                        result.error(
                            "CONFIG_SAVE_SUPERSEDED",
                            "A newer runtime configuration replaced this save",
                            null,
                        )
                    } else if (success) {
                        if (managedHermes && com.tecclub.flutter_singbox.diagnostics.HermesPilotGate.enabled(context)) {
                            hermesSavedFingerprint = com.tecclub.flutter_singbox.bg.NativeConfigBinding.fingerprint(config)
                        }
                        result.success(true)
                    } else {
                        result.error("CONFIG_SAVE_FAILED", "Failed to save configuration", null)
                    }
                }
            } catch (e: Exception) {
                android.util.Log.e("FlutterSingboxPlugin", "Error saving config: ${e.message}", e)
                withContext(Dispatchers.Main) {
                    result.error("CONFIG_SAVE_ERROR", e.message, null)
                }
            }
        }
    }
    
    private fun getConfig(result: Result) {
        coroutineScope.launch {
            try {
                val config = SimpleConfigManager.getConfig()
                result.success(config)
            } catch (e: Exception) {
                result.error("CONFIG_GET_ERROR", e.message, null)
            }
        }
    }
    
    private fun startVPN(result: Result) {
        if (!VpnStopLifecyclePolicy.canStart(isShuttingDown)) {
            result.error("STOP_IN_PROGRESS", "The previous VPN runtime has not stopped yet", null)
            return
        }
        // Android returns permission results using a fixed request code. A
        // cancelled dialog must finish before another start can reuse it.
        if (pendingVpnPermissionGeneration != 0L) {
            result.error("VPN_PERMISSION_PENDING", "A VPN permission request is still open", null)
            return
        }
        val currentActivity = activity
        if (currentActivity == null) {
            result.error("ACTIVITY_UNAVAILABLE", "Activity is not available", null)
            return
        }
        val generation = lifecycleGeneration.incrementAndGet()
        try {
            val permission = VpnService.prepare(currentActivity)
            if (permission == null) {
                startVPNService(result, generation)
            } else {
                requestVpnPermission(currentActivity, permission, generation, result)
            }
        } catch (_: Exception) {
            result.error("START_VPN_ERROR", "Unable to prepare Android VPN", null)
        }
    }

    private fun requestVpnPermission(activity: Activity, intent: Intent, generation: Long, result: Result) {
        pendingVpnPermissionResult = result
        pendingVpnPermissionGeneration = generation
        try {
            activity.startActivityForResult(intent, VPN_REQUEST_CODE)
        } catch (error: Exception) {
            pendingVpnPermissionResult = null
            pendingVpnPermissionGeneration = 0L
            throw error
        }
    }

    private fun canDispatchStart(generation: Long): Boolean =
        VpnStopLifecyclePolicy.canDispatchStart(generation, lifecycleGeneration.get(), isShuttingDown)

    private fun reportCancelledStart(result: Result) {
        result.error("START_CANCELLED", "A newer VPN lifecycle operation replaced this start", null)
    }

    private fun attachHermesSource(intent: Intent, config: String) {
        val fingerprint = hermesSavedFingerprint ?: return
        if (fingerprint == com.tecclub.flutter_singbox.bg.NativeConfigBinding.fingerprint(config)) {
            intent.putExtra(com.tecclub.flutter_singbox.diagnostics.HermesPilotGate.EXTRA_MANAGED_CONFIG, fingerprint)
        }
    }

    private fun startVPNService(result: Result, generation: Long) {
        coroutineScope.launch {
            if (!canDispatchStart(generation)) {
                reportCancelledStart(result)
                return@launch
            }
            try {
                val config = configContent?.takeIf { it.isNotBlank() && it != "{}" }
                    ?: withContext(Dispatchers.IO) { SimpleConfigManager.getConfig() }
                if (!canDispatchStart(generation)) {
                    reportCancelledStart(result)
                    return@launch
                }
                val isXrayRuntime = runCatching { XrayRuntimeConfig.isXray(config) }.getOrDefault(false)
                if (isXrayRuntime && !hasActiveVpnNetwork() && isVpnServiceRunning()) {
                    val killed = killVpnServiceProcess("pre-start stale Xray service without active VPN") {
                        canDispatchStart(generation) && !hasActiveVpnNetwork()
                    }
                    if (killed) {
                        val deadline = SystemClock.elapsedRealtime() + 1500
                        while (canDispatchStart(generation) &&
                            SystemClock.elapsedRealtime() < deadline && isVpnServiceRunning()
                        ) {
                            kotlinx.coroutines.delay(150)
                        }
                    }
                }
                // Check after I/O. Nothing below may suspend between this
                // check and dispatch: stopVPN uses the same main thread.
                if (!canDispatchStart(generation)) {
                    reportCancelledStart(result)
                    return@launch
                }
                val permission = if (Settings.serviceMode == ServiceMode.VPN) VpnService.prepare(context) else null
                if (permission != null) {
                    val currentActivity = activity
                    if (currentActivity == null) {
                        result.error("ACTIVITY_UNAVAILABLE", "Activity is not available", null)
                    } else {
                        requestVpnPermission(currentActivity, permission, generation, result)
                    }
                    return@launch
                }
                val commandToken = VpnCommandFence.issue(context, VpnCommandFence.Kind.Start)
                val intent = Intent(context, Settings.serviceClass()).apply {
                    action = BoxService.ACTION_START
                    putExtra(VpnCommandFence.EXTRA_TOKEN, commandToken)
                    putExtra(BoxService.EXTRA_CONFIG_CONTENT, config)
                    putExtra(
                        com.tecclub.flutter_singbox.config.RuntimeTlsPolicy.INTENT_REVISION_EXTRA,
                        com.tecclub.flutter_singbox.config.RuntimeTlsPolicy.CURRENT_REVISION,
                    )
                    putExtra(Action.EXTRA_USER_INITIATED, true)
                }
                attachHermesSource(intent, config)
                stopCleanupJob?.cancel()
                stopCleanupJob = null
                stopCleanupCompleted = false
                isStarting = true
                hasStartupError = false
                _vpnStatus.value = Status.Starting
                connectionUiState = connectionUiState.copy(
                    status = ConnectionStatus.Connecting,
                    uploadSpeed = "0 B/s",
                    downloadSpeed = "0 B/s",
                    sessionDuration = null,
                    pingMs = null,
                    pingObservedAtMs = null,
                )
                vpnNotificationHelper.updateNotification(connectionUiState)
                SimpleConfigManager.setStartedByUser(true)
                SimpleConfigManager.setManualDisconnectRequested(false)
                resetSessionTrafficCounters()
                checkNotNull(ContextCompat.startForegroundService(context, intent))
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (error: Exception) {
                if (canDispatchStart(generation)) {
                    isStarting = false
                    SimpleConfigManager.setStartedByUser(false)
                    _vpnStatus.value = Status.Stopped
                }
                android.util.Log.e("FlutterSingboxPlugin", "VPN start dispatch failed: " + error.javaClass.simpleName)
                result.error("START_VPN_ERROR", "Unable to start Android VPN service", null)
                return@launch
            }
            // Acknowledges Android dispatch only, not tunnel readiness.
            result.success(true)
            sendStatusUpdate(Status.Starting)
            kotlinx.coroutines.delay(1500)
            if (!canDispatchStart(generation)) return@launch
            if (hasStartupError) {
                isStarting = false
                return@launch
            }
            connection.connect()
            kotlinx.coroutines.delay(500)
            if (canDispatchStart(generation)) isStarting = false
        }
    }

    private fun reloadVPN(result: Result) {
        val requestedGeneration = lifecycleGeneration.get()
        coroutineScope.launch {
            try {
                if (isShuttingDown || !isVpnServiceRunning()) {
                    result.success(false)
                    return@launch
                }
                if (!canDispatchStart(requestedGeneration)) {
                    reportCancelledStart(result)
                    return@launch
                }
                val generation = lifecycleGeneration.incrementAndGet()

                val config = configContent?.takeIf { it.isNotBlank() && it != "{}" }
                    ?: withContext(Dispatchers.IO) { SimpleConfigManager.getConfig() }
                if (!canDispatchStart(generation)) {
                    reportCancelledStart(result)
                    return@launch
                }
                val commandToken = VpnCommandFence.issue(context, VpnCommandFence.Kind.Start)
                val reloadIntent = RuntimeConfigReload.attach(
                    Intent(Action.SERVICE_RELOAD).apply {
                        `package` = context.packageName
                        putExtra(VpnCommandFence.EXTRA_TOKEN, commandToken)
                        putExtra(Action.EXTRA_USER_INITIATED, true)
                    },
                    config,
                )
                attachHermesSource(reloadIntent, config)

                SimpleConfigManager.setStartedByUser(true)
                SimpleConfigManager.setManualDisconnectRequested(false)
                isStarting = true
                hasStartupError = false
                resetSessionTrafficCounters()
                _vpnStatus.value = Status.Starting
                sendStatusUpdate(Status.Starting)
                context.sendBroadcast(reloadIntent)
                result.success(true)
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (e: Exception) {
                android.util.Log.e("FlutterSingboxPlugin", "Error reloading VPN", e)
                result.error("RELOAD_VPN_ERROR", e.message, null)
            }
        }
    }

    private fun sendVpnClose(commandToken: String?) {
        context.sendBroadcast(Intent(Action.SERVICE_CLOSE).apply {
            `package` = context.packageName
            putExtra(Action.EXTRA_USER_INITIATED, true)
            commandToken?.let { putExtra(VpnCommandFence.EXTRA_TOKEN, it) }
        })
    }

    private fun stopVPN(result: Result) {
        if (VpnStopLifecyclePolicy.canJoinStop(isShuttingDown, activeStopGeneration,
                lifecycleGeneration.get(), stopCleanupJob?.isActive == true)) {
            // Stop acknowledges a request, not the cleanup. Keep the original
            // deadline instead of extending it on a profile replacement.
            result.success(true)
            return
        }
        try {
            android.util.Log.e("FlutterSingboxPlugin", "Stopping VPN")
            val generation = lifecycleGeneration.incrementAndGet()
            activeStopGeneration = generation
            // Even when durable invalidation is unavailable, request normal
            // cleanup; the caller must not be told that fencing succeeded.
            val commandToken = runCatching { VpnCommandFence.issue(context, VpnCommandFence.Kind.Stop) }.getOrNull()
            val stoppedDuringStartup = _vpnStatus.value == Status.Starting
            // A start acknowledged by Android may not have installed the
            // service-side close receiver yet. Allow the first cleanup poll
            // to observe it and reissue close rather than trusting a transient
            // absence or waiting the entire graceful timeout.
            earliestStopConfirmationAt = if (stoppedDuringStartup) SystemClock.elapsedRealtime() + 250 else 0L
            
            // Set shutting down flag and clear starting flag
            isShuttingDown = true
            stopCleanupCompleted = false
            isStarting = false
            val permissionWaiter = pendingVpnPermissionResult
            pendingVpnPermissionResult = null
            permissionWaiter?.let(::reportCancelledStart)
            SimpleConfigManager.setStartedByUser(false)
            SimpleConfigManager.setManualDisconnectRequested(true)
            stopCleanupJob?.cancel()
            stopCleanupJob = null
            
            // Update status to Stopping
            _vpnStatus.value = Status.Stopping
            
            // Immediately send stopping status update to Flutter
            sendStatusUpdate(Status.Stopping)
            
            // Send broadcast to stop the service
            // NOTE: Do NOT disconnect immediately - let the service complete its cleanup first
            // The broadcast receiver will handle status updates, and we'll disconnect after
            // the service is confirmed stopped
            android.util.Log.e("FlutterSingboxPlugin", "Sending SERVICE_CLOSE broadcast")
            sendVpnClose(commandToken)

            if (commandToken == null) {
                result.error("STOP_VPN_ERROR", "VPN stop requested; durable cancellation was not confirmed", null)
            } else {
                result.success(true)
            }
            
            // Wait for service to stop before disconnecting
            // The service will broadcast Status.Stopped when it's done cleaning up
            // Store the job so it can be cancelled if user starts VPN again quickly
            stopCleanupJob = coroutineScope.launch {
                try {
                    android.util.Log.e("FlutterSingboxPlugin", "Waiting for service to stop...")

                    val deadline = SystemClock.elapsedRealtime() +
                        VpnStopLifecyclePolicy.GRACEFUL_TIMEOUT_MS
                    var running = true
                    var resentStartupClose = false
                    while (SystemClock.elapsedRealtime() < deadline) {
                        kotlinx.coroutines.delay(250)

                        if (stopCleanupCompleted) {
                            android.util.Log.e("FlutterSingboxPlugin", "Stop cleanup finished by status broadcast")
                            return@launch
                        }

                        // Check if we're still shutting down (might have been cancelled by startVPN)
                        if (!isShuttingDown || generation != lifecycleGeneration.get()) {
                            android.util.Log.e("FlutterSingboxPlugin", "Stop cleanup cancelled")
                            return@launch
                        }

                        running = isVpnServiceRunning()
                        if (!isShuttingDown || generation != lifecycleGeneration.get()) return@launch
                        if (!running) {
                            break
                        }
                        if (stoppedDuringStartup && !resentStartupClose) {
                            sendVpnClose(commandToken)
                            resentStartupClose = true
                        }
                    }

                    if (running) {
                        android.util.Log.e("FlutterSingboxPlugin", "Service still running after graceful stop, requesting stopService")
                        sendVpnClose(commandToken)
                        context.stopService(Intent(context, Settings.serviceClass()))
                        val forceDeadline = SystemClock.elapsedRealtime() +
                            VpnStopLifecyclePolicy.FORCE_STOP_TIMEOUT_MS
                        while (SystemClock.elapsedRealtime() < forceDeadline) {
                            kotlinx.coroutines.delay(250)
                            running = isVpnServiceRunning()
                            if (!isShuttingDown || generation != lifecycleGeneration.get()) return@launch
                            if (!running) {
                                break
                            }
                        }
                    }

                    if (running) {
                        val killed = killVpnServiceProcess("forced stop after graceful stop timeout") {
                            isShuttingDown && generation == lifecycleGeneration.get()
                        }
                        if (!isShuttingDown || generation != lifecycleGeneration.get()) return@launch
                        if (killed) {
                            val killDeadline = SystemClock.elapsedRealtime() +
                                VpnStopLifecyclePolicy.PROCESS_EXIT_CONFIRM_TIMEOUT_MS
                            while (SystemClock.elapsedRealtime() < killDeadline) {
                                kotlinx.coroutines.delay(150)
                                running = isVpnServiceRunning()
                                if (!isShuttingDown || generation != lifecycleGeneration.get()) return@launch
                                if (!running) {
                                    break
                                }
                            }
                        }
                    }

                    if (VpnStopLifecyclePolicy.canFinalize(running)) {
                        completeStopCleanup(
                            "cleanup-job service absent",
                            generation = generation,
                            cancelJob = false,
                            serviceRunning = false,
                        )
                    } else {
                        android.util.Log.e(
                            "FlutterSingboxPlugin",
                            "VPN service still running after bounded stop; keeping Stopping",
                        )
                        _vpnStatus.value = Status.Stopping
                        sendStatusUpdate(Status.Stopping)
                        stopCleanupJob = null
                    }
                } catch (e: CancellationException) {
                    android.util.Log.e(
                        "FlutterSingboxPlugin",
                        "Stop cleanup job cancelled"
                    )
                    if (generation == activeStopGeneration) stopCleanupJob = null
                } catch (e: Exception) {
                    android.util.Log.e("FlutterSingboxPlugin", "Error during stop cleanup: ${e.message}", e)
                    if (isShuttingDown && generation == lifecycleGeneration.get()) {
                        _vpnStatus.value = Status.Stopping
                        sendStatusUpdate(Status.Stopping)
                        stopCleanupJob = null
                    }
                }
            }
        } catch (e: Exception) {
            android.util.Log.e("FlutterSingboxPlugin", "Error stopping VPN", e)
            
            // A failed stop request is not proof that the native runtime exited.
            // Keep the lifecycle closed to new starts until service absence is
            // observed by cleanup or an explicit status query.
            isShuttingDown = true
            _vpnStatus.value = Status.Stopping
            sendStatusUpdate(Status.Stopping)
            
            result.error("STOP_VPN_ERROR", e.message, null)
        }
    }

    private fun completeStopCleanup(
        reason: String,
        generation: Long = activeStopGeneration,
        cancelJob: Boolean = true,
        serviceRunning: Boolean,
    ) {
        if (!VpnStopLifecyclePolicy.canFinalize(serviceRunning)) {
            android.util.Log.w(
                "FlutterSingboxPlugin",
                "Refusing to publish Stopped while VPN service is still running",
            )
            return
        }
        if (stopCleanupCompleted ||
            generation == 0L ||
            generation != activeStopGeneration ||
            generation != lifecycleGeneration.get() ||
            SystemClock.elapsedRealtime() < earliestStopConfirmationAt
        ) {
            return
        }
        stopCleanupCompleted = true
        android.util.Log.e("FlutterSingboxPlugin", "Completing stop cleanup: $reason")

        sessionStartedAt = 0L
        statusClient.disconnect()
        logClient.disconnect()
        connection.disconnect()
        connectionUiState = ConnectionUiState.disconnected()
        _trafficStats.value = mapOf<String, Any>(
            "uplinkSpeed" to 0L,
            "downlinkSpeed" to 0L,
            "uplinkTotal" to 0L,
            "downlinkTotal" to 0L,
            "connectionsIn" to 0,
            "connectionsOut" to 0,
            "sessionUplink" to 0L,
            "sessionDownlink" to 0L,
            "sessionTotal" to 0L,
            "formattedUplinkSpeed" to "0 B/s",
            "formattedDownlinkSpeed" to "0 B/s",
            "formattedUplinkTotal" to "0 B",
            "formattedDownlinkTotal" to "0 B",
            "formattedSessionUplink" to "0 B",
            "formattedSessionDownlink" to "0 B",
            "formattedSessionTotal" to "0 B"
        )
        resetUidTrafficSession()
        SessionTrafficRepository.reset(context)
        _vpnStatus.value = Status.Stopped
        sendStatusUpdate(Status.Stopped)
        isShuttingDown = false

        val cleanupJob = stopCleanupJob
        stopCleanupJob = null
        if (cancelJob) {
            cleanupJob?.cancel()
        }

        android.util.Log.e("FlutterSingboxPlugin", "VPN stopped successfully")
    }
    
    private fun getVPNStatus(result: Result) {
        android.util.Log.e("FlutterSingboxPlugin", "getVPNStatus called")
        
        coroutineScope.launch {
            try {
                val queryGeneration = lifecycleGeneration.get()
                // Check if the VPN service is actually running
                val manager = context.getSystemService(Context.ACTIVITY_SERVICE) as android.app.ActivityManager
                val isServiceRunning = withContext(Dispatchers.IO) {
                    manager.getRunningServices(Integer.MAX_VALUE).any { 
                        it.service.className.contains("BoxService") || 
                        it.service.className.contains("VPNService")
                    }
                }
                if (queryGeneration != lifecycleGeneration.get()) {
                    result.success(_vpnStatus.value.name)
                    return@launch
                }
                
                android.util.Log.e("FlutterSingboxPlugin", "VPN service running check in getVPNStatus: $isServiceRunning")
                
                if (isServiceRunning) {
                    if (isShuttingDown) {
                        android.util.Log.e(
                            "FlutterSingboxPlugin",
                            "Service is shutting down in getVPNStatus; reporting Stopping"
                        )
                        _vpnStatus.value = Status.Stopping
                        result.success(Status.Stopping.name)
                        sendStatusUpdate(Status.Stopping)
                        statusInitialized = true
                        return@launch
                    }
                    val inferredStatus = inferredRunningStatus()
                    if (queryGeneration != lifecycleGeneration.get()) {
                        result.success(_vpnStatus.value.name)
                        return@launch
                    }
                    _vpnStatus.value = inferredStatus
                    
                    if (inferredStatus == Status.Stopped) {
                        statusClient.disconnect()
                        logClient.disconnect()
                    } else if (inferredStatus == Status.Started && !isCurrentXrayRuntime()) {
                        if (!statusClient.isConnected()) {
                            statusClient.connect()
                        }
                        if (logEventSink != null && !logClient.isConnected()) {
                            logClient.connect()
                        }
                    }
                } else {
                    // Service is not running
                    if (isShuttingDown) {
                        completeStopCleanup(
                            reason = "status-query service absent",
                            generation = activeStopGeneration,
                            serviceRunning = false,
                        )
                    } else {
                        _vpnStatus.value = Status.Stopped
                    }
                }
                
                // Return the current status
                result.success(_vpnStatus.value.name)
                
                // Queries are intentionally side-effect free. Real status changes
                // are delivered by service callbacks and reconciliation checks.
                statusInitialized = true
            } catch (e: Exception) {
                android.util.Log.e("FlutterSingboxPlugin", "Error checking VPN status", e)
                result.success(_vpnStatus.value.name) // Return current status as fallback
            }
        }
    }
    
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != VPN_REQUEST_CODE) return false
        val result = pendingVpnPermissionResult
        val generation = pendingVpnPermissionGeneration
        pendingVpnPermissionResult = null
        pendingVpnPermissionGeneration = 0L
        if (result == null) return true

        when {
            !canDispatchStart(generation) -> reportCancelledStart(result)
            resultCode == Activity.RESULT_OK -> startVPNService(result, generation)
            else -> result.error("VPN_PERMISSION_DENIED", "VPN permission denied", null)
        }
        return true
    }

    // ServiceConnection.Callback implementation
    override fun onServiceStatusChanged(status: Status) {
        android.util.Log.e("FlutterSingboxPlugin", "onServiceStatusChanged: ${status.name}, hasStartupError=$hasStartupError")
        val guarded = VpnStatusResolver.resolveServiceBroadcastStatus(
            broadcastStatus = status,
            isShuttingDown = isShuttingDown,
            isStarting = isStarting,
            startedByUser = runCatching { SimpleConfigManager.getStartedByUser() || lastKnownSystemAlwaysOn == true }.getOrDefault(false),
        )
        if (guarded != status) {
            _vpnStatus.value = guarded
            sendStatusUpdate(guarded)
            return
        }
        
        // Skip if we're shutting down and receive Started status
        if (isShuttingDown && status == Status.Started) {
            android.util.Log.e("FlutterSingboxPlugin", "Ignoring status $status during shutdown")
            return
        }
        
        // Skip if there was a startup error and we receive Started status
        // This prevents reporting Started when the service actually failed
        if (hasStartupError && status == Status.Started) {
            android.util.Log.e("FlutterSingboxPlugin", "Ignoring status $status because hasStartupError=true")
            return
        }
        
        // If we receive Stopped during startup, mark it as a startup error
        if (isStarting && status == Status.Stopped) {
            android.util.Log.e("FlutterSingboxPlugin", "Received Stopped during startup - marking as startup error")
            hasStartupError = true
            isStarting = false
            // Don't return - let the status update flow through
        }
        
        // Update the status immediately
        _vpnStatus.value = status
        
        // Connect or disconnect status client based on connection state
        when (status) {
            Status.Started -> {
                android.util.Log.e("FlutterSingboxPlugin", "Service started, connecting status client")
                if (sessionStartedAt == 0L) {
                    sessionStartedAt = System.currentTimeMillis()
                }
                connectionUiState = connectionUiState.copy(
                    status = ConnectionStatus.Connected,
                    uploadSpeed = "0 B/s",
                    downloadSpeed = "0 B/s",
                    totalTraffic = "0 B",
                    sessionDuration = "00:00:00"
                )
                vpnNotificationHelper.updateNotification(connectionUiState)
                
                // Connect status client if not already connected
                if (!isCurrentXrayRuntime() && !statusClient.isConnected()) {
                    statusClient.connect()
                }
                
                // Also connect log client if there's a listener and not already connected
                if (!isCurrentXrayRuntime() && logEventSink != null && !logClient.isConnected()) {
                    logClient.connect()
                }
                
            }
            Status.Stopped -> {
                android.util.Log.e("FlutterSingboxPlugin", "Service stopped, disconnecting status client")
                sessionStartedAt = 0L
                statusClient.disconnect()
                logClient.disconnect()
                connectionUiState = ConnectionUiState.disconnected()
                
                // Reset traffic stats when stopped
                _trafficStats.value = mapOf<String, Any>(
                    "uplinkSpeed" to 0L,
                    "downlinkSpeed" to 0L,
                    "uplinkTotal" to 0L,
                    "downlinkTotal" to 0L,
                    "connectionsIn" to 0,
                    "connectionsOut" to 0,
                    "sessionUplink" to 0L,
                    "sessionDownlink" to 0L,
                    "sessionTotal" to 0L,
                    "formattedUplinkSpeed" to "0 B/s",
                    "formattedDownlinkSpeed" to "0 B/s",
                    "formattedUplinkTotal" to "0 B",
                    "formattedDownlinkTotal" to "0 B",
                    "formattedSessionUplink" to "0 B",
                    "formattedSessionDownlink" to "0 B",
                    "formattedSessionTotal" to "0 B"
                )
                resetUidTrafficSession()
                if (!SimpleConfigManager.getStartedByUser(context) && lastKnownSystemAlwaysOn != true) {
                    SessionTrafficRepository.reset(context)
                }
            }
            else -> {
                // Starting or Stopping - no action needed
            }
        }
        
        // We've now initialized the status
        statusInitialized = true
        
        // Send status update via the helper method (only once)
        sendStatusUpdate(status)
    }
    
    override fun onServiceAlert(type: Alert, message: String?) {
        // Alert is handled by the alertReceiver
    }
    
    // StatusClient.Handler implementation
    override fun onStatusUpdate(status: StatusMessage) {
        if (!SessionTrafficAccumulator.shouldCollect(_vpnStatus.value, isCurrentXrayRuntime())) {
            return
        }
        val uidSample = sampleUidTraffic()
        val singBoxCountersAvailable = status.uplinkTotal > 0L ||
            status.downlinkTotal > 0L ||
            status.uplink > 0L ||
            status.downlink > 0L
        val sessionSource = if (
            SessionTrafficRepository.currentSource() == SessionTrafficSource.SING_BOX ||
            singBoxCountersAvailable
        ) {
            SessionTrafficSource.SING_BOX
        } else {
            SessionTrafficSource.UID
        }
        val sessionRawUplink = if (sessionSource == SessionTrafficSource.SING_BOX) {
            status.uplinkTotal
        } else {
            uidSample.txTotal
        }
        val sessionRawDownlink = if (sessionSource == SessionTrafficSource.SING_BOX) {
            status.downlinkTotal
        } else {
            uidSample.rxTotal
        }
        val uplinkSpeed = if (status.uplink > 0L) status.uplink else uidSample.txSpeed
        val downlinkSpeed = if (status.downlink > 0L) status.downlink else uidSample.rxSpeed
        val uplinkTotal = if (status.uplinkTotal > 0L) status.uplinkTotal else uidSample.txTotal
        val downlinkTotal = if (status.downlinkTotal > 0L) status.downlinkTotal else uidSample.rxTotal
        val session = SessionTrafficRepository.observe(
            source = sessionSource,
            rawUplink = sessionRawUplink,
            rawDownlink = sessionRawDownlink,
        )
        
        // Update traffic stats
        val stats = currentNetworkSnapshot().toMutableMap()
        stats.putAll(mapOf(
            "uplinkSpeed" to uplinkSpeed,
            "downlinkSpeed" to downlinkSpeed,
            "uplinkTotal" to uplinkTotal,
            "downlinkTotal" to downlinkTotal,
            "connectionsIn" to status.connectionsIn,
            "connectionsOut" to status.connectionsOut,
            "sessionUplink" to session.uplink,
            "sessionDownlink" to session.downlink,
            "sessionTotal" to session.total,
            "formattedUplinkSpeed" to TrafficStats.formatBytes(uplinkSpeed) + "/s",
            "formattedDownlinkSpeed" to TrafficStats.formatBytes(downlinkSpeed) + "/s",
            "formattedUplinkTotal" to TrafficStats.formatBytes(uplinkTotal),
            "formattedDownlinkTotal" to TrafficStats.formatBytes(downlinkTotal),
            "formattedSessionUplink" to TrafficStats.formatBytes(session.uplink),
            "formattedSessionDownlink" to TrafficStats.formatBytes(session.downlink),
            "formattedSessionTotal" to TrafficStats.formatBytes(session.total)
        ))
        
        publishTrafficStats(stats)
    }

    private fun syncXrayTrafficSampler(status: Status) {
        val isXrayRuntime = isCurrentXrayRuntime()
        val shouldCollect = XrayTrafficEventPolicy.shouldCollect(
            status = status,
            isXrayRuntime = isXrayRuntime,
        )
        if (shouldCollect) {
            startXrayTrafficSampler()
        } else {
            stopXrayTrafficSampler(publishIdleSample = isXrayRuntime)
        }
    }

    private fun startXrayTrafficSampler() {
        if (xrayTrafficJob?.isActive == true) {
            return
        }
        if (sessionStartUidTxBytes < 0L ||
            sessionStartUidRxBytes < 0L ||
            lastUidTrafficSampleAt <= 0L
        ) {
            resetUidTrafficSession()
        }

        android.util.Log.i("FlutterSingboxPlugin", "Starting Xray UID traffic sampler")
        xrayTrafficJob = coroutineScope.launch {
            try {
                while (isActive && _vpnStatus.value == Status.Started) {
                    val sample = sampleUidTraffic()
                    val session = SessionTrafficRepository.observe(
                        source = SessionTrafficSource.UID,
                        rawUplink = sample.txTotal,
                        rawDownlink = sample.rxTotal,
                    )
                    val stats = XrayTrafficEventPolicy.build(
                        sample = sample.copy(
                            sessionTx = session.uplink,
                            sessionRx = session.downlink,
                        ),
                        networkSnapshot = currentNetworkSnapshot(),
                    )
                    publishTrafficStats(stats)
                    kotlinx.coroutines.delay(XRAY_TRAFFIC_SAMPLE_INTERVAL_MS)
                }
            } catch (error: CancellationException) {
                throw error
            } catch (error: Exception) {
                android.util.Log.e(
                    "FlutterSingboxPlugin",
                    "Xray UID traffic sampler failed",
                    error,
                )
            }
        }
    }

    private fun stopXrayTrafficSampler(publishIdleSample: Boolean = false) {
        val job = xrayTrafficJob ?: return
        xrayTrafficJob = null
        job.cancel()
        if (publishIdleSample) {
            val sample = sampleUidTraffic()
            val session = SessionTrafficRepository.observe(
                source = SessionTrafficSource.UID,
                rawUplink = sample.txTotal,
                rawDownlink = sample.rxTotal,
            )
            publishTrafficStats(
                XrayTrafficEventPolicy.build(
                    sample = sample.copy(
                        sessionTx = session.uplink,
                        sessionRx = session.downlink,
                    ),
                    networkSnapshot = currentNetworkSnapshot(),
                    active = false,
                ),
            )
        }
        android.util.Log.i("FlutterSingboxPlugin", "Stopped Xray UID traffic sampler")
    }

    private fun publishTrafficStats(stats: Map<String, Any>) {
        _trafficStats.value = stats
        updateTrafficNotification(stats)

        Handler(Looper.getMainLooper()).post {
            trafficEventSink?.success(stats)
        }
    }

    private fun resetUidTrafficSession() {
        val tx = readUidTxBytes()
        val rx = readUidRxBytes()
        sessionStartUidTxBytes = tx
        sessionStartUidRxBytes = rx
        lastUidTxBytes = tx
        lastUidRxBytes = rx
        lastUidTrafficSampleAt = System.currentTimeMillis()
    }

    private fun resetSessionTrafficCounters() {
        sessionStartedAt = 0L
        SessionTrafficRepository.reset(context)
        resetUidTrafficSession()
        _trafficStats.value = _trafficStats.value.mapValues { (key, value) ->
            when (key) {
                "uplinkSpeed", "downlinkSpeed", "uplinkTotal", "downlinkTotal",
                "sessionUplink", "sessionDownlink", "sessionTotal" -> 0L
                "connectionsIn", "connectionsOut" -> 0
                "formattedUplinkSpeed", "formattedDownlinkSpeed" -> "0 B/s"
                "formattedUplinkTotal", "formattedDownlinkTotal", "formattedSessionUplink",
                "formattedSessionDownlink", "formattedSessionTotal" -> "0 B"
                else -> value
            }
        }
    }

    private fun sampleUidTraffic(): XrayUidTrafficSample {
        val now = System.currentTimeMillis()
        val tx = readUidTxBytes()
        val rx = readUidRxBytes()
        if (tx < 0L || rx < 0L) {
            return XrayUidTrafficSample(0L, 0L, 0L, 0L, 0L, 0L)
        }

        if (sessionStartUidTxBytes < 0L || sessionStartUidRxBytes < 0L) {
            sessionStartUidTxBytes = tx
            sessionStartUidRxBytes = rx
        }

        val elapsedMs = (now - lastUidTrafficSampleAt).coerceAtLeast(1L)
        val txSpeed = if (lastUidTxBytes >= 0L) {
            ((tx - lastUidTxBytes).coerceAtLeast(0L) * 1000L) / elapsedMs
        } else {
            0L
        }
        val rxSpeed = if (lastUidRxBytes >= 0L) {
            ((rx - lastUidRxBytes).coerceAtLeast(0L) * 1000L) / elapsedMs
        } else {
            0L
        }

        lastUidTxBytes = tx
        lastUidRxBytes = rx
        lastUidTrafficSampleAt = now

        return XrayUidTrafficSample(
            txTotal = tx,
            rxTotal = rx,
            txSpeed = txSpeed,
            rxSpeed = rxSpeed,
            sessionTx = (tx - sessionStartUidTxBytes).coerceAtLeast(0L),
            sessionRx = (rx - sessionStartUidRxBytes).coerceAtLeast(0L)
        )
    }

    private fun readUidTxBytes(): Long {
        val value = android.net.TrafficStats.getUidTxBytes(context.applicationInfo.uid)
        return if (value == android.net.TrafficStats.UNSUPPORTED.toLong()) -1L else value
    }

    private fun readUidRxBytes(): Long {
        val value = android.net.TrafficStats.getUidRxBytes(context.applicationInfo.uid)
        return if (value == android.net.TrafficStats.UNSUPPORTED.toLong()) -1L else value
    }

    private fun updateTrafficNotification(stats: Map<String, Any>) {
        if (_vpnStatus.value != Status.Started) {
            return
        }

        val now = System.currentTimeMillis()
        if (now - lastNotificationUpdateAt < 1000) {
            return
        }
        lastNotificationUpdateAt = now

        connectionUiState = connectionUiState.copy(
            status = ConnectionStatus.Connected,
            uploadSpeed = stats["formattedUplinkSpeed"]?.toString() ?: "0 B/s",
            downloadSpeed = stats["formattedDownlinkSpeed"]?.toString() ?: "0 B/s",
            totalTraffic = stats["formattedSessionTotal"]?.toString() ?: "0 B",
            sessionDuration = currentSessionDuration()
        )
        vpnNotificationHelper.updateNotification(connectionUiState)
    }

    companion object {
        private const val XRAY_TRAFFIC_SAMPLE_INTERVAL_MS = 1_000L
    }

    private fun currentSessionDuration(): String? {
        val startedAt = sessionStartedAt
        if (startedAt <= 0L) return connectionUiState.sessionDuration
        val seconds = (System.currentTimeMillis() - startedAt).coerceAtLeast(0L) / 1000L
        return TrafficFormatter.formatDuration(seconds)
    }
    
    // Per-App Tunneling methods
    
    private fun setPerAppProxyMode(mode: String, result: Result) {
        try {
            when (mode) {
                Settings.PER_APP_PROXY_OFF, 
                Settings.PER_APP_PROXY_INCLUDE, 
                Settings.PER_APP_PROXY_EXCLUDE -> {
                    Settings.perAppProxyMode = mode
                    result.success(true)
                }
                else -> {
                    result.error("INVALID_MODE", "Invalid per-app proxy mode: $mode", null)
                }
            }
        } catch (e: Exception) {
            result.error("SET_MODE_ERROR", e.message, null)
        }
    }
    
    private fun getPerAppProxyMode(result: Result) {
        result.success(Settings.perAppProxyMode)
    }
    
    private fun setPerAppProxyList(appList: List<String>, result: Result) {
        try {
            Settings.perAppProxyList = appList
            result.success(true)
        } catch (e: Exception) {
            result.error("SET_APP_LIST_ERROR", e.message, null)
        }
    }
    
    private fun getPerAppProxyList(result: Result) {
        result.success(Settings.perAppProxyList)
    }
    
    private fun getInstalledApps(result: Result) {
        coroutineScope.launch(Dispatchers.IO) {
            try {
                val pm = context.packageManager
                val apps = pm.getInstalledApplications(PackageManager.GET_META_DATA)
                
                val appDetails = apps
                    .filter { it.packageName != context.packageName } // Exclude our app
                    .filter { !it.packageName.startsWith("com.android.") } // Filter out system apps
                    .map { appInfo ->
                        try {
                            val label = pm.getApplicationLabel(appInfo).toString()
                            mapOf(
                                "packageName" to appInfo.packageName,
                                "appName" to label,
                                "isSystemApp" to ((appInfo.flags and android.content.pm.ApplicationInfo.FLAG_SYSTEM) != 0)
                            )
                        } catch (e: Exception) {
                            mapOf(
                                "packageName" to appInfo.packageName,
                                "appName" to appInfo.packageName,
                                "isSystemApp" to ((appInfo.flags and android.content.pm.ApplicationInfo.FLAG_SYSTEM) != 0)
                            )
                        }
                    }
                    .sortedBy { it["appName"] as String }
                
                // Return on main thread
                Handler(Looper.getMainLooper()).post {
                    result.success(appDetails)
                }
            } catch (e: Exception) {
                Handler(Looper.getMainLooper()).post {
                    result.error("GET_APPS_ERROR", e.message, null)
                }
            }
        }
    }
    
    // LogClient.Handler implementation
    override fun onConnected() {
        android.util.Log.d("FlutterSingboxPlugin", "Log client connected")
    }
    
    override fun onDisconnected() {
        android.util.Log.d("FlutterSingboxPlugin", "Log client disconnected")
    }
    
    override fun clearLogs() {
        android.util.Log.d("FlutterSingboxPlugin", "Clearing logs")
        synchronized(logBuffer) {
            logBuffer.clear()
        }
        Handler(Looper.getMainLooper()).post {
            logEventSink?.success(mapOf("type" to "clear"))
        }
    }
    
    override fun appendLog(message: String) {
        // Add to buffer
        synchronized(logBuffer) {
            logBuffer.add(message)
            while (logBuffer.size > maxLogBufferSize) {
                logBuffer.removeFirst()
            }
        }
        
        // Send to Flutter
        Handler(Looper.getMainLooper()).post {
            logEventSink?.success(mapOf("type" to "log", "message" to message))
        }
    }
    
    // Method to get buffered logs (can be called from Flutter)
    private fun getLogs(result: Result) {
        synchronized(logBuffer) {
            result.success(logBuffer.toList())
        }
    }
    
    // Method to clear log buffer
    private fun clearLogBuffer(result: Result) {
        synchronized(logBuffer) {
            logBuffer.clear()
        }
        result.success(true)
    }
}
