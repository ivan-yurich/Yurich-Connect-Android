package com.tecclub.flutter_singbox.bg

import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.ConnectivityManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.os.PowerManager
import androidx.annotation.RequiresApi
import androidx.core.content.ContextCompat
import androidx.lifecycle.MutableLiveData
import com.tecclub.flutter_singbox.Application
import com.tecclub.flutter_singbox.config.SimpleConfigManager
import com.tecclub.flutter_singbox.constant.Action
import com.tecclub.flutter_singbox.constant.Alert
import com.tecclub.flutter_singbox.constant.Status
import com.tecclub.flutter_singbox.database.Settings
import io.nekohasekai.libbox.CommandServer
import io.nekohasekai.libbox.CommandServerHandler
import io.nekohasekai.libbox.Libbox
import io.nekohasekai.libbox.OverrideOptions
import io.nekohasekai.libbox.PlatformInterface
import io.nekohasekai.libbox.SystemProxyStatus
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import java.net.InetSocketAddress
import java.net.Socket
import javax.net.ssl.SSLSocket
import javax.net.ssl.SSLSocketFactory

class BoxService(
    private val service: Service, private val platformInterface: PlatformInterface
) : CommandServerHandler {

    companion object {
        const val ACTION_START = "io.nekohasekai.sfa.ACTION_START"
        const val EXTRA_CONFIG_CONTENT = "config_content"
        private const val WATCHDOG_MIXED_PROXY_PORT = 20808
        private const val WATCHDOG_INITIAL_GRACE_MS = 30_000L
        private const val WATCHDOG_INTERVAL_MS = 60_000L
        private const val WATCHDOG_IDLE_INTERVAL_MS = 90_000L
        private const val WATCHDOG_RESTART_COOLDOWN_MS = 90_000L
        private const val WATCHDOG_FAILURE_LIMIT = 3
        private const val KEEPER_WAKE_LOCK_MS = 10 * 60 * 1000L
        private const val STICKY_RESTART_DELAY_MS = 2_500L
        private const val NETWORK_SETTLE_DELAY_MS = 6_000L
        private const val WAKE_SETTLE_DELAY_MS = 3_000L
        private const val NETWORK_WAKE_DEBOUNCE_MS = 5_000L

        fun start() {
            val intent = runBlocking {
                withContext(Dispatchers.IO) {
                    Intent(Application.application, Settings.serviceClass()).apply {
                        action = ACTION_START
                        // Config content should be added by the caller
                    }
                }
            }
            ContextCompat.startForegroundService(Application.application, intent)
        }

        fun stop() {
            Application.application.sendBroadcast(
                Intent(Action.SERVICE_CLOSE).setPackage(
                    Application.application.packageName
                )
            )
        }
    }

    var fileDescriptor: ParcelFileDescriptor? = null

    private val status = MutableLiveData(Status.Stopped)
    private val binder = ServiceBinder(status) // We're using StatusClient now for traffic stats
    private val notification: ServiceNotification by lazy { 
        ServiceNotification(status, service) 
    }
    private var commandServer: CommandServer? = null
    private val serviceScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private var watchdogJob: Job? = null
    private var watchdogFailures = 0
    private var watchdogMixedProxyEnabled = false
    private var lastWatchdogRestartAt = 0L
    private var lastNetworkWakeEventAt = 0L
    @Volatile private var watchdogRestarting = false
    private var keeperWakeLock: PowerManager.WakeLock? = null
    private var receiverRegistered = false
    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            when (intent.action) {
                Action.SERVICE_CLOSE -> {
                    stopService()
                }

                Action.SERVICE_RESTART -> {
                    serviceScope.launch {
                        if (status.value == Status.Started) {
                            restartFromWatchdog("notification-action")
                        } else if (status.value == Status.Stopped) {
                            onStartCommand()
                        }
                    }
                }


                PowerManager.ACTION_DEVICE_IDLE_MODE_CHANGED -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                        serviceUpdateIdleMode()
                    }
                    refreshKeeperWakeLock("idle-mode")
                    handleNetworkWakeEvent("idle-mode")
                }

                ConnectivityManager.CONNECTIVITY_ACTION,
                Intent.ACTION_SCREEN_ON,
                Intent.ACTION_USER_PRESENT -> {
                    handleNetworkWakeEvent(intent.action ?: "network-wake")
                }
            }
        }
    }

    private fun startCommandServer() {
        if (commandServer != null) {
            android.util.Log.d("BoxService", "Command server already started")
            return
        }
        val commandServer = CommandServer(this, platformInterface)
        commandServer.start()
        this.commandServer = commandServer
    }

    private var lastProfileName = ""
    private suspend fun startService() {
        android.util.Log.e("BoxService", "Starting SingBox service...")
        try {
            // withContext(Dispatchers.Main) {
            //     android.util.Log.e("BoxService", "Showing initial notification")
            //     notification.show(lastProfileName, "Starting...")
            // }

            // Load the configuration from the SimpleConfigManager instead of database
            android.util.Log.e("BoxService", "Loading configuration from SimpleConfigManager")
            val content = SimpleConfigManager.getConfig()
            android.util.Log.e("BoxService", "Config loaded, length: ${content.length}")
            watchdogMixedProxyEnabled =
                content.contains("\"type\"") &&
                content.contains("\"mixed\"") &&
                content.contains("$WATCHDOG_MIXED_PROXY_PORT")
            
            if (content.isBlank() || content == "{}") {
                android.util.Log.e("BoxService", "Empty configuration detected")
                stopAndAlert(Alert.EmptyConfiguration)
                return
            }

            lastProfileName = "Yurich Connect"
            // withContext(Dispatchers.Main) {
            //     android.util.Log.e("BoxService", "Updating notification with profile name")
            //     // notification.show(lastProfileName, "Starting...")
            // }

            android.util.Log.e("BoxService", "Starting DefaultNetworkMonitor")
            DefaultNetworkMonitor.start()
            
            android.util.Log.e("BoxService", "Setting memory limit")
            Libbox.setMemoryLimit(true)
            
            android.util.Log.e("BoxService", "Config accepted, length: ${content.length}")

            try {
                commandServer?.startOrReloadService(content, OverrideOptions())
                android.util.Log.e("BoxService", "SingBox service started successfully")
            } catch (e: Exception) {
                android.util.Log.e("BoxService", "Failed to start SingBox service: ${e.message}", e)
                stopAndAlert(Alert.StartService, e.message)
                return
            }

            android.util.Log.e("BoxService", "Posting status as Started")
            status.postValue(Status.Started)
            
            // Start traffic monitoring
            android.util.Log.e("BoxService", "Starting traffic monitor")
            startTrafficMonitor()
            
            // Broadcast status change
            android.util.Log.e("BoxService", "Broadcasting status change to Started")
            Application.application.sendBroadcast(
                Intent(Action.BROADCAST_STATUS_CHANGED).apply {
                    `package` = Application.application.packageName
                    putExtra(Action.EXTRA_STATUS, Status.Started.ordinal)
                }
            )
            
            android.util.Log.e("BoxService", "Updating notification to Connected")
            withContext(Dispatchers.Main) {
                notification.show(lastProfileName, "Подключено")
            }
            
            android.util.Log.e("BoxService", "Starting notification")
            notification.start()
            refreshKeeperWakeLock("service-start")
            startNativeWatchdog()
            
            android.util.Log.e("BoxService", "Service startup complete")
        } catch (e: Exception) {
            android.util.Log.e("BoxService", "Uncaught exception in startService: ${e.message}", e)
            stopAndAlert(Alert.StartService, e.message)
            return
        }
    }

    override fun serviceReload() {
        stopNativeWatchdog()
        notification.stop()
        status.postValue(Status.Starting)
            // Broadcast status change
            Application.application.sendBroadcast(
                Intent(Action.BROADCAST_STATUS_CHANGED).apply {
                    `package` = Application.application.packageName
                    putExtra(Action.EXTRA_STATUS, Status.Starting.ordinal)
                }
            )
            val pfd = fileDescriptor
            if (pfd != null) {
                pfd.close()
                fileDescriptor = null
            }
        commandServer?.closeService()
        runBlocking {
            startService()
        }
    }

    override fun serviceStop() {
        stopService()
    }

    override fun writeDebugMessage(message: String) {
        android.util.Log.d("BoxService", message)
    }

    override fun getSystemProxyStatus(): SystemProxyStatus {
        val status = SystemProxyStatus()
        if (service is VPNService) {
            status.available = service.systemProxyAvailable
            status.enabled = service.systemProxyEnabled
        }
        return status
    }

    override fun setSystemProxyEnabled(isEnabled: Boolean) {
        serviceReload()
    }

    @RequiresApi(Build.VERSION_CODES.M)
    private fun serviceUpdateIdleMode() {
        android.util.Log.d(
            "BoxService",
            "Device idle mode changed; keeping foreground VPN command server awake"
        )
        commandServer?.wake()
        refreshKeeperWakeLock("device-idle")
    }

    private fun startTrafficMonitor() {
        // Nothing to do here - we're using StatusClient to get traffic updates
        // This method is kept for backwards compatibility
        android.util.Log.d("BoxService", "Traffic monitoring is now handled by StatusClient")
    }

    private fun stopService() {
        if (status.value != Status.Started && status.value != Status.Starting) return
        stopNativeWatchdog()
        releaseKeeperWakeLock()
        status.value = Status.Stopping
        

        // Broadcast Stopping status
        Application.application.sendBroadcast(
            Intent(Action.BROADCAST_STATUS_CHANGED).apply {
                `package` = Application.application.packageName
                putExtra(Action.EXTRA_STATUS, Status.Stopping.ordinal)
            }
        )
        
        if (receiverRegistered) {
            service.unregisterReceiver(receiver)
            receiverRegistered = false
        }
        notification.stop()
        serviceScope.launch {
            val pfd = fileDescriptor
            if (pfd != null) {
                pfd.close()
                fileDescriptor = null
            }
            runCatching {
                commandServer?.closeService()
            }.onFailure {
                android.util.Log.e("BoxService", "service: error when closing", it)
            }
            DefaultNetworkMonitor.stop()

            commandServer?.apply {
                close()
            }
            commandServer = null
            // Broadcast status change
            Application.application.sendBroadcast(
                Intent(Action.BROADCAST_STATUS_CHANGED).apply {
                    `package` = Application.application.packageName
                    putExtra(Action.EXTRA_STATUS, Status.Stopped.ordinal)
                }
            )
            withContext(Dispatchers.Main) {
                status.value = Status.Stopped
                service.stopSelf()
            }
        }
    }

    private suspend fun stopAndAlert(type: Alert, message: String? = null) {
        android.util.Log.e("BoxService", "stopAndAlert called: ${type.name}, message: $message")
        stopNativeWatchdog()
        releaseKeeperWakeLock()
        runCatching {
            SimpleConfigManager.setStartedByUser(false)
        }
        withContext(Dispatchers.Main) {
            // CRITICAL: Must call startForeground before stopping to avoid Android crash
            // When startForegroundService is called, we MUST call startForeground within ~5 seconds
            android.util.Log.e("BoxService", "Showing error notification before stopping")
            notification.show("Error", message ?: type.name)
            
            if (receiverRegistered) {
                android.util.Log.e("BoxService", "Unregistering broadcast receivers")
                service.unregisterReceiver(receiver)
                receiverRegistered = false
            }
            
            android.util.Log.e("BoxService", "Stopping notification")
            notification.stop()
            
            android.util.Log.e("BoxService", "Broadcasting alert: ${type.name}")
            binder.broadcast { serviceCallback ->
                serviceCallback.onServiceAlert(type.ordinal, message)
            }
            
            android.util.Log.e("BoxService", "Setting status to Stopped")
            status.value = Status.Stopped
            
            // Broadcast Stopped status after alert
            android.util.Log.e("BoxService", "Broadcasting Stopped status")
            Application.application.sendBroadcast(
                Intent(Action.BROADCAST_STATUS_CHANGED).apply {
                    `package` = Application.application.packageName
                    putExtra(Action.EXTRA_STATUS, Status.Stopped.ordinal)
                }
            )
            
            // Stop the service itself
            android.util.Log.e("BoxService", "Stopping service")
            service.stopSelf()
            
            android.util.Log.e("BoxService", "Alert handling complete")
        }
    }

    @Suppress("SameReturnValue")
    internal fun onStartCommand(): Int {
        Application.initializeIfNeeded(service.applicationContext)
        android.util.Log.e("BoxService", "onStartCommand called, current status: ${status.value}")
        val keepRunning = runCatching { SimpleConfigManager.getStartedByUser() }.getOrDefault(false)
        
        // CRITICAL: Call startForeground IMMEDIATELY to prevent Android from killing the app
        // This must happen synchronously before any async work
        android.util.Log.e("BoxService", "Starting foreground notification immediately")
        notification.show("Yurich Connect", "Подключение...")
        
        if (status.value != Status.Stopped) {
            android.util.Log.e("BoxService", "Service already running, not restarting")
            return if (keepRunning) Service.START_STICKY else Service.START_NOT_STICKY
        }
        
        android.util.Log.e("BoxService", "Setting status to Starting")
        status.value = Status.Starting
        
        // Broadcast status change
        android.util.Log.e("BoxService", "Broadcasting Starting status")
        Application.application.sendBroadcast(
            Intent(Action.BROADCAST_STATUS_CHANGED).apply {
                `package` = Application.application.packageName
                putExtra(Action.EXTRA_STATUS, Status.Starting.ordinal)
            }
        )

        if (!receiverRegistered) {
            android.util.Log.e("BoxService", "Registering broadcast receivers")
            ContextCompat.registerReceiver(service, receiver, IntentFilter().apply {
                addAction(Action.SERVICE_CLOSE)
                addAction(Action.SERVICE_RESTART)
                addAction(ConnectivityManager.CONNECTIVITY_ACTION)
                addAction(Intent.ACTION_SCREEN_ON)
                addAction(Intent.ACTION_USER_PRESENT)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                    addAction(PowerManager.ACTION_DEVICE_IDLE_MODE_CHANGED)
                }
            }, ContextCompat.RECEIVER_NOT_EXPORTED)
            receiverRegistered = true
        }

        android.util.Log.e("BoxService", "Launching IO coroutine for service startup")
        serviceScope.launch {
            try {
                android.util.Log.e("BoxService", "Ensuring libbox initialization")
                Application.ensureLibboxInitialized(service.applicationContext)
                android.util.Log.e("BoxService", "Starting command server")
                startCommandServer()
            } catch (e: Exception) {
                android.util.Log.e("BoxService", "Failed to start command server: ${e.message}", e)
                stopAndAlert(Alert.StartCommandServer, e.message)
                return@launch
            }
            
            android.util.Log.e("BoxService", "Calling startService()")
            startService()
        }
        return if (keepRunning) Service.START_STICKY else Service.START_NOT_STICKY
    }

    internal fun onBind(): android.os.Binder {
        return android.os.Binder()
    }

    internal fun onDestroy() {
        val shouldRestore = runCatching {
            SimpleConfigManager.getStartedByUser() && SimpleConfigManager.hasValidConfig()
        }.getOrDefault(false)
        stopNativeWatchdog()
        serviceScope.cancel()
        releaseKeeperWakeLock()
        runCatching {
            if (receiverRegistered) {
                service.unregisterReceiver(receiver)
                receiverRegistered = false
            }
        }
        runCatching {
            notification.stop()
        }
        runCatching {
            fileDescriptor?.close()
            fileDescriptor = null
        }
        runCatching {
            commandServer?.closeService()
            commandServer?.close()
            commandServer = null
        }
        runCatching {
            runBlocking {
                DefaultNetworkMonitor.stop()
            }
        }
        status.postValue(Status.Stopped)
        Application.application.sendBroadcast(
            Intent(Action.BROADCAST_STATUS_CHANGED).apply {
                `package` = Application.application.packageName
                putExtra(Action.EXTRA_STATUS, Status.Stopped.ordinal)
            }
        )
        binder.close()
        if (shouldRestore) {
            scheduleStickyRestart("service-destroyed")
        }
    }

    internal fun onTaskRemoved() {
        val shouldRestore = runCatching {
            SimpleConfigManager.getStartedByUser() && SimpleConfigManager.hasValidConfig()
        }.getOrDefault(false)
        if (shouldRestore) {
            scheduleStickyRestart("task-removed")
        }
    }

    internal fun onRevoke() {
        stopService()
    }

    internal fun writeLog(message: String) {
        commandServer?.writeMessage(0, message)
    }
    
    internal fun sendNotification(notification: io.nekohasekai.libbox.Notification) {
        // Basic notification handling - can be extended later
        android.util.Log.d("BoxService", "Notification: ${notification.title} - ${notification.body}")
    }

    private fun broadcastStatus(nextStatus: Status) {
        Application.application.sendBroadcast(
            Intent(Action.BROADCAST_STATUS_CHANGED).apply {
                `package` = Application.application.packageName
                putExtra(Action.EXTRA_STATUS, nextStatus.ordinal)
            }
        )
    }

    private fun startNativeWatchdog() {
        watchdogJob?.cancel()
        watchdogFailures = 0

        if (!watchdogMixedProxyEnabled) {
            android.util.Log.d(
                "BoxService",
                "Native watchdog skipped: mixed proxy $WATCHDOG_MIXED_PROXY_PORT not found"
            )
            return
        }

        watchdogJob = serviceScope.launch {
            delay(WATCHDOG_INITIAL_GRACE_MS)
            while (isActive && status.value == Status.Started) {
                refreshKeeperWakeLock("watchdog")
                commandServer?.wake()

                if (!hasDefaultNetwork()) {
                    watchdogFailures = 0
                    android.util.Log.w("BoxService", "Watchdog: waiting for default network")
                    withContext(Dispatchers.Main) {
                        notification.show(lastProfileName, "Ожидание сети...")
                    }
                    delay(15_000L)
                    continue
                }

                val healthy = probeMixedProxy()
                if (healthy) {
                    if (watchdogFailures > 0) {
                        android.util.Log.d("BoxService", "Watchdog: tunnel recovered")
                    }
                    watchdogFailures = 0
                } else {
                    watchdogFailures += 1
                    android.util.Log.w(
                        "BoxService",
                        "Watchdog: tunnel probe failed #$watchdogFailures"
                    )
                    if (watchdogFailures >= WATCHDOG_FAILURE_LIMIT) {
                        watchdogFailures = 0
                        restartFromWatchdog("health-probe")
                    }
                }

                delay(watchdogDelayMs())
            }
        }
    }

    private fun stopNativeWatchdog() {
        watchdogJob?.cancel()
        watchdogJob = null
        watchdogFailures = 0
        watchdogRestarting = false
    }

    private fun handleNetworkWakeEvent(reason: String) {
        if (status.value != Status.Started || watchdogRestarting) {
            return
        }

        val now = System.currentTimeMillis()
        if (now - lastNetworkWakeEventAt < NETWORK_WAKE_DEBOUNCE_MS) {
            android.util.Log.d("BoxService", "Watchdog: network/wake event debounced: $reason")
            return
        }
        lastNetworkWakeEventAt = now

        serviceScope.launch {
            android.util.Log.d("BoxService", "Watchdog: network/wake event $reason")
            refreshKeeperWakeLock(reason)
            commandServer?.wake()
            runCatching {
                DefaultNetworkMonitor.stop()
                DefaultNetworkMonitor.start()
            }.onFailure {
                android.util.Log.w("BoxService", "Watchdog: network monitor refresh failed", it)
            }

            if (watchdogJob?.isActive != true) {
                startNativeWatchdog()
            }

            if (!watchdogMixedProxyEnabled) {
                return@launch
            }

            delay(settleDelayFor(reason))
            if (status.value != Status.Started || !hasDefaultNetwork()) {
                return@launch
            }

            if (!probeMixedProxy()) {
                restartFromWatchdog(reason)
            }
        }
    }

    private suspend fun restartFromWatchdog(reason: String) {
        val now = System.currentTimeMillis()
        if (watchdogRestarting || now - lastWatchdogRestartAt < WATCHDOG_RESTART_COOLDOWN_MS) {
            android.util.Log.w("BoxService", "Watchdog: restart skipped by cooldown")
            return
        }

        watchdogRestarting = true
        lastWatchdogRestartAt = now
        try {
            android.util.Log.w("BoxService", "Watchdog: restarting sing-box after $reason")
            refreshKeeperWakeLock("watchdog-restart")
            status.postValue(Status.Starting)
            broadcastStatus(Status.Starting)
            withContext(Dispatchers.Main) {
                notification.show(lastProfileName, "Восстановление соединения...")
            }

            val pfd = fileDescriptor
            if (pfd != null) {
                runCatching { pfd.close() }
                fileDescriptor = null
            }
            runCatching {
                commandServer?.closeService()
            }.onFailure {
                android.util.Log.e("BoxService", "Watchdog: closeService failed", it)
            }

            delay(900L)
            startService()
        } finally {
            watchdogRestarting = false
        }
    }

    private fun probeMixedProxy(): Boolean {
        val targets = arrayOf(
            "cp.cloudflare.com" to "/generate_204",
            "www.gstatic.com" to "/generate_204",
            "connectivitycheck.gstatic.com" to "/generate_204"
        )

        for ((host, path) in targets) {
            var rawSocket: Socket? = null
            var tlsSocket: SSLSocket? = null
            try {
                rawSocket = Socket()
                rawSocket.connect(
                    InetSocketAddress("127.0.0.1", WATCHDOG_MIXED_PROXY_PORT),
                    2500
                )
                rawSocket.soTimeout = 3500
                val connectRequest = "CONNECT $host:443 HTTP/1.1\r\n" +
                    "Host: $host:443\r\n" +
                    "Connection: close\r\n\r\n"
                rawSocket.getOutputStream().write(connectRequest.toByteArray(Charsets.US_ASCII))
                rawSocket.getOutputStream().flush()
                val connectReader = rawSocket.getInputStream().bufferedReader(Charsets.US_ASCII)
                val connectStatus = connectReader.readLine()
                if (connectStatus?.contains(" 200 ") != true) {
                    android.util.Log.w("BoxService", "Watchdog CONNECT status: $connectStatus")
                    continue
                }
                while (true) {
                    val header = connectReader.readLine() ?: break
                    if (header.isEmpty()) break
                }

                tlsSocket = (SSLSocketFactory.getDefault() as SSLSocketFactory)
                    .createSocket(rawSocket, host, 443, true) as SSLSocket
                tlsSocket.soTimeout = 4500
                tlsSocket.startHandshake()
                val request = "GET $path HTTP/1.1\r\n" +
                    "Host: $host\r\n" +
                    "User-Agent: YurichConnectNativeKeeper/1\r\n" +
                    "Connection: close\r\n\r\n"
                tlsSocket.getOutputStream().write(request.toByteArray(Charsets.US_ASCII))
                tlsSocket.getOutputStream().flush()
                val responseStatus = tlsSocket.getInputStream()
                    .bufferedReader(Charsets.US_ASCII)
                    .readLine()
                if (responseStatus?.startsWith("HTTP/") == true &&
                    (responseStatus.contains(" 204 ") || responseStatus.contains(" 200 "))
                ) {
                    return true
                }
                android.util.Log.w("BoxService", "Watchdog HTTPS status: $responseStatus")
            } catch (e: Exception) {
                android.util.Log.w("BoxService", "Watchdog probe failed for $host: ${e.message}")
            } finally {
                runCatching { tlsSocket?.close() }
                runCatching { rawSocket?.close() }
            }
        }

        return false
    }

    private fun hasDefaultNetwork(): Boolean {
        if (DefaultNetworkMonitor.defaultNetwork != null) {
            return true
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            val activeNetwork = runCatching { Application.connectivity.activeNetwork }.getOrNull()
            if (activeNetwork != null) {
                DefaultNetworkMonitor.defaultNetwork = activeNetwork
                return true
            }
        }
        return false
    }

    private fun watchdogDelayMs(): Long {
        return if (isDeviceIdleMode()) WATCHDOG_IDLE_INTERVAL_MS else WATCHDOG_INTERVAL_MS
    }

    private fun settleDelayFor(reason: String): Long {
        return if (
            reason.contains("CONNECTIVITY_ACTION") ||
            reason.contains("network", ignoreCase = true) ||
            reason.contains("idle", ignoreCase = true)
        ) {
            NETWORK_SETTLE_DELAY_MS
        } else {
            WAKE_SETTLE_DELAY_MS
        }
    }

    private fun isDeviceIdleMode(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
            return false
        }
        return runCatching {
            val powerManager = service.getSystemService(Context.POWER_SERVICE) as PowerManager
            powerManager.isDeviceIdleMode
        }.getOrDefault(false)
    }

    private fun refreshKeeperWakeLock(reason: String) {
        try {
            val powerManager = service.getSystemService(Context.POWER_SERVICE) as PowerManager
            val wakeLock = keeperWakeLock ?: powerManager.newWakeLock(
                PowerManager.PARTIAL_WAKE_LOCK,
                "YurichConnect:VpnKeeper"
            ).apply {
                setReferenceCounted(false)
                keeperWakeLock = this
            }

            if (wakeLock.isHeld) {
                runCatching { wakeLock.release() }
            }
            wakeLock.acquire(KEEPER_WAKE_LOCK_MS)
            android.util.Log.d("BoxService", "Keeper wake lock refreshed: $reason")
        } catch (e: Exception) {
            android.util.Log.w("BoxService", "Keeper wake lock failed: ${e.message}")
        }
    }

    private fun releaseKeeperWakeLock() {
        val wakeLock = keeperWakeLock ?: return
        if (wakeLock.isHeld) {
            runCatching { wakeLock.release() }
        }
        keeperWakeLock = null
    }

    private fun scheduleStickyRestart(reason: String) {
        android.util.Log.w("BoxService", "Scheduling sticky restart after $reason")
        Handler(Looper.getMainLooper()).postDelayed({
            val shouldRestore = runCatching {
                SimpleConfigManager.getStartedByUser() && SimpleConfigManager.hasValidConfig()
            }.getOrDefault(false)
            if (!shouldRestore) {
                android.util.Log.w("BoxService", "Sticky restart skipped: user flag/config missing")
                return@postDelayed
            }

            val intent = Intent(service.applicationContext, Settings.serviceClass()).apply {
                action = ACTION_START
            }
            ContextCompat.startForegroundService(service.applicationContext, intent)
        }, STICKY_RESTART_DELAY_MS)
    }
}
