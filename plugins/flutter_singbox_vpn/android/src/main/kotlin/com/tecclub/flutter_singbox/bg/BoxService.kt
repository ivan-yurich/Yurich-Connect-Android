package com.tecclub.flutter_singbox.bg

import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.Network
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.os.PowerManager
import android.os.SystemClock
import androidx.annotation.RequiresApi
import androidx.core.content.ContextCompat
import androidx.lifecycle.MutableLiveData
import com.tecclub.flutter_singbox.Application
import com.tecclub.flutter_singbox.config.SimpleConfigManager
import com.tecclub.flutter_singbox.config.SingBoxRuntimeConfig
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
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.cancel
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import java.net.InetSocketAddress
import java.net.Socket
import java.security.MessageDigest
import java.util.concurrent.atomic.AtomicLong
import javax.net.ssl.SSLSocket
import javax.net.ssl.SSLSocketFactory
import kotlin.system.exitProcess

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
        private const val WATCHDOG_FLAP_WINDOW_MS = 5 * 60 * 1000L
        private const val WATCHDOG_FLAP_RESTART_THRESHOLD = 4
        // Both embedded runtimes expose the mixed proxy in well under 500 ms on
        // supported devices. Keep a small settle window, then rely on the real
        // 2-of-3 external quorum instead of an unconditional startup sleep.
        private const val READINESS_INITIAL_DELAY_MS = 750L
        private const val READINESS_RETRY_DELAY_MS = 3_000L
        private const val READINESS_BACKGROUND_RETRY_MS = 20_000L
        private const val READINESS_PROBE_ATTEMPTS = 2
        private const val READINESS_STARTUP_RESTART_GRACE_MS = 30_000L
        private const val HEALTH_CONNECT_TIMEOUT_MS = 2_000
        private const val HEALTH_PROXY_RESPONSE_TIMEOUT_MS = 3_000
        private const val HEALTH_TLS_TIMEOUT_MS = 4_000
        // Keep the CPU awake only while starting/recovering a tunnel. A healthy
        // foreground VPN must be allowed to enter Doze instead of extending this
        // lock from every periodic health probe.
        private const val KEEPER_WAKE_LOCK_MS = 60_000L
        private const val STICKY_RESTART_DELAY_MS = 2_500L
        private const val NETWORK_RESET_DELAY_MS = 250L
        private const val NETWORK_SETTLE_DELAY_MS = 6_000L
        private const val WAKE_SETTLE_DELAY_MS = 3_000L
        private const val NETWORK_WAKE_DEBOUNCE_MS = 5_000L
        private const val NETWORK_WAKE_GRACE_MS = 45_000L
        private const val LIFECYCLE_RECOVERY_TIMEOUT_MS = 30_000L
        private const val CORE_PROCESS_EXIT_DELAY_MS = 600L
        @Volatile private var processRuntimeCore: VpnRuntimeCore? = null

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
        ServiceNotification(service)
    }
    private var commandServer: CommandServer? = null
    private var xrayRunner: XrayRunner? = null
    private val serviceScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val sessionState = VpnSessionStateMachine()
    private val lifecycleMutex = Mutex()
    private var lifecycleJob: Job? = null
    private var watchdogJob: Job? = null
    private var networkResetJob: Job? = null
    @Volatile private var readinessJob: Job? = null
    private val readinessRevision = AtomicLong(0L)
    private var watchdogFailures = 0
    private val watchdogFlapDetector = TunnelFlapDetector(
        threshold = WATCHDOG_FLAP_RESTART_THRESHOLD,
        windowMs = WATCHDOG_FLAP_WINDOW_MS,
    )
    private val networkResetTracker = NetworkResetTracker<Network>()
    private var watchdogMixedProxyEnabled = false
    private var lastNetworkWakeEventAt = 0L
    private var lastStartAttemptAt = 0L
    private var lastStartAttemptAtElapsed = 0L
    private var lastStopAttemptAt = 0L
    @Volatile private var watchdogRestarting = false
    @Volatile private var stickyRestartScheduled = false
    @Volatile private var cleanProcessRestartScheduled = false
    @Volatile private var lastHealthyDefaultNetwork: Network? = null
    private var keeperWakeLock: PowerManager.WakeLock? = null
    private var receiverRegistered = false
    private var lastConfigFingerprint: String? = null
    private var activeRuntimeCore: VpnRuntimeCore? = null
    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            when (intent.action) {
                Action.SERVICE_CLOSE -> {
                    if (intent.getBooleanExtra(Action.EXTRA_USER_INITIATED, false)) {
                        SimpleConfigManager.setStartedByUser(false)
                        SimpleConfigManager.setManualDisconnectRequested(true)
                    }
                    stopService()
                }

                Action.SERVICE_RESTART -> {
                    if (intent.getBooleanExtra(Action.EXTRA_USER_INITIATED, false)) {
                        SimpleConfigManager.setStartedByUser(true)
                        SimpleConfigManager.setManualDisconnectRequested(false)
                    }
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

    private fun closeCommandServer(reason: String) {
        val staleCommandServer = commandServer ?: return
        commandServer = null
        runCatching {
            staleCommandServer.closeService()
        }.onFailure {
            android.util.Log.e("BoxService", "$reason: closeService failed", it)
        }
        runCatching {
            staleCommandServer.close()
        }.onFailure {
            android.util.Log.e("BoxService", "$reason: command server close failed", it)
        }
    }

    @Volatile private var lastProfileName = ""

    private fun currentProfileName(): String {
        val persistedName = SimpleConfigManager.getActiveProfileName()
        if (persistedName.isNotBlank()) {
            lastProfileName = persistedName
        }
        return lastProfileName.ifBlank { "Yurich Connect" }
    }

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
            watchdogMixedProxyEnabled = SingBoxRuntimeConfig.exposesMixedProxy(
                content,
                WATCHDOG_MIXED_PROXY_PORT,
            )
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
            activeRuntimeCore = VpnRuntimeCore.SingBox
            processRuntimeCore = VpnRuntimeCore.SingBox

            Application.ensureLibboxInitialized(service.applicationContext)
            verifyNativeRuntimeIsolation(VpnRuntimeCore.SingBox)
            startCommandServer()
            val activeCommandServer = checkNotNull(commandServer) {
                "Command server is unavailable after initialization"
            }

            lastProfileName = SimpleConfigManager.getActiveProfileName()
                .ifBlank { "Yurich Connect" }
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
                activeCommandServer.startOrReloadService(content, OverrideOptions())
                android.util.Log.e("BoxService", "SingBox service started successfully")
            } catch (e: Exception) {
                android.util.Log.e("BoxService", "Failed to start SingBox service: ${e.message}", e)
                stopAndAlert(Alert.StartService, e.message, generation)
                return
            }

            ensureCurrentSession(generation)
            android.util.Log.i(
                "BoxService",
                "Sing-box runtime started; waiting for external tunnel readiness"
            )
            android.util.Log.e("BoxService", "Starting traffic monitor")
            startTrafficMonitor()

            withContext(Dispatchers.Main) {
                notification.show(currentProfileName(), "Проверка соединения...")
            }
            refreshKeeperWakeLock("service-start")
            startReadinessValidation(
                generation = generation,
                reason = "sing-box-start",
                initialDelayMs = READINESS_INITIAL_DELAY_MS,
                demoteUntilReady = true,
            )

            android.util.Log.e("BoxService", "Service startup waiting for readiness")
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
            activeRuntimeCore = VpnRuntimeCore.Xray
            processRuntimeCore = VpnRuntimeCore.Xray
            android.util.Log.e("BoxService", "Starting Xray service...")
            lastProfileName = SimpleConfigManager.getActiveProfileName()
                .ifBlank { "Yurich Connect XHTTP" }
            watchdogMixedProxyEnabled = XrayRuntimeConfig.exposesHttpProxy(
                configJson,
                WATCHDOG_MIXED_PROXY_PORT,
            )
            DefaultNetworkMonitor.setNetworkChangeObserver {
                handleNetworkWakeEvent("default-network")
            }
            DefaultNetworkMonitor.start()
            val runner = XrayRunner(service)
            xrayRunner = runner
            val response = withContext(Dispatchers.IO) {
                runner.start(configJson)
            }
            verifyNativeRuntimeIsolation(VpnRuntimeCore.Xray)
            android.util.Log.e("BoxService", "Xray service started: $response")

            ensureCurrentSession(generation)
            withContext(Dispatchers.Main) {
                notification.show(currentProfileName(), "Проверка соединения...")
            }
            refreshKeeperWakeLock("xray-service-start")
            startReadinessValidation(
                generation = generation,
                reason = "xray-start",
                initialDelayMs = READINESS_INITIAL_DELAY_MS,
                demoteUntilReady = true,
            )
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
            recycleVpnService("service-reload", reconnect.generation)
        }
    }

    private suspend fun recycleVpnService(
        reason: String,
        generation: Long,
        incomingRuntimeCore: VpnRuntimeCore? = null,
    ) {
        ensureCurrentSession(generation)
        val targetRuntimeCore = incomingRuntimeCore ?: VpnRuntimeCorePolicy.classify(
            runCatching { SimpleConfigManager.getConfig() }.getOrDefault("{}"),
        )
        val previousRuntimeCore = processRuntimeCore ?: activeRuntimeCore
        val watchdogRecovery = reason.startsWith("watchdog:")
        if (
            watchdogRecovery ||
            VpnRuntimeCorePolicy.requiresCleanProcess(previousRuntimeCore, targetRuntimeCore)
        ) {
            // A watchdog can be recovering a blocked Go/JNI runtime. Graceful
            // in-process teardown is not cancellable once JNI blocks and would
            // hold lifecycleMutex forever, so use the isolated-process escape
            // hatch for confirmed health recovery. Routine same-core config
            // switches still recycle in-process without an exit_self event.
            withContext(Dispatchers.Main) {
                restartInCleanProcess(
                    "$reason:${previousRuntimeCore?.name}->${targetRuntimeCore.name}",
                )
            }
            return
        }

        restartRuntimeInProcess(reason, generation, targetRuntimeCore)
    }

    private suspend fun restartRuntimeInProcess(
        reason: String,
        generation: Long,
        targetRuntimeCore: VpnRuntimeCore,
    ) {
        ensureCurrentSession(generation)
        android.util.Log.w(
            "BoxService",
            "Recycling ${targetRuntimeCore.name} runtime in the current VPN process after $reason",
        )
        stopNativeWatchdog(clearRestarting = false)
        refreshKeeperWakeLock("runtime-recycle")
        withContext(Dispatchers.Main) {
            notification.show(currentProfileName(), "Восстановление соединения...")
        }

        stopXrayRunner("runtime recycle after $reason")
        closeCommandServer("runtime recycle after $reason")
        try {
            DefaultNetworkMonitor.stop()
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            android.util.Log.e("BoxService", "$reason: network monitor stop failed", e)
        }
        closeTunFileDescriptor()
        activeRuntimeCore = null

        ensureCurrentSession(generation)
        startService(generation)
    }

    override fun serviceStop() {
        android.util.Log.d("BoxService", "Native service requested runtime stop")
        readinessRevision.incrementAndGet()
        readinessJob?.cancel()
        readinessJob = null
        stopNativeWatchdog()
        closeTunFileDescriptor()
        runCatching {
            commandServer?.closeService()
        }.onFailure {
            android.util.Log.e("BoxService", "Native runtime stop failed", it)
        }
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
        Application.initializeBaseIfNeeded(service.applicationContext)
        var currentStatus = currentSessionStatus()
        android.util.Log.e("BoxService", "onStartCommand called, current status: $currentStatus")
        val keepRunning = runCatching { SimpleConfigManager.getStartedByUser() }.getOrDefault(false)
        val incomingConfig = runCatching { SimpleConfigManager.getConfig() }.getOrDefault("{}")
        val incomingFingerprint = runCatching {
            configFingerprint(incomingConfig)
        }.getOrDefault("")
        val incomingRuntimeCore = VpnRuntimeCorePolicy.classify(incomingConfig)

        if (
            currentStatus == Status.Stopped &&
            VpnRuntimeCorePolicy.requiresCleanProcess(
                previous = processRuntimeCore,
                incoming = incomingRuntimeCore,
            )
        ) {
            restartInCleanProcess(
                "stopped-runtime-switch:${processRuntimeCore?.name}->${incomingRuntimeCore.name}",
            )
            return Service.START_NOT_STICKY
        }

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
                    val reconnect = sessionState.requestReconnect("runtime-config-switch")
                        ?: return if (keepRunning) {
                            Service.START_STICKY
                        } else {
                            Service.START_NOT_STICKY
                        }
                    publishSessionStatus()
                    launchLifecycle(reconnect.generation) {
                        recycleVpnService(
                            reason = "runtime-config-switch",
                            generation = reconnect.generation,
                            incomingRuntimeCore = incomingRuntimeCore,
                        )
                    }
                    return if (keepRunning) Service.START_STICKY else Service.START_NOT_STICKY
                } else {
                    android.util.Log.e("BoxService", "Service already running, reusing config")
                    val notificationTitle = currentProfileName()
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
        lastStartAttemptAtElapsed = SystemClock.elapsedRealtime()
        publishSessionStatus()

        ensureReceiversRegistered()

        android.util.Log.e("BoxService", "Launching IO coroutine for service startup")
        launchLifecycle(start.generation) {
            try {
                val runtimeConfig = XrayRuntimeConfig.from(SimpleConfigManager.getConfig())
                activeRuntimeCore = if (runtimeConfig.enabled) {
                    VpnRuntimeCore.Xray
                } else {
                    VpnRuntimeCore.SingBox
                }
                if (runtimeConfig.enabled) {
                    android.util.Log.e(
                        "BoxService",
                        "Xray config detected, skipping sing-box command server"
                    )
                } else {
                    // Record the process owner before the first native library
                    // load. If initialization fails halfway through, a later
                    // Xray start must still force a clean VPN process instead
                    // of loading both Go runtimes into the same process.
                    processRuntimeCore = VpnRuntimeCore.SingBox
                    android.util.Log.e("BoxService", "Ensuring libbox initialization")
                    Application.ensureLibboxInitialized(service.applicationContext)
                    verifyNativeRuntimeIsolation(VpnRuntimeCore.SingBox)
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

    private fun restartInCleanProcess(reason: String) {
        if (cleanProcessRestartScheduled) {
            android.util.Log.d("BoxService", "Clean VPN process restart already scheduled")
            return
        }
        cleanProcessRestartScheduled = true
        android.util.Log.w(
            "BoxService",
            "Restarting the VPN process cleanly after $reason",
        )

        readinessRevision.incrementAndGet()
        readinessJob?.cancel()
        readinessJob = null
        stopNativeWatchdog()
        releaseKeeperWakeLock()
        notification.show("Yurich Connect", "Переключение протокола...")

        service.sendBroadcast(
            Intent(service, VpnProcessRestartReceiver::class.java).apply {
                action = VpnProcessRestartReceiver.ACTION_RESTART_CLEAN_PROCESS
            }
        )
        closeTunFileDescriptor()
        service.stopSelf()
        Handler(Looper.getMainLooper()).postDelayed({
            android.util.Log.i("BoxService", "Exiting old VPN process after $reason")
            exitProcess(0)
        }, CORE_PROCESS_EXIT_DELAY_MS)
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
        val snapshot = sessionState.snapshot()
        if (snapshot.phase == VpnSessionPhase.Connected && watchdogJob?.isActive != true) {
            android.util.Log.w("BoxService", "Restarting missing watchdog after $reason")
            startNativeWatchdog()
        } else if (
            (snapshot.phase == VpnSessionPhase.Starting ||
                snapshot.phase == VpnSessionPhase.Reconnecting) &&
            readinessJob?.isActive != true &&
            hasActiveRuntime()
        ) {
            android.util.Log.w("BoxService", "Restarting missing readiness check after $reason")
            startReadinessValidation(
                generation = snapshot.generation,
                reason = reason,
                initialDelayMs = READINESS_INITIAL_DELAY_MS,
                demoteUntilReady = true,
            )
        }
    }

    internal fun onBind(): android.os.Binder {
        return binder
    }

    internal fun onDestroy() {
        val destroySnapshot = sessionState.snapshot()
        val shouldRestore = runCatching {
            destroySnapshot.desiredRunning &&
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
        val snapshot = sessionState.snapshot()
        Application.application.sendBroadcast(
            Intent(Action.BROADCAST_STATUS_CHANGED).apply {
                `package` = Application.application.packageName
                putExtra(Action.EXTRA_STATUS, nextStatus.ordinal)
                putExtra(Action.EXTRA_SESSION_REASON, snapshot.reason)
                putExtra(Action.EXTRA_DESIRED_RUNNING, snapshot.desiredRunning)
                SimpleConfigManager.getManualDisconnectRequested()?.let {
                    putExtra(Action.EXTRA_MANUAL_DISCONNECT_REQUESTED, it)
                }
            }
        )
    }

    private suspend fun markRuntimeReady(generation: Long, reason: String): Boolean {
        ensureCurrentSession(generation)
        val snapshot = sessionState.snapshot()
        val wasConnected = snapshot.phase == VpnSessionPhase.Connected
        if (!wasConnected && !sessionState.markConnected(generation, "ready:$reason")) {
            return false
        }

        lastHealthyDefaultNetwork = DefaultNetworkMonitor.defaultNetwork
        networkResetTracker.markCurrent(lastHealthyDefaultNetwork)
        lastStartAttemptAtElapsed = 0L
        watchdogFailures = 0
        if (!wasConnected) {
            android.util.Log.i(
                "BoxService",
                "Tunnel readiness confirmed after $reason; publishing Started"
            )
            publishSessionStatus()
            withContext(Dispatchers.Main) {
                notification.show(currentProfileName(), "Подключено")
            }
        }
        releaseKeeperWakeLock()
        startNativeWatchdog()
        return true
    }

    private fun startReadinessValidation(
        generation: Long,
        reason: String,
        initialDelayMs: Long,
        demoteUntilReady: Boolean,
    ) {
        if (!sessionState.isCurrent(generation)) {
            return
        }

        val snapshot = sessionState.snapshot()
        if (!watchdogMixedProxyEnabled) {
            serviceScope.launch {
                markRuntimeReady(generation, "probe-unavailable:$reason")
            }
            return
        }
        val shouldDemote = demoteUntilReady && snapshot.phase == VpnSessionPhase.Connected
        if (shouldDemote) {
            if (!sessionState.markReconnecting(generation, "readiness:$reason")) {
                return
            }
            publishSessionStatus()
        }

        cancelPeriodicWatchdog()
        val revision = readinessRevision.incrementAndGet()
        readinessJob?.cancel()
        readinessJob = serviceScope.launch {
            var sawDefaultNetwork = false
            try {
                if (demoteUntilReady || snapshot.phase != VpnSessionPhase.Connected) {
                    withContext(Dispatchers.Main) {
                        notification.show(currentProfileName(), "Проверка соединения...")
                    }
                }

                delay(initialDelayMs)
                repeat(READINESS_PROBE_ATTEMPTS) { attempt ->
                    if (!isReadinessCurrent(generation, revision)) {
                        return@launch
                    }

                    val hasNetwork = hasDefaultNetwork()
                    sawDefaultNetwork = sawDefaultNetwork || hasNetwork
                    val probe = if (hasNetwork) probeMixedProxy() else null
                    val healthy = probe?.healthy == true
                    if (healthy) {
                        markRuntimeReady(generation, reason)
                        return@launch
                    }

                    android.util.Log.w(
                        "BoxService",
                        "Readiness probe failed ${attempt + 1}/$READINESS_PROBE_ATTEMPTS after $reason"
                    )
                    if (attempt + 1 < READINESS_PROBE_ATTEMPTS) {
                        delay(READINESS_RETRY_DELAY_MS)
                    }
                }

                if (!isReadinessCurrent(generation, revision)) {
                    return@launch
                }
                withContext(Dispatchers.Main) {
                    notification.show(currentProfileName(), "Восстановление соединения...")
                }

                val startupGraceElapsed =
                    TunnelReadinessPolicy.canRestartAfterStartupGrace(
                        nowMs = SystemClock.elapsedRealtime(),
                        startAttemptAtMs = lastStartAttemptAtElapsed,
                        graceMs = READINESS_STARTUP_RESTART_GRACE_MS,
                    )
                if (!startupGraceElapsed) {
                    android.util.Log.w(
                        "BoxService",
                        "Watchdog: restart deferred during runtime startup grace",
                    )
                }

                serviceScope.launch {
                    val restarted = sawDefaultNetwork && startupGraceElapsed &&
                        restartFromWatchdog("readiness:$reason")
                    if (!restarted && sessionState.isCurrent(generation)) {
                        startReadinessValidation(
                            generation = generation,
                            reason = "retry:$reason",
                            initialDelayMs = READINESS_BACKGROUND_RETRY_MS,
                            demoteUntilReady = true,
                        )
                    }
                }
            } finally {
                if (readinessRevision.get() == revision) {
                    readinessJob = null
                }
            }
        }
    }

    private fun isReadinessCurrent(generation: Long, revision: Long): Boolean {
        return readinessRevision.get() == revision && sessionState.isCurrent(generation)
    }

    private fun cancelPeriodicWatchdog() {
        watchdogJob?.cancel()
        watchdogJob = null
        watchdogFailures = 0
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
                commandServer?.wake()

                if (!hasDefaultNetwork()) {
                    watchdogFailures = 0
                    android.util.Log.w("BoxService", "Watchdog: waiting for default network")
                    withContext(Dispatchers.Main) {
                        notification.show(currentProfileName(), "Ожидание сети...")
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

                val probe = probeMixedProxy()
                val repeatedDegradation = watchdogFlapDetector.record(
                    nowMs = SystemClock.elapsedRealtime(),
                    successfulEndpoints = probe.successfulEndpoints,
                    totalEndpoints = probe.totalEndpoints,
                )
                if (repeatedDegradation) {
                    android.util.Log.w(
                        "BoxService",
                        "Watchdog: repeated degraded quorum; restarting VPN runtime"
                    )
                    if (restartFromWatchdog("repeated-degraded-quorum")) {
                        return@launch
                    }
                }

                val healthy = probe.healthy
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
                    val snapshot = sessionState.snapshot()
                    startReadinessValidation(
                        generation = snapshot.generation,
                        reason = "periodic-health",
                        initialDelayMs = READINESS_RETRY_DELAY_MS,
                        demoteUntilReady = true,
                    )
                    return@launch
                }

                delay(watchdogDelayMs())
            }
        }
    }

    private fun stopNativeWatchdog(clearRestarting: Boolean = true) {
        cancelPeriodicWatchdog()
        networkResetJob?.cancel()
        networkResetJob = null
        readinessRevision.incrementAndGet()
        readinessJob?.cancel()
        readinessJob = null
        if (clearRestarting) {
            watchdogRestarting = false
        }
        lastHealthyDefaultNetwork = null
        networkResetTracker.clear()
        watchdogFlapDetector.reset()
    }

    private fun handleNetworkWakeEvent(reason: String) {
        val snapshot = sessionState.snapshot()
        if (!snapshot.desiredRunning ||
            (snapshot.phase != VpnSessionPhase.Connected &&
                snapshot.phase != VpnSessionPhase.Reconnecting) ||
            watchdogRestarting
        ) {
            return
        }

        val currentDefaultNetwork = DefaultNetworkMonitor.defaultNetwork
        val shouldResetRuntimeNetwork = networkResetTracker.onNetworkEvent(
            currentDefaultNetwork,
        )
        val isDefaultNetworkEvent = reason.contains("default-network", ignoreCase = true)
        val networkChanged = isDefaultNetworkEvent &&
            currentDefaultNetwork != lastHealthyDefaultNetwork
        if (networkChanged) {
            watchdogFlapDetector.reset()
        }
        val alreadyValidating = snapshot.phase == VpnSessionPhase.Reconnecting
        val now = System.currentTimeMillis()
        if (now - lastNetworkWakeEventAt < NETWORK_WAKE_DEBOUNCE_MS &&
            !networkChanged &&
            !alreadyValidating
        ) {
            android.util.Log.d("BoxService", "Watchdog: network/wake event debounced: $reason")
            return
        }
        lastNetworkWakeEventAt = now

        android.util.Log.d(
            "BoxService",
            "Watchdog: network/wake event $reason, changed=$networkChanged"
        )
        refreshKeeperWakeLock(reason)
        if (shouldResetRuntimeNetwork) {
            scheduleRuntimeNetworkReset(
                network = checkNotNull(currentDefaultNetwork),
                generation = snapshot.generation,
            )
        }
        commandServer?.wake()

        // A changed Android default network invalidates the previous outbound
        // readiness result even while the VPN NetworkAgent remains VALIDATED.
        startReadinessValidation(
            generation = snapshot.generation,
            reason = reason,
            initialDelayMs = settleDelayFor(reason),
            demoteUntilReady = networkChanged || alreadyValidating,
        )
    }

    private fun scheduleRuntimeNetworkReset(network: Network, generation: Long) {
        val expectedCommandServer = commandServer ?: return
        networkResetJob?.cancel()
        networkResetJob = serviceScope.launch {
            delay(NETWORK_RESET_DELAY_MS)
            if (!sessionState.isCurrent(generation) ||
                DefaultNetworkMonitor.defaultNetwork != network ||
                commandServer !== expectedCommandServer
            ) {
                return@launch
            }

            runCatching {
                expectedCommandServer.resetNetwork()
            }.onSuccess {
                android.util.Log.i(
                    "BoxService",
                    "Reset sing-box connections after Android default-network change",
                )
            }.onFailure {
                android.util.Log.e(
                    "BoxService",
                    "Unable to reset sing-box after Android network change",
                    it,
                )
            }
            runCatching { expectedCommandServer.wake() }
                .onFailure {
                    android.util.Log.w("BoxService", "Unable to wake sing-box after reset", it)
                }
        }
    }

    private suspend fun restartFromWatchdog(reason: String): Boolean {
        val now = SystemClock.elapsedRealtime()
        val lastRestartAt = SimpleConfigManager.getLastWatchdogRestartAt()
        val networkRecoveryAllowance =
            reason.contains("default-network", ignoreCase = true) &&
                networkResetTracker.hasRecoveryAllowance()
        val restartAllowed = TunnelReadinessPolicy.canRestart(
            nowMs = now,
            lastRestartAtMs = lastRestartAt,
            cooldownMs = WATCHDOG_RESTART_COOLDOWN_MS,
            allowCooldownBypass = networkRecoveryAllowance,
        )
        if (watchdogRestarting ||
            !restartAllowed
        ) {
            android.util.Log.w("BoxService", "Watchdog: restart skipped by cooldown")
            return false
        }

        watchdogRestarting = true
        if (!SimpleConfigManager.setLastWatchdogRestartAt(now)) {
            watchdogRestarting = false
            android.util.Log.e("BoxService", "Watchdog: unable to persist restart cooldown")
            return false
        }
        val reconnect = sessionState.requestReconnect("watchdog:$reason") ?: run {
            SimpleConfigManager.setLastWatchdogRestartAt(lastRestartAt)
            watchdogRestarting = false
            android.util.Log.w("BoxService", "Watchdog: restart rejected by session state")
            return false
        }
        if (networkRecoveryAllowance) {
            networkResetTracker.consumeRecoveryAllowance()
        }
        publishSessionStatus()
        try {
            // A periodic watchdog recovery runs inside watchdogJob itself. Detach
            // that caller before recycleVpnService stops the old watchdog so the
            // in-process restart is not cancelled halfway through teardown.
            if (watchdogJob === currentCoroutineContext()[Job]) {
                watchdogJob = null
            }
            lifecycleMutex.withLock {
                ensureCurrentSession(reconnect.generation)
                android.util.Log.w("BoxService", "Watchdog: restarting VPN runtime after $reason")
                refreshKeeperWakeLock("watchdog-restart")
                withContext(Dispatchers.Main) {
                    notification.show(currentProfileName(), "Восстановление соединения...")
                }
                recycleVpnService("watchdog:$reason", reconnect.generation)
            }
        } catch (e: CancellationException) {
            android.util.Log.w("BoxService", "Watchdog restart cancelled for stale generation")
            throw e
        } finally {
            watchdogRestarting = false
        }
        return true
    }

    private data class TunnelProbeResult(
        val successfulEndpoints: Int,
        val totalEndpoints: Int,
    ) {
        val healthy: Boolean
            get() = TunnelReadinessPolicy.isHealthy(
                successfulEndpoints = successfulEndpoints,
                totalEndpoints = totalEndpoints,
            )
    }

    private suspend fun probeMixedProxy(): TunnelProbeResult = coroutineScope {
        val targets = arrayOf(
            "www.cloudflare.com" to "/cdn-cgi/trace",
            "connectivitycheck.gstatic.com" to "/generate_204",
            "www.google.com" to "/generate_204",
        )
        val results = targets.map { (host, path) ->
            async(Dispatchers.IO) {
                probeMixedProxyEndpoint(host, path)
            }
        }.awaitAll()
        val successfulEndpoints = results.count { it }
        val result = TunnelProbeResult(
            successfulEndpoints = successfulEndpoints,
            totalEndpoints = targets.size,
        )
        android.util.Log.d(
            "BoxService",
            "External readiness quorum: $successfulEndpoints/${targets.size}, healthy=${result.healthy}"
        )
        result
    }

    private fun probeMixedProxyEndpoint(host: String, path: String): Boolean {
        var rawSocket: Socket? = null
        var tlsSocket: SSLSocket? = null
        try {
            rawSocket = Socket()
            rawSocket.connect(
                InetSocketAddress("127.0.0.1", WATCHDOG_MIXED_PROXY_PORT),
                HEALTH_CONNECT_TIMEOUT_MS,
            )
            rawSocket.soTimeout = HEALTH_PROXY_RESPONSE_TIMEOUT_MS
            val connectRequest = "CONNECT $host:443 HTTP/1.1\r\n" +
                "Host: $host:443\r\n" +
                "Connection: close\r\n\r\n"
            rawSocket.getOutputStream().write(connectRequest.toByteArray(Charsets.US_ASCII))
            rawSocket.getOutputStream().flush()
            val connectReader = rawSocket.getInputStream().bufferedReader(Charsets.US_ASCII)
            val connectStatus = connectReader.readLine()
            if (connectStatus?.contains(" 200 ") != true) {
                android.util.Log.w("BoxService", "Watchdog CONNECT status for $host: $connectStatus")
                return false
            }
            while (true) {
                val header = connectReader.readLine() ?: break
                if (header.isEmpty()) break
            }

            tlsSocket = (SSLSocketFactory.getDefault() as SSLSocketFactory)
                .createSocket(rawSocket, host, 443, true) as SSLSocket
            tlsSocket.soTimeout = HEALTH_TLS_TIMEOUT_MS
            tlsSocket.sslParameters = tlsSocket.sslParameters.apply {
                endpointIdentificationAlgorithm = "HTTPS"
            }
            tlsSocket.startHandshake()
            val request = "GET $path HTTP/1.1\r\n" +
                "Host: $host\r\n" +
                "User-Agent: YurichConnectNativeKeeper/2\r\n" +
                "Connection: close\r\n\r\n"
            tlsSocket.getOutputStream().write(request.toByteArray(Charsets.US_ASCII))
            tlsSocket.getOutputStream().flush()
            val responseStatus = tlsSocket.getInputStream()
                .bufferedReader(Charsets.US_ASCII)
                .readLine()
            val successful = responseStatus?.startsWith("HTTP/") == true &&
                (responseStatus.contains(" 204 ") || responseStatus.contains(" 200 "))
            if (!successful) {
                android.util.Log.w("BoxService", "Watchdog HTTPS status for $host: $responseStatus")
            }
            return successful
        } catch (e: Exception) {
            android.util.Log.w("BoxService", "Watchdog probe failed for $host: ${e.message}")
            return false
        } finally {
            runCatching { tlsSocket?.close() }
            runCatching { rawSocket?.close() }
        }
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

    private fun verifyNativeRuntimeIsolation(expected: VpnRuntimeCore) {
        val snapshot = NativeRuntimeIsolation.requireIsolated(expected)
        if (snapshot == null) {
            android.util.Log.w(
                "RuntimeIsolation",
                "RUNTIME_ISOLATION core=${expected.name} maps=unavailable",
            )
            return
        }
        android.util.Log.i(
            "RuntimeIsolation",
            "RUNTIME_ISOLATION core=${expected.name} " +
                "libbox=${snapshot.libboxLoaded} " +
                "libgojni=${snapshot.libgojniLoaded} safe=true",
        )
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
        if (stickyRestartScheduled) {
            android.util.Log.d("BoxService", "Sticky restart already scheduled")
            return
        }
        stickyRestartScheduled = true
        android.util.Log.w("BoxService", "Scheduling sticky restart after $reason")
        Handler(Looper.getMainLooper()).postDelayed({
            stickyRestartScheduled = false
            val shouldRestore = runCatching {
                SimpleConfigManager.getStartedByUser() && SimpleConfigManager.hasValidConfig()
            }.getOrDefault(false)
            if (!shouldRestore) {
                android.util.Log.w("BoxService", "Sticky restart skipped: user flag/config missing")
                return@postDelayed
            }

            val intent = Intent(service.applicationContext, Settings.serviceClass()).apply {
                action = ACTION_START
                putExtra(EXTRA_CONFIG_CONTENT, SimpleConfigManager.getConfig())
            }
            ContextCompat.startForegroundService(service.applicationContext, intent)
        }, STICKY_RESTART_DELAY_MS)
    }
}
