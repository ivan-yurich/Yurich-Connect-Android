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
import android.net.VpnService
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.getSystemService
import androidx.core.content.ContextCompat
import androidx.core.app.ActivityCompat
import androidx.lifecycle.LiveData
import androidx.lifecycle.Observer
import com.tecclub.flutter_singbox.bg.BoxService
import com.tecclub.flutter_singbox.bg.ServiceConnection
import com.tecclub.flutter_singbox.bg.ServiceNotification
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
import go.Seq
import io.nekohasekai.libbox.Libbox
import io.nekohasekai.libbox.SetupOptions
import java.io.File
import com.tecclub.flutter_singbox.utils.StatusClient
import com.tecclub.flutter_singbox.utils.LogClient
import com.tecclub.flutter_singbox.utils.TrafficFormatter
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
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.GlobalScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * ApplicationHelper class - this is a copy of the Application functionality
 * directly embedded in the plugin class to avoid separate file dependencies
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
            
            Seq.setContext(application)
            
            // Initialize config manager
            SimpleConfigManager.init(application)
            
            @Suppress("OPT_IN_USAGE")
            GlobalScope.launch(Dispatchers.IO) {
                initializeLibbox(application)
            }
        }
        
        /**
         * Initialize the libbox library with the application's directories
         */
        private fun initializeLibbox(context: Context) {
            val baseDir = context.filesDir
            baseDir.mkdirs()
            val workingDir = context.getExternalFilesDir(null) ?: return
            workingDir.mkdirs()
            val tempDir = context.cacheDir
            tempDir.mkdirs()
            
            // Match official app: fixAndroidStack for Android N-N_MR1 and P+
            // See: https://github.com/golang/go/issues/68760
            val fixAndroidStack = android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.N && 
                    android.os.Build.VERSION.SDK_INT <= android.os.Build.VERSION_CODES.N_MR1 ||
                    android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.P
            
            val setupOptions = SetupOptions()
            setupOptions.basePath = baseDir.path
            setupOptions.workingPath = workingDir.path
            setupOptions.tempPath = tempDir.path
            setupOptions.fixAndroidStack = fixAndroidStack
            
            android.util.Log.d("ApplicationHelper", "Initializing libbox with fixAndroidStack=$fixAndroidStack")
            
            Libbox.setup(setupOptions)
            Libbox.redirectStderr(File(workingDir, "stderr.log").path)
        }
    }
}

private const val APP_ALERT_CHANNEL_ID = "yurich_connect_alerts"

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
    
    // Status tracking
    private val _vpnStatus = MutableStateFlow(Status.Stopped)
    val vpnStatus: StateFlow<Status> = _vpnStatus
    
    // For checking the initial status upon startup
    private var statusInitialized = false
    
    // Flag to prevent reconnection during shutdown
    private var isShuttingDown = false
    
    // Flag to prevent Stopped status during startup
    private var isStarting = false
    
    // Flag to track if there was a startup error
    private var hasStartupError = false
    
    // Job for stop cleanup - can be cancelled when starting new connection
    private var stopCleanupJob: kotlinx.coroutines.Job? = null

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
    private var sessionStartUplinkTotal = 0L
    private var sessionStartDownlinkTotal = 0L
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
        coroutineScope.launch {
            while (true) {
                try {
                    // Wait 15 seconds between checks
                    kotlinx.coroutines.delay(15000)
                    
                    // If status is Started, verify it's actually running
                    if (_vpnStatus.value == Status.Started) {
                        android.util.Log.e("FlutterSingboxPlugin", "Performing periodic status check")
                        checkServiceStatus()
                    }
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
                val statusOrdinal = intent.getIntExtra(Action.EXTRA_STATUS, Status.Stopped.ordinal)
                val status = Status.values()[statusOrdinal]
                
                android.util.Log.e("FlutterSingboxPlugin", "Received broadcast status change: ${status.name}, isStarting=$isStarting, hasStartupError=$hasStartupError")
                
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
                        if (!statusClient.isConnected()) {
                            statusClient.connect()
                        }
                        if (logEventSink != null && !logClient.isConnected()) {
                            logClient.connect()
                        }
                    }
                    Status.Stopped -> {
                        sessionStartedAt = 0L
                        connectionUiState = ConnectionUiState.disconnected()
                        // Clients will be disconnected by stopVPN or onServiceStatusChanged
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
                sendStatusUpdate(status)
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
                        val inferredStatus = inferredRunningStatus()
                        _vpnStatus.value = inferredStatus
                        
                        if (inferredStatus == Status.Started) {
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
                if (_vpnStatus.value == Status.Started && !logClient.isConnected()) {
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
        context.registerReceiver(statusReceiver, IntentFilter(Action.BROADCAST_STATUS_CHANGED), 
            Context.RECEIVER_NOT_EXPORTED)
        context.registerReceiver(alertReceiver, IntentFilter(Action.BROADCAST_ALERT), 
            Context.RECEIVER_NOT_EXPORTED)
            
        // Initialize status - ensure it's accurate
        checkServiceStatus()
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
                
                android.util.Log.e("FlutterSingboxPlugin", "VPN service running check: $isServiceRunning")
                
                if (isServiceRunning) {
                    val inferredStatus = inferredRunningStatus()
                    _vpnStatus.value = inferredStatus
                    
                    if (inferredStatus == Status.Started) {
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
            }
        }
    }
    
    // Helper method to send status updates to Flutter
    private fun sendStatusUpdate(status: Status) {
        android.util.Log.e("FlutterSingboxPlugin", "Sending status update to Flutter: ${status.name}")
        val statusMap = mapOf(
            "status" to status.name,
            "statusCode" to status.ordinal
        )
        
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

    private fun inferredRunningStatus(): Status {
        return when {
            isStarting -> Status.Starting
            _vpnStatus.value == Status.Stopping -> Status.Stopping
            else -> Status.Started
        }
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            "getPlatformVersion" -> {
                result.success("Android ${android.os.Build.VERSION.RELEASE}")
            }
            "saveConfig" -> {
                val config = call.argument<String>("config") ?: ""
                saveConfig(config, result)
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
            "getVPNStatus" -> {
                getVPNStatus(result)
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
            connectionUiState = ConnectionUiState.fromMap(state)
            if (
                connectionUiState.status != ConnectionStatus.Disconnected ||
                _vpnStatus.value != Status.Stopped
            ) {
                vpnNotificationHelper.updateNotification(connectionUiState)
            }
            result.success(true)
        } catch (e: Exception) {
            result.error("NOTIFICATION_UPDATE_ERROR", e.message, null)
        }
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
    
    private var configContent: String? = null
    
    private fun saveConfig(config: String, result: Result) {
        android.util.Log.e("FlutterSingboxPlugin", "Saving config: ${config.length} bytes")
        configContent = config // Store locally for immediate use when starting VPN
        
        coroutineScope.launch {
            try {
                val success = SimpleConfigManager.saveConfig(config)
                android.util.Log.e("FlutterSingboxPlugin", "Config save result: $success")
                if (success) {
                    result.success(true)
                } else {
                    result.error("CONFIG_SAVE_FAILED", "Failed to save configuration", null)
                }
            } catch (e: Exception) {
                android.util.Log.e("FlutterSingboxPlugin", "Error saving config: ${e.message}", e)
                result.error("CONFIG_SAVE_ERROR", e.message, null)
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
        android.util.Log.e("FlutterSingboxPlugin", "Starting VPN...")
        // Reset shutdown flag when starting a new connection
        isShuttingDown = false
        activity?.let {
            val intent = VpnService.prepare(it)
            if (intent != null) {
                android.util.Log.e("FlutterSingboxPlugin", "VPN permission required, showing dialog")
                pendingVpnPermissionResult = result
                it.startActivityForResult(intent, VPN_REQUEST_CODE)
            } else {
                android.util.Log.e("FlutterSingboxPlugin", "VPN permission already granted, starting service")
                startVPNService(result)
            }
        } ?: run {
            android.util.Log.e("FlutterSingboxPlugin", "Activity unavailable, cannot start VPN")
            result.error("ACTIVITY_UNAVAILABLE", "Activity is not available", null)
        }
    }
    
    private fun startVPNService(result: Result) {
        android.util.Log.e("FlutterSingboxPlugin", "Starting VPN Service...")
        
        // Cancel any pending stop cleanup job from previous stopVPN call
        stopCleanupJob?.cancel()
        stopCleanupJob = null
        android.util.Log.e("FlutterSingboxPlugin", "Cancelled any pending stop cleanup job")
        
        // Reset shutdown flag and set starting flag
        isShuttingDown = false
        isStarting = true
        hasStartupError = false
        try {
            // Update status to Starting
            _vpnStatus.value = Status.Starting
            connectionUiState = connectionUiState.copy(
                status = ConnectionStatus.Connecting,
                uploadSpeed = "0 B/s",
                downloadSpeed = "0 B/s",
                totalTraffic = "0 B",
                sessionDuration = null
            )
            vpnNotificationHelper.updateNotification(connectionUiState)
            android.util.Log.e("FlutterSingboxPlugin", "Set VPN status to Starting")
            sendStatusUpdate(Status.Starting)
            SimpleConfigManager.setStartedByUser(true)
            
            // Reset session traffic counters
            sessionStartUplinkTotal = 0
            sessionStartDownlinkTotal = 0
            resetUidTrafficSession()
            
            // Start the service using proper method
            android.util.Log.e("FlutterSingboxPlugin", "Calling startService method")
            startService(result)
            
            // Delay before connecting to service to give it time to start
            coroutineScope.launch {
                android.util.Log.e("FlutterSingboxPlugin", "Waiting for service to initialize...")
                kotlinx.coroutines.delay(1500) // Wait 1.5 seconds for service to start
                
                // Check if there was a startup error
                if (hasStartupError) {
                    android.util.Log.e("FlutterSingboxPlugin", "Startup error detected, not connecting to service")
                    isStarting = false
                    return@launch
                }
                
                // Connect to the service
                android.util.Log.e("FlutterSingboxPlugin", "Connecting to service after delay")
                connection.connect()
                
                // Reset starting flag after connection attempt
                kotlinx.coroutines.delay(500) // Additional delay for connection to stabilize
                isStarting = false
                android.util.Log.e("FlutterSingboxPlugin", "Starting phase complete")
            }
            
            android.util.Log.e("FlutterSingboxPlugin", "VPN service start successful")
            result.success(true)
        } catch (e: Exception) {
            android.util.Log.e("FlutterSingboxPlugin", "Error starting VPN service: ${e.message}", e)
            isStarting = false
            SimpleConfigManager.setStartedByUser(false)
            _vpnStatus.value = Status.Stopped
            result.error("START_VPN_ERROR", e.message, null)
        }
    }
    
    private fun startService(result: Result) {
        coroutineScope.launch(Dispatchers.IO) {
            android.util.Log.e("FlutterSingboxPlugin", "Starting service in IO coroutine")

            if (Settings.serviceMode == ServiceMode.VPN) {
                 android.util.Log.e("FlutterSingboxPlugin", "Service mode is VPN, checking if prepare is needed")
                 if (prepare(result)) {
                     android.util.Log.e("FlutterSingboxPlugin", "VPN prepare returned true, exiting launch")
                     return@launch
                 }
                 android.util.Log.e("FlutterSingboxPlugin", "VPN prepare returned false, continuing")
             }
             
            // Load config from SimpleConfigManager and set it as an extra
            val config = SimpleConfigManager.getConfig()
            android.util.Log.e("FlutterSingboxPlugin", "Loaded config from SimpleConfigManager, length: ${config.length}")
            
            // Create intent with action and config content
            val intent = Intent(context, Settings.serviceClass()).apply {
                action = BoxService.ACTION_START
                putExtra(BoxService.EXTRA_CONFIG_CONTENT, config)
            }
            android.util.Log.e("FlutterSingboxPlugin", "Created intent with ACTION_START and config extra")
            
            withContext(Dispatchers.Main) {
                android.util.Log.e("FlutterSingboxPlugin", "Starting foreground service")
                androidx.core.content.ContextCompat.startForegroundService(context, intent)
                android.util.Log.e("FlutterSingboxPlugin", "Service start request sent")
            }
        }
    }

    private suspend fun prepare(result: Result) = withContext(Dispatchers.Main) {
         try {
             android.util.Log.e("FlutterSingboxPlugin", "Preparing VPN service")
             val intent = VpnService.prepare(this@FlutterSingboxPlugin.context)
             if (intent != null) {
                 android.util.Log.e("FlutterSingboxPlugin", "VPN preparation returned an intent, need permission")
                 
                 // We shouldn't call startVPN here as it would cause an infinite loop
                 // Instead, we need to store the result and show the dialog
                 activity?.let {
                     android.util.Log.e("FlutterSingboxPlugin", "Starting VPN permission request activity")
                     pendingVpnPermissionResult = result
                     it.startActivityForResult(intent, VPN_REQUEST_CODE)
                     true
                 } ?: run {
                     android.util.Log.e("FlutterSingboxPlugin", "Activity unavailable for permission request")
                     onServiceAlert(Alert.RequestVPNPermission, "Activity unavailable")
                     false
                 }
             } else {
                 android.util.Log.e("FlutterSingboxPlugin", "VPN preparation returned null, permission already granted")
                 false
             }
         } catch (e: Exception) {
             android.util.Log.e("FlutterSingboxPlugin", "Error preparing VPN: ${e.message}", e)
             onServiceAlert(Alert.RequestVPNPermission, e.message)
             false
         }
     }
    
    private fun stopVPN(result: Result) {
        try {
            android.util.Log.e("FlutterSingboxPlugin", "Stopping VPN")
            
            // Set shutting down flag and clear starting flag
            isShuttingDown = true
            isStarting = false
            SimpleConfigManager.setStartedByUser(false)
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
            context.sendBroadcast(
                Intent(Action.SERVICE_CLOSE).setPackage(
                    context.packageName
                )
            )

            result.success(true)
            
            // Wait for service to stop before disconnecting
            // The service will broadcast Status.Stopped when it's done cleaning up
            // Store the job so it can be cancelled if user starts VPN again quickly
            stopCleanupJob = coroutineScope.launch {
                try {
                    android.util.Log.e("FlutterSingboxPlugin", "Waiting for service to stop...")

                    val deadline = System.currentTimeMillis() + 12000
                    var running = true
                    while (System.currentTimeMillis() < deadline) {
                        kotlinx.coroutines.delay(250)

                        // Check if we're still shutting down (might have been cancelled by startVPN)
                        if (!isShuttingDown) {
                            android.util.Log.e("FlutterSingboxPlugin", "Stop cleanup cancelled - VPN is starting again")
                            return@launch
                        }

                        running = isVpnServiceRunning()
                        if (!running) {
                            break
                        }
                    }

                    if (running) {
                        android.util.Log.e("FlutterSingboxPlugin", "Service still running after graceful stop, requesting stopService")
                        context.sendBroadcast(
                            Intent(Action.SERVICE_CLOSE).setPackage(
                                context.packageName
                            )
                        )
                        context.stopService(Intent(context, Settings.serviceClass()))
                        val forceDeadline = System.currentTimeMillis() + 4000
                        while (System.currentTimeMillis() < forceDeadline) {
                            kotlinx.coroutines.delay(250)
                            running = isVpnServiceRunning()
                            if (!running) {
                                break
                            }
                        }
                    }

                    android.util.Log.e("FlutterSingboxPlugin", "Disconnecting from service after cleanup, running=$running")
                    statusClient.disconnect()
                    logClient.disconnect()
                    connection.disconnect()

                    // Force status to Stopped only after the service had time to shut down.
                    _vpnStatus.value = Status.Stopped
                    sendStatusUpdate(Status.Stopped)

                    // Reset the shutting down flag
                    isShuttingDown = false
                    stopCleanupJob = null

                    android.util.Log.e("FlutterSingboxPlugin", "VPN stopped successfully")
                } catch (e: Exception) {
                    android.util.Log.e("FlutterSingboxPlugin", "Error during stop cleanup: ${e.message}", e)
                    isShuttingDown = false
                    _vpnStatus.value = Status.Stopped
                    sendStatusUpdate(Status.Stopped)
                    stopCleanupJob = null
                }
            }
        } catch (e: Exception) {
            android.util.Log.e("FlutterSingboxPlugin", "Error stopping VPN", e)
            
            // Reset the shutting down flag
            isShuttingDown = false
            
            // Even on error, set status to Stopped for UI consistency
            _vpnStatus.value = Status.Stopped
            sendStatusUpdate(Status.Stopped)
            
            result.error("STOP_VPN_ERROR", e.message, null)
        }
    }
    
    private fun getVPNStatus(result: Result) {
        android.util.Log.e("FlutterSingboxPlugin", "getVPNStatus called")
        
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
                
                android.util.Log.e("FlutterSingboxPlugin", "VPN service running check in getVPNStatus: $isServiceRunning")
                
                if (isServiceRunning) {
                    val inferredStatus = inferredRunningStatus()
                    _vpnStatus.value = inferredStatus
                    
                    if (inferredStatus == Status.Started) {
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
                
                // Return the current status
                result.success(_vpnStatus.value.name)
                
                // Also update status via event channel
                sendStatusUpdate(_vpnStatus.value)
                
                statusInitialized = true
            } catch (e: Exception) {
                android.util.Log.e("FlutterSingboxPlugin", "Error checking VPN status", e)
                result.success(_vpnStatus.value.name) // Return current status as fallback
            }
        }
    }
    
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode == VPN_REQUEST_CODE) {
            android.util.Log.e("FlutterSingboxPlugin", "VPN permission request result: ${if (resultCode == Activity.RESULT_OK) "GRANTED" else "DENIED"}")
            if (resultCode == Activity.RESULT_OK) {
                android.util.Log.e("FlutterSingboxPlugin", "VPN permission granted, starting service")
                pendingVpnPermissionResult?.let {
                    // First load the config that should be used
                    val configContent = SimpleConfigManager.getConfig()
                    android.util.Log.e("FlutterSingboxPlugin", "Loaded config from SimpleConfigManager: ${configContent.length} bytes")
                    
                    // Start VPN service with the config
                    startVPNService(it)
                } ?: run {
                    android.util.Log.e("FlutterSingboxPlugin", "WARNING: No pending result found after permission granted")
                }
            } else {
                android.util.Log.e("FlutterSingboxPlugin", "VPN permission denied by user")
                pendingVpnPermissionResult?.error("VPN_PERMISSION_DENIED", "VPN permission denied", null)
            }
            pendingVpnPermissionResult = null
            return true
        }
        return false
    }
    
    // ServiceConnection.Callback implementation
    override fun onServiceStatusChanged(status: Status) {
        android.util.Log.e("FlutterSingboxPlugin", "onServiceStatusChanged: ${status.name}, hasStartupError=$hasStartupError")
        
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
                sessionStartedAt = System.currentTimeMillis()
                connectionUiState = connectionUiState.copy(
                    status = ConnectionStatus.Connected,
                    uploadSpeed = "0 B/s",
                    downloadSpeed = "0 B/s",
                    totalTraffic = "0 B",
                    sessionDuration = "00:00:00"
                )
                vpnNotificationHelper.updateNotification(connectionUiState)
                
                // Connect status client if not already connected
                if (!statusClient.isConnected()) {
                    statusClient.connect()
                }
                
                // Also connect log client if there's a listener and not already connected
                if (logEventSink != null && !logClient.isConnected()) {
                    logClient.connect()
                }
                
                // Reset session traffic counters when connection starts
                sessionStartUplinkTotal = 0
                sessionStartDownlinkTotal = 0
                resetUidTrafficSession()
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
        val uidSample = sampleUidTraffic()

        // When first status update comes, set session start values
        if (sessionStartUplinkTotal == 0L && sessionStartDownlinkTotal == 0L && status.uplinkTotal > 0) {
            sessionStartUplinkTotal = status.uplinkTotal
            sessionStartDownlinkTotal = status.downlinkTotal
        }
        
        // Calculate session data (data transferred since connection started)
        val singBoxSessionUplink = (status.uplinkTotal - sessionStartUplinkTotal).coerceAtLeast(0L)
        val singBoxSessionDownlink = (status.downlinkTotal - sessionStartDownlinkTotal).coerceAtLeast(0L)
        val sessionUplink = if (singBoxSessionUplink > 0L || status.uplink > 0L) {
            singBoxSessionUplink
        } else {
            uidSample.sessionTx
        }
        val sessionDownlink = if (singBoxSessionDownlink > 0L || status.downlink > 0L) {
            singBoxSessionDownlink
        } else {
            uidSample.sessionRx
        }
        val uplinkSpeed = if (status.uplink > 0L) status.uplink else uidSample.txSpeed
        val downlinkSpeed = if (status.downlink > 0L) status.downlink else uidSample.rxSpeed
        val uplinkTotal = if (status.uplinkTotal > 0L) status.uplinkTotal else uidSample.txTotal
        val downlinkTotal = if (status.downlinkTotal > 0L) status.downlinkTotal else uidSample.rxTotal
        
        // Update traffic stats
        val stats = mapOf(
            "uplinkSpeed" to uplinkSpeed,
            "downlinkSpeed" to downlinkSpeed,
            "uplinkTotal" to uplinkTotal,
            "downlinkTotal" to downlinkTotal,
            "connectionsIn" to status.connectionsIn,
            "connectionsOut" to status.connectionsOut,
            "sessionUplink" to sessionUplink,
            "sessionDownlink" to sessionDownlink,
            "sessionTotal" to (sessionUplink + sessionDownlink),
            "formattedUplinkSpeed" to TrafficStats.formatBytes(uplinkSpeed) + "/s",
            "formattedDownlinkSpeed" to TrafficStats.formatBytes(downlinkSpeed) + "/s",
            "formattedUplinkTotal" to TrafficStats.formatBytes(uplinkTotal),
            "formattedDownlinkTotal" to TrafficStats.formatBytes(downlinkTotal),
            "formattedSessionUplink" to TrafficStats.formatBytes(sessionUplink),
            "formattedSessionDownlink" to TrafficStats.formatBytes(sessionDownlink),
            "formattedSessionTotal" to TrafficStats.formatBytes(sessionUplink + sessionDownlink)
        )
        
        _trafficStats.value = stats as Map<String, Any>
        updateTrafficNotification(stats)
        
        // Send traffic stats to Flutter
        val handler = Handler(Looper.getMainLooper())
        handler.post {
            trafficEventSink?.success(stats)
        }
    }

    private data class UidTrafficSample(
        val txTotal: Long,
        val rxTotal: Long,
        val txSpeed: Long,
        val rxSpeed: Long,
        val sessionTx: Long,
        val sessionRx: Long
    )

    private fun resetUidTrafficSession() {
        val tx = readUidTxBytes()
        val rx = readUidRxBytes()
        sessionStartUidTxBytes = tx
        sessionStartUidRxBytes = rx
        lastUidTxBytes = tx
        lastUidRxBytes = rx
        lastUidTrafficSampleAt = System.currentTimeMillis()
    }

    private fun sampleUidTraffic(): UidTrafficSample {
        val now = System.currentTimeMillis()
        val tx = readUidTxBytes()
        val rx = readUidRxBytes()
        if (tx < 0L || rx < 0L) {
            return UidTrafficSample(0L, 0L, 0L, 0L, 0L, 0L)
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

        return UidTrafficSample(
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
