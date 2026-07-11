package com.tecclub.flutter_singbox.bg

import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
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
import com.tecclub.flutter_singbox.session.VpnSessionPhase
import com.tecclub.flutter_singbox.session.VpnSessionStateMachine
import com.tecclub.flutter_singbox.xray.XrayRuntimeConfig
import com.tecclub.flutter_singbox.xray.XrayRunner
import io.nekohasekai.libbox.CommandServer
import io.nekohasekai.libbox.CommandServerHandler
import io.nekohasekai.libbox.Libbox
import io.nekohasekai.libbox.OverrideOptions
import io.nekohasekai.libbox.PlatformInterface
import io.nekohasekai.libbox.SystemProxyStatus
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import java.net.InetSocketAddress
import java.net.Socket
import javax.net.ssl.SSLSocket
import javax.net.ssl.SSLSocketFactory
import java.security.MessageDigest

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
        private const val NETWORK_WAKE_GRACE_MS = 45_000L
        private const val NETWORK_WAKE_PROBE_ATTEMPTS = 3
        private const val NETWORK_WAKE_PROBE_DELAY_MS = 4_000L
        private const val LIFECYCLE_RECOVERY_TIMEOUT_MS = 30_000L

        fun start() {
            val intent = Intent(Application.application, Settings.serviceClass()).apply {
                action = ACTION_START
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
    private var xrayRunner: XrayRunner? = null
    private val serviceScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val sessionState = VpnSessionStateMachine()
    private val lifecycleMutex = Mutex()
    private var lifecycleJob: Job? = null
    private var watchdogJob: Job? = null
    private var watchdogFailures = 0
    private var watchdogMixedProxyEnabled = false
    private var lastWatchdogRestartAt = 0L
    private var lastNetworkWakeEventAt = 0L
    private var lastStartAttemptAt = 0L
    private var lastStopAttemptAt = 0L
    @Volatile private var watchdogRestarting = false
    private var keeperWakeLock: PowerManager.WakeLock? = null
    private var receiverRegistered = false
    private var lastConfigFingerprint: String? = null
    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            when (intent.action) {
                Action.SERVICE_CLOSE -> {
                    stopService()
                }

                Action.SERVICE_RESTART -> {
                    serviceScope.launch {
                        if (currentSessionStatus() == Status.Started) {
                            restartFromWatchdog("notification-action")
                        } else if (currentSessionStatus() == Status.Stopped) {
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

    private fun currentSessionStatus(): Status = when (sessionState.snapshot().phase) {
        VpnSessionPhase.Stopped,
        VpnSessionPhase.Failed -> Status.Stopped
        VpnSessionPhase.Starting,
        VpnSessionPhase.Reconnecting -> Status.Starting
        VpnSessionPhase.Connected -> Status.Started
        VpnSessionPhase.Stopping -> Status.Stopping
    }

    private fun publishSessionStatus() {
        val nextStatus = currentSessionStatus()
        status.postValue(nextStatus)
        broadcastStatus(nextStatus)
    }

    private fun ensureCurrentSession(
        generation: Long,
        requireDesiredRunning: Boolean = true,
    ) {
        if (!sessionState.isCurrent(generation, requireDesiredRunning)) {
            throw CancellationException("Stale VPN session generation $generation")
        }
    }

    private fun launchLifecycle(
        generation: Long,
        block: suspend () -> Unit,
    ) {
        lifecycleJob?.cancel()
        lifecycleJob = serviceScope.launch {
            lifecycleMutex.withLock {
                ensureCurrentSession(generation)
                block()
            }
        }
    }

    private fun configFingerprint(config: String): String {
        return MessageDigest.getInstance("SHA-256")
            .digest(config.toByteArray(Charsets.UTF_8))
            .joinToString("") { byte -> "%02x".format(byte) }
    }

    private suspend fun startService(generation: Long) {
        android.util.Log.e("BoxService", "Starting SingBox service...")
        try {
            ensureCurrentSession(generation)
            // withContext(Dispatchers.Main) {
            //     android.util.Log.e("BoxService", "Showing initial notification")
            //     notification.show(lastProfileName, "Starting...")
            // }

            // Load the configuration from the SimpleConfigManager instead of database
            android.util.Log.e("BoxService", "Loading configuration from SimpleConfigManager")
            val content = SimpleConfigManager.getConfig()
            android.util.Log.e("BoxService", "Config loaded, length: ${content.length}")
            // Local mixed inbounds are not guaranteed to be exposed by every
            // Android libbox build. Xray owns a dedicated health HTTP inbound.
            watchdogMixedProxyEnabled = false
            lastConfigFingerprint = configFingerprint(content)
            
            if (content.isBlank() || content == "{}") {
                android.util.Log.e("BoxService", "Empty configuration detected")
                stopAndAlert(Alert.EmptyConfiguration, generation = generation)
                return
            }

            val xrayConfig = XrayRuntimeConfig.from(content)
            if (xrayConfig.enabled) {
                startXrayService(xrayConfig.configJson, generation)
                return
            }

            lastProfileName = "Yurich Connect"
            // withContext(Dispatchers.Main) {
            //     android.util.Log.e("BoxService", "Updating notification with profile name")
            //     // notification.show(lastProfileName, "Starting...")
            // }

            android.util.Log.e("BoxService", "Starting DefaultNetworkMonitor")
            DefaultNetworkMonitor.setNetworkChangeObserver {
                handleNetworkWakeEvent("default-network")
            }
            DefaultNetworkMonitor.start()
            
            android.util.Log.e("BoxService", "Setting memory limit")
            Libbox.setMemoryLimit(true)
            
            android.util.Log.e("BoxService", "Config accepted, length: ${content.length}")

            try {
                commandServer?.startOrReloadService(content, OverrideOptions())
                android.util.Log.e("BoxService", "SingBox service started successfully")
            } catch (e: Exception) {
                android.util.Log.e("BoxService", "Failed to start SingBox service: ${e.message}", e)
                stopAndAlert(Alert.StartService, e.message, generation)
                return
            }

            ensureCurrentSession(generation)
            android.util.Log.e("BoxService", "Posting status as Started")
            if (!sessionState.markConnected(generation, "sing-box-started")) {
                throw CancellationException("Sing-box start completed for stale generation $generation")
            }
            publishSessionStatus()
            
            // Start traffic monitoring
            android.util.Log.e("BoxService", "Starting traffic monitor")
            startTrafficMonitor()
            
            android.util.Log.e("BoxService", "Updating notification to Connected")
            withContext(Dispatchers.Main) {
                notification.show(lastProfileName, "Подключено")
            }
            
            android.util.Log.e("BoxService", "Starting notification")
            notification.start()
            refreshKeeperWakeLock("service-start")
            startNativeWatchdog()
            
            android.util.Log.e("BoxService", "Service startup complete")
        } catch (e: CancellationException) {
            android.util.Log.w("BoxService", "Cancelled stale start generation $generation")
            throw e
        } catch (e: Exception) {
            android.util.Log.e("BoxService", "Uncaught exception in startService: ${e.message}", e)
            stopAndAlert(Alert.StartService, e.message, generation)
            return
        }
    }

    private suspend fun startXrayService(configJson: String, generation: Long) {
        if (service !is VPNService) {
            stopAndAlert(
                Alert.StartService,
                "Xray runtime requires Android VPN service",
                generation,
            )
            return
        }

        try {
            ensureCurrentSession(generation)
            android.util.Log.e("BoxService", "Starting Xray service...")
            lastProfileName = "Yurich Connect XHTTP"
            watchdogMixedProxyEnabled = configJson.contains("\"port\": $WATCHDOG_MIXED_PROXY_PORT")
            DefaultNetworkMonitor.setNetworkChangeObserver {
                handleNetworkWakeEvent("default-network")
            }
            DefaultNetworkMonitor.start()
            val runner = XrayRunner(service)
            xrayRunner = runner
            val response = withContext(Dispatchers.IO) {
                runner.start(configJson)
            }
            android.util.Log.e("BoxService", "Xray service started: $response")

            ensureCurrentSession(generation)
            if (!sessionState.markConnected(generation, "xray-started")) {
                throw CancellationException("Xray start completed for stale generation $generation")
            }
            publishSessionStatus()
            withContext(Dispatchers.Main) {
                notification.show(lastProfileName, "Подключено")
            }
            notification.start()
            refreshKeeperWakeLock("xray-service-start")
            startNativeWatchdog()
        } catch (e: CancellationException) {
            android.util.Log.w("BoxService", "Cancelled stale Xray start generation $generation")
            throw e
        } catch (e: Exception) {
            android.util.Log.e("BoxService", "Failed to start Xray service: ${e.message}", e)
            stopXrayRunner("startXrayService")
            stopAndAlert(Alert.StartService, e.message, generation)
        }
    }

    override fun serviceReload() {
        val reconnect = sessionState.requestReconnect("service-reload") ?: return
        publishSessionStatus()
        launchLifecycle(reconnect.generation) {
            stopNativeWatchdog()
            notification.stop()
            stopXrayRunner("serviceReload")
            runCatching {
                commandServer?.closeService()
            }.onFailure {
                android.util.Log.e("BoxService", "service: error when closing sing-box on reload", it)
            }
            runCatching {
                DefaultNetworkMonitor.stop()
            }.onFailure {
                android.util.Log.e("BoxService", "service: error when stopping network monitor on reload", it)
            }
            closeTunFileDescriptor()
            delay(300L)
            ensureCurrentSession(reconnect.generation)
            startService(reconnect.generation)
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

    private fun closeTunFileDescriptor() {
        val pfd = fileDescriptor ?: return
        runCatching {
            pfd.close()
        }.onFailure {
            android.util.Log.e("BoxService", "service: error when closing tun fd", it)
        }
        fileDescriptor = null
    }

    private fun hasActiveRuntime(): Boolean {
        val xrayActive = runCatching { xrayRunner?.isStarted() == true }
            .getOrDefault(false)
        return xrayActive || fileDescriptor != null ||
            (currentSessionStatus() == Status.Started && commandServer != null)
    }

    private fun shouldRecoverStaleLifecycleState(currentStatus: Status): Boolean {
        if (currentStatus != Status.Starting && currentStatus != Status.Stopping) {
            return false
        }

        val lastAttemptAt = if (currentStatus == Status.Starting) {
            lastStartAttemptAt
        } else {
            lastStopAttemptAt
        }
        val staleByAge = lastAttemptAt == 0L ||
            System.currentTimeMillis() - lastAttemptAt > LIFECYCLE_RECOVERY_TIMEOUT_MS

        return staleByAge && !hasActiveRuntime()
    }

    private fun recoverStaleLifecycleState(currentStatus: Status) {
        android.util.Log.w(
            "BoxService",
            "Recovering stale lifecycle state: $currentStatus"
        )
        stopNativeWatchdog()
        releaseKeeperWakeLock()
        val staleCommandServer = commandServer
        xrayRunner = null
        commandServer = null
        closeTunFileDescriptor()
        notification.stop()
        sessionState.forceStopped("stale-lifecycle-recovery", clearDesiredRunning = false)
        publishSessionStatus()
        android.util.Log.w(
            "BoxService",
            "Stale lifecycle state reset without synchronous native stop"
        )

        if (staleCommandServer != null) {
            serviceScope.launch {
                runCatching {
                    staleCommandServer.closeService()
                }.onFailure {
                    android.util.Log.e("BoxService", "stale recovery: closeService failed", it)
                }
                runCatching {
                    staleCommandServer.close()
                }.onFailure {
                    android.util.Log.e("BoxService", "stale recovery: command server close failed", it)
                }
                runCatching {
                    DefaultNetworkMonitor.stop()
                }.onFailure {
                    android.util.Log.e("BoxService", "stale recovery: network monitor stop failed", it)
                }
            }
        }
    }

    private fun stopXrayRunner(reason: String) {
        val runner = xrayRunner ?: return
        xrayRunner = null
        // Xray/libXray can block while reading from TUN. Close the fd first so Android
        // releases the VPN network promptly and stopXray() can exit its read loop.
        closeTunFileDescriptor()
        runCatching {
            runner.stop()
        }.onFailure {
            android.util.Log.e("BoxService", "$reason: error when stopping xray", it)
        }
    }

    private fun stopService() {
        val currentStatus = currentSessionStatus()
        if (currentStatus != Status.Started && currentStatus != Status.Starting) return
        val stop = sessionState.requestStop("service-close")
        publishSessionStatus()
        lifecycleJob?.cancel()
        stopNativeWatchdog()
        releaseKeeperWakeLock()
        runCatching {
            SimpleConfigManager.setStartedByUser(false)
        }
        lastStopAttemptAt = System.currentTimeMillis()
        if (receiverRegistered) {
            service.unregisterReceiver(receiver)
            receiverRegistered = false
        }
        notification.stop()
        lifecycleJob = serviceScope.launch {
            lifecycleMutex.withLock {
                ensureCurrentSession(stop.generation, requireDesiredRunning = false)
                stopXrayRunner("stopService")
                runCatching {
                    commandServer?.closeService()
                }.onFailure {
                    android.util.Log.e("BoxService", "service: error when closing", it)
                }
                try {
                    DefaultNetworkMonitor.stop()
                } catch (e: Exception) {
                    android.util.Log.e("BoxService", "service: error when stopping network monitor", e)
                }
                closeTunFileDescriptor()

                commandServer?.close()
                commandServer = null
                if (sessionState.markStopped(
                        stop.generation,
                        reason = "service-stopped",
                        clearDesiredRunning = true,
                    )
                ) {
                    publishSessionStatus()
                }
                withContext(Dispatchers.Main) {
                    service.stopSelf()
                }
            }
        }
    }

    private suspend fun stopAndAlert(
        type: Alert,
        message: String? = null,
        generation: Long = sessionState.snapshot().generation,
    ) {
        android.util.Log.e("BoxService", "stopAndAlert called: ${type.name}, message: $message")
        if (!sessionState.markFailed(
                generation,
                reason = "${type.name}:${message.orEmpty()}",
                keepDesiredRunning = false,
            )
        ) {
            android.util.Log.w("BoxService", "Ignoring alert from stale generation $generation")
            return
        }
        publishSessionStatus()
        stopNativeWatchdog()
        releaseKeeperWakeLock()
        runCatching {
            SimpleConfigManager.setStartedByUser(false)
        }
        stopXrayRunner("stopAndAlert")
        runCatching {
            commandServer?.closeService()
        }.onFailure {
            android.util.Log.e("BoxService", "stopAndAlert: error when closing sing-box", it)
        }
        try {
            DefaultNetworkMonitor.stop()
        } catch (e: Exception) {
            android.util.Log.e("BoxService", "stopAndAlert: error when stopping network monitor", e)
        }
        closeTunFileDescriptor()
        runCatching {
            commandServer?.close()
            commandServer = null
        }.onFailure {
            android.util.Log.e("BoxService", "stopAndAlert: error when closing command server", it)
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
            
            // Stop the service itself
            android.util.Log.e("BoxService", "Stopping service")
            service.stopSelf()
            
            android.util.Log.e("BoxService", "Alert handling complete")
        }
    }

    @Suppress("SameReturnValue")
    internal fun onStartCommand(): Int {
        Application.initializeIfNeeded(service.applicationContext)
        var currentStatus = currentSessionStatus()
        android.util.Log.e("BoxService", "onStartCommand called, current status: $currentStatus")
        val keepRunning = runCatching { SimpleConfigManager.getStartedByUser() }.getOrDefault(false)
        val incomingConfig = runCatching { SimpleConfigManager.getConfig() }.getOrDefault("{}")
        val incomingFingerprint = runCatching {
            configFingerprint(incomingConfig)
        }.getOrDefault("")

        if (currentStatus != Status.Stopped) {
            if (shouldRecoverStaleLifecycleState(currentStatus)) {
                recoverStaleLifecycleState(currentStatus)
                currentStatus = currentSessionStatus()
            } else {
                val hasConfigChange = lastConfigFingerprint != null &&
                    !incomingConfig.isBlank() &&
                    incomingConfig != "{}" &&
                    incomingFingerprint.isNotEmpty() &&
                    incomingFingerprint != (lastConfigFingerprint ?: "")

                if (hasConfigChange) {
                    android.util.Log.e(
                        "BoxService",
                        "Runtime config changed while service is ${currentStatus.name}; reloading"
                    )
                    ensureReceiversRegistered()
                    refreshRunningService("on-start-command-reload")
                    serviceReload()
                } else {
                    android.util.Log.e("BoxService", "Service already running, reusing config")
                    val notificationTitle = lastProfileName.ifBlank { "Yurich Connect" }
                    val notificationText = if (currentStatus == Status.Started) {
                        "Подключено"
                    } else {
                        "Подключение..."
                    }
                    notification.show(notificationTitle, notificationText)
                    ensureReceiversRegistered()
                    refreshRunningService("on-start-command-existing")
                }
                return if (keepRunning) Service.START_STICKY else Service.START_NOT_STICKY
            }
        }

        // CRITICAL: Call startForeground IMMEDIATELY to prevent Android from killing the app
        // This must happen synchronously before any async work
        android.util.Log.e("BoxService", "Starting foreground notification immediately")
        notification.show("Yurich Connect", "Подключение...")

        android.util.Log.e("BoxService", "Setting status to Starting")
        val start = sessionState.requestStart("on-start-command")
        lastStartAttemptAt = System.currentTimeMillis()
        publishSessionStatus()

        ensureReceiversRegistered()

        android.util.Log.e("BoxService", "Launching IO coroutine for service startup")
        launchLifecycle(start.generation) {
            try {
                val runtimeConfig = XrayRuntimeConfig.from(SimpleConfigManager.getConfig())
                if (runtimeConfig.enabled) {
                    android.util.Log.e(
                        "BoxService",
                        "Xray config detected, skipping sing-box command server"
                    )
                } else {
                    android.util.Log.e("BoxService", "Ensuring libbox initialization")
                    Application.ensureLibboxInitialized(service.applicationContext)
                    android.util.Log.e("BoxService", "Starting command server")
                    startCommandServer()
                }
            } catch (e: Exception) {
                android.util.Log.e("BoxService", "Failed to start command server: ${e.message}", e)
                stopAndAlert(Alert.StartCommandServer, e.message, start.generation)
                return@launchLifecycle
            }

            ensureCurrentSession(start.generation)
            android.util.Log.e("BoxService", "Calling startService()")
            startService(start.generation)
        }
        return if (keepRunning) Service.START_STICKY else Service.START_NOT_STICKY
    }

    private fun ensureReceiversRegistered() {
        if (receiverRegistered) {
            return
        }
        android.util.Log.e("BoxService", "Registering broadcast receivers")
        ContextCompat.registerReceiver(service, receiver, IntentFilter().apply {
            addAction(Action.SERVICE_CLOSE)
            addAction(Action.SERVICE_RESTART)
            addAction(Intent.ACTION_SCREEN_ON)
            addAction(Intent.ACTION_USER_PRESENT)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                addAction(PowerManager.ACTION_DEVICE_IDLE_MODE_CHANGED)
            }
        }, ContextCompat.RECEIVER_NOT_EXPORTED)
        receiverRegistered = true
    }

    private fun refreshRunningService(reason: String) {
        refreshKeeperWakeLock(reason)
        commandServer?.wake()
        if (currentSessionStatus() == Status.Started && watchdogJob?.isActive != true) {
            android.util.Log.w("BoxService", "Restarting missing watchdog after $reason")
            startNativeWatchdog()
        }
    }

    internal fun onBind(): android.os.Binder {
        return binder
    }

    internal fun onDestroy() {
        val destroyStatus = currentSessionStatus()
        val shouldRestore = runCatching {
            destroyStatus == Status.Started &&
                SimpleConfigManager.getStartedByUser() &&
                SimpleConfigManager.hasValidConfig()
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
        stopXrayRunner("onDestroy")
        runCatching {
            commandServer?.closeService()
            commandServer?.close()
            commandServer = null
        }
        DefaultNetworkMonitor.stopAsync()
        closeTunFileDescriptor()
        sessionState.forceStopped("service-destroyed", clearDesiredRunning = !shouldRestore)
        publishSessionStatus()
        binder.close()
        if (shouldRestore) {
            scheduleStickyRestart("service-destroyed")
        }
    }

    internal fun onTaskRemoved() {
        android.util.Log.w(
            "BoxService",
            "Task removed; keeping current foreground VPN service without sticky restart"
        )
        ensureReceiversRegistered()
        refreshRunningService("task-removed")
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
            while (isActive && currentSessionStatus() == Status.Started) {
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

                if (isNetworkWakeGraceWindow()) {
                    watchdogFailures = 0
                    android.util.Log.d("BoxService", "Watchdog: waiting for network wake settle")
                    delay(10_000L)
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
        if (currentSessionStatus() != Status.Started || watchdogRestarting) {
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
            if (currentSessionStatus() != Status.Started || !hasDefaultNetwork()) {
                return@launch
            }

            repeat(NETWORK_WAKE_PROBE_ATTEMPTS) { attempt ->
                if (currentSessionStatus() != Status.Started || !hasDefaultNetwork()) {
                    return@launch
                }
                if (probeMixedProxy()) {
                    watchdogFailures = 0
                    android.util.Log.d(
                        "BoxService",
                        "Watchdog: network/wake probe recovered after $reason"
                    )
                    return@launch
                }
                android.util.Log.w(
                    "BoxService",
                    "Watchdog: network/wake probe failed ${attempt + 1}/$NETWORK_WAKE_PROBE_ATTEMPTS after $reason"
                )
                if (attempt + 1 < NETWORK_WAKE_PROBE_ATTEMPTS) {
                    delay(NETWORK_WAKE_PROBE_DELAY_MS)
                }
            }
            restartFromWatchdog(reason)
        }
    }

    private suspend fun restartFromWatchdog(reason: String) {
        val now = System.currentTimeMillis()
        if (watchdogRestarting || now - lastWatchdogRestartAt < WATCHDOG_RESTART_COOLDOWN_MS) {
            android.util.Log.w("BoxService", "Watchdog: restart skipped by cooldown")
            return
        }

        val reconnect = sessionState.requestReconnect("watchdog:$reason") ?: run {
            android.util.Log.w("BoxService", "Watchdog: restart rejected by session state")
            return
        }
        watchdogRestarting = true
        lastWatchdogRestartAt = now
        publishSessionStatus()
        try {
            lifecycleMutex.withLock {
                ensureCurrentSession(reconnect.generation)
                android.util.Log.w("BoxService", "Watchdog: restarting sing-box after $reason")
                refreshKeeperWakeLock("watchdog-restart")
                withContext(Dispatchers.Main) {
                    notification.show(lastProfileName, "Восстановление соединения...")
                }

                stopXrayRunner("watchdog-restart")
                runCatching {
                    commandServer?.closeService()
                }.onFailure {
                    android.util.Log.e("BoxService", "Watchdog: closeService failed", it)
                }
                try {
                    DefaultNetworkMonitor.stop()
                } catch (e: Exception) {
                    android.util.Log.e("BoxService", "Watchdog: network monitor stop failed", e)
                }
                closeTunFileDescriptor()

                delay(900L)
                ensureCurrentSession(reconnect.generation)
                startService(reconnect.generation)
            }
        } catch (e: CancellationException) {
            android.util.Log.w("BoxService", "Watchdog restart cancelled for stale generation")
            throw e
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
            reason.contains("network", ignoreCase = true) ||
            reason.contains("idle", ignoreCase = true)
        ) {
            NETWORK_SETTLE_DELAY_MS
        } else {
            WAKE_SETTLE_DELAY_MS
        }
    }

    private fun isNetworkWakeGraceWindow(): Boolean {
        val lastEventAt = lastNetworkWakeEventAt
        return lastEventAt > 0L &&
            System.currentTimeMillis() - lastEventAt < NETWORK_WAKE_GRACE_MS
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
