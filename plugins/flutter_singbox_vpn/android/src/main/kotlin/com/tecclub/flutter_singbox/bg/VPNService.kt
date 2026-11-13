package com.tecclub.flutter_singbox.bg

import android.content.Intent
import android.content.pm.PackageManager.NameNotFoundException
import android.net.ProxyInfo
import android.net.VpnService
import android.os.Build
import android.os.IBinder
import android.os.ParcelFileDescriptor
import android.util.Log
import com.tecclub.flutter_singbox.Application
import com.tecclub.flutter_singbox.config.SimpleConfigManager
import com.tecclub.flutter_singbox.config.RuntimeKillSwitchPolicy
import com.tecclub.flutter_singbox.config.KillSwitchIntentStore
import com.tecclub.flutter_singbox.config.SmartRouteApps
import com.tecclub.flutter_singbox.config.StrictProtectionIntent
import com.tecclub.flutter_singbox.constant.Alert
import com.tecclub.flutter_singbox.constant.Action
import io.nekohasekai.libbox.TunOptions
import com.tecclub.flutter_singbox.ktx.toIpPrefix
import com.tecclub.flutter_singbox.ktx.toList
import com.tecclub.flutter_singbox.database.Settings
import io.nekohasekai.libbox.Libbox
import java.io.FileDescriptor
import java.util.concurrent.atomic.AtomicInteger

class VPNService : VpnService(), PlatformInterfaceWrapper {

    companion object {
        private const val TAG = "VPNService"
        private const val PROTECT_LOG_LIMIT = 3
        private val XRAY_TUN_DNS_SERVERS = listOf("1.1.1.1", "8.8.8.8")
        private val protectCallCount = AtomicInteger(0)
    }

    private val service = BoxService(this, this)
    var systemProxyAvailable = false
    var systemProxyEnabled = false
    @Volatile private var nextRuntimeStrict = false
    @Volatile private var nextRuntimeFingerprint: String? = null
    @Volatile private var activeTunStrict = false
    @Volatile private var activeAppRoutes: AppRoutes? = null
    @Volatile private var systemStartSeen = false
    private val protectionHandler = android.os.Handler(android.os.Looper.getMainLooper())
    private val protectionCheck = object : Runnable {
        override fun run() {
            // A Settings change need not restart an already connected VPN.
            // Failure to OBSERVE does not trigger a restart or downgrade policy.
            if (runCatching { service.isRuntimeConnected() && needsRuntimePolicyUpdate() }.getOrDefault(false)) {
                service.serviceReload()
            }
            protectionHandler.postDelayed(this, 3_000L)
        }
    }

    override fun onCreate() {
        super.onCreate()
        protectionHandler.post(protectionCheck)
    }

    private fun liveSystemOn(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return false
        val identity = android.os.Binder.clearCallingIdentity()
        return try { isAlwaysOn || isLockdownEnabled }
        finally { android.os.Binder.restoreCallingIdentity(identity) }
    }

    internal fun systemOwnsLifecycle(): Boolean = systemStartSeen || liveSystemOn()

    private fun strictPolicyRequested(systemStartRequest: Boolean = false): Boolean {
        val persisted = KillSwitchIntentStore.requested(applicationContext)
        val live = liveSystemOn()
        val required = StrictProtectionIntent.required(persisted, systemStartRequest, live)
        if (required && !persisted) KillSwitchIntentStore.setRequested(applicationContext, true)
        return required
    }

    internal fun needsRuntimePolicyUpdate(): Boolean = nextRuntimeStrict != strictPolicyRequested()

    internal fun protectionState(): Map<String, Boolean> {
        check(Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q)
        val tunOpen = runCatching { service.fileDescriptor?.fileDescriptor?.valid() == true }.getOrDefault(false)
        val identity = android.os.Binder.clearCallingIdentity()
        return try { mapOf(
            "alwaysOn" to isAlwaysOn,
            "lockdown" to isLockdownEnabled,
            "strictRuntime" to (activeTunStrict && tunOpen),
            "vpnActive" to service.isDesiredRunning(),
            "tunOpen" to tunOpen,
        ) } finally { android.os.Binder.restoreCallingIdentity(identity) }
    }

    /** A protected or uncertain VPN is out of scope for this pilot. Read only. */
    internal fun hermesPolicyAllows(): Boolean =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q && !systemOwnsLifecycle() &&
            !activeTunStrict && !nextRuntimeStrict && !KillSwitchIntentStore.requested(applicationContext)

    internal fun prepareRuntime(content: String): RuntimeKillSwitchPolicy.Plan {
        val lockdown = strictPolicyRequested()
        return RuntimeKillSwitchPolicy.prepare(content, lockdown)
    }

    internal fun useRuntimePlan(plan: RuntimeKillSwitchPolicy.Plan, fingerprint: String) {
        nextRuntimeStrict = plan.strict
        nextRuntimeFingerprint = fingerprint.takeUnless { plan.strict }
    }

    private data class AppRoutes(
        val descriptor: ParcelFileDescriptor,
        val excluded: List<String>,
    )

    /** Report actual successful Builder calls, only for the current established TUN. */
    internal fun appliedAppExclusions(): List<String>? {
        val routes = activeAppRoutes ?: return null
        return routes.excluded.takeIf {
            service.isRuntimeConnected() && service.fileDescriptor === routes.descriptor &&
                runCatching { routes.descriptor.fileDescriptor.valid() }.getOrDefault(false)
        }
    }

    private fun applyAppExclusions(
        builder: Builder,
        configured: Iterable<String>,
        applied: MutableList<String>,
        includeOptIns: Boolean,
        tolerateLegacyErrors: Boolean = false,
    ) {
        val optIns = if (includeOptIns) {
            SmartRouteApps.exclusions(applicationContext, nextRuntimeFingerprint, nextRuntimeStrict)
        } else emptyList()
        val packages = VpnPackagePolicy.disallowedPackages(configured + optIns, packageName)
        packages.forEach { id ->
            try {
                builder.addDisallowedApplication(id)
                if (id != packageName) applied.add(id)
            } catch (error: NameNotFoundException) {
                if (id == packageName && !tolerateLegacyErrors) throw error
                // App can be removed between the eligibility check and establish.
            } catch (error: Exception) {
                if (!tolerateLegacyErrors) throw error
                Log.w(TAG, "Android could not apply an Xray app exclusion")
            }
        }
    }

    private fun rememberAppRoutes(pfd: ParcelFileDescriptor, applied: List<String>) {
        activeAppRoutes = if (applied.size <= NativeProtectionQuery.MAX_REPORTED_EXCLUSIONS) {
            AppRoutes(pfd, applied.toList())
        } else null
    }

    private fun strictTunRequired(): Boolean {
        check(!strictPolicyRequested() || nextRuntimeStrict) {
            "Kill switch: runtime policy changed; reconnect required"
        }
        return nextRuntimeStrict
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == BoxService.ACTION_START && intent.hasExtra(VpnCommandFence.EXTRA_TOKEN)) {
            val token = intent.getStringExtra(VpnCommandFence.EXTRA_TOKEN)
            val result = VpnCommandFence.runCurrent(applicationContext, token, VpnCommandFence.Kind.Start) {
                service.rememberAppCommand(
                    token,
                    intent.getStringExtra(com.tecclub.flutter_singbox.diagnostics.HermesPilotGate.EXTRA_MANAGED_CONFIG),
                )
                acceptStartCommand(intent, startId)
            }
            return result ?: service.rejectSupersededStart(startId)
        }
        // OS Always-on, boot restore and legacy tile starts do not carry an
        // app-issued token. Their authorization and restore policy is unchanged.
        if (!service.isDesiredRunning() || intent == null || intent.action == SERVICE_INTERFACE) {
            service.rememberAppCommand(null)
        }
        return acceptStartCommand(intent, startId)
    }

    private fun acceptStartCommand(intent: Intent?, startId: Int): Int {
        Application.initializeBaseIfNeeded(applicationContext)
        // An always-on start is a system-owned request, including a null sticky
        // intent after process death. A stale manual-disconnect flag must not win.
        val systemOwned = intent?.action == SERVICE_INTERFACE || liveSystemOn()
        if (systemOwned) {
            systemStartSeen = true
            strictPolicyRequested(systemStartRequest = true)
            SimpleConfigManager.setStartedByUser(true)
            SimpleConfigManager.setManualDisconnectRequested(false)
        }
        android.util.Log.e("VPNService", "onStartCommand called with intent: ${intent?.action}")

        if (!systemOwned && intent?.getBooleanExtra(Action.EXTRA_BACKGROUND_RESTORE, false) == true) {
            val restoreRequested = PackageReplaceRestorePolicy.restoreRequested(
                autoStart = SimpleConfigManager.getAutoStart(applicationContext),
                startedByUser = SimpleConfigManager.getStartedByUser(applicationContext),
                manualDisconnectRequested = SimpleConfigManager.getManualDisconnectRequested(),
            )
            if (!restoreRequested || !SimpleConfigManager.hasValidConfig(applicationContext)) {
                Log.i(TAG, "Background restore cancelled because persisted intent changed")
                stopSelf(startId)
                return START_NOT_STICKY
            }
        }
        
        // Extract config content if available
        if (intent != null && intent.action == BoxService.ACTION_START) {
            if (intent.getBooleanExtra(Action.EXTRA_USER_INITIATED, false)) {
                SimpleConfigManager.setStartedByUser(true)
                SimpleConfigManager.setManualDisconnectRequested(false)
            }
            val configContent = intent.getStringExtra(BoxService.EXTRA_CONFIG_CONTENT)
            android.util.Log.e("VPNService", "Config content received: ${configContent?.length ?: 0} bytes")
            
            if (configContent != null) {
                // The app process already persisted it. Cache the exact intent payload
                // here so BoxService never performs Keystore I/O on the service main thread.
                android.util.Log.e("VPNService", "Caching received runtime config")
                val revision = intent.getIntExtra(
                    com.tecclub.flutter_singbox.config.RuntimeTlsPolicy.INTENT_REVISION_EXTRA, 0,
                )
                if (!SimpleConfigManager.cacheConfig(configContent, revision)) {
                    Log.w(TAG, "Refusing unsupported or unvalidated TLS start payload")
                    stopSelf(startId)
                    return START_NOT_STICKY
                }
            } else {
                android.util.Log.e("VPNService", "WARNING: No config content received in intent")
            }
        }
        
        return service.onStartCommand()
    }

    override fun onBind(intent: Intent): IBinder {
        val binder = super.onBind(intent)
        if (binder != null) {
            return binder
        }
        return service.onBind()
    }

    override fun onDestroy() {
        protectionHandler.removeCallbacks(protectionCheck)
        service.onDestroy()
        super.onDestroy()
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        service.onTaskRemoved()
        super.onTaskRemoved(rootIntent)
    }

    override fun onRevoke() {
        service.onRevoke()
        super.onRevoke()
    }

    override fun autoDetectInterfaceControl(fd: Int) {
        val result = protect(fd)
        check(result || !nextRuntimeStrict) { "Kill switch: upstream socket protection failed" }
        val call = protectCallCount.incrementAndGet()
        if (call <= PROTECT_LOG_LIMIT || !result) {
            val message = "sing-box protect call=$call fd=$fd protected=$result"
            if (result) {
                Log.d(TAG, message)
            } else {
                Log.w(TAG, message)
            }
        }
    }

    override fun openTun(options: TunOptions): Int {
        if (prepare(this) != null) error("android: missing vpn permission")
        val strict = strictTunRequired()
        val appliedPackages = mutableListOf<String>()

        // A reload can reach openTun before the previous native service has released
        // its descriptor. Keep only one Android VPN interface across profile switches.
        service.fileDescriptor?.close()
        service.fileDescriptor = null

        val builder = Builder()
            .setSession("sing-box")
            .setMtu(options.mtu)

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            builder.setMetered(false)
        }

        val inet4Address = options.inet4Address
        while (inet4Address.hasNext()) {
            val address = inet4Address.next()
            builder.addAddress(address.address(), address.prefix())
        }

        val inet6Address = options.inet6Address
        while (inet6Address.hasNext()) {
            val address = inet6Address.next()
            builder.addAddress(address.address(), address.prefix())
        }

        if (strict) {
            // Capture both families regardless of a raw/native caller's routes.
            // No allowBypass, allowFamily, exclusions or include-only app lists.
            builder.addRoute("0.0.0.0", 0)
            builder.addRoute("::", 0)
            builder.addDnsServer(options.dnsServerAddress.value)
        } else if (options.autoRoute) {
            builder.addDnsServer(options.dnsServerAddress.value)

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                val inet4RouteAddress = options.inet4RouteAddress
                if (inet4RouteAddress.hasNext()) {
                    while (inet4RouteAddress.hasNext()) {
                        builder.addRoute(inet4RouteAddress.next().toIpPrefix())
                    }
                } else if (options.inet4Address.hasNext()) {
                    builder.addRoute("0.0.0.0", 0)
                }

                val inet6RouteAddress = options.inet6RouteAddress
                if (inet6RouteAddress.hasNext()) {
                    while (inet6RouteAddress.hasNext()) {
                        builder.addRoute(inet6RouteAddress.next().toIpPrefix())
                    }
                } else if (options.inet6Address.hasNext()) {
                    builder.addRoute("::", 0)
                }

                val inet4RouteExcludeAddress = options.inet4RouteExcludeAddress
                while (inet4RouteExcludeAddress.hasNext()) {
                    builder.excludeRoute(inet4RouteExcludeAddress.next().toIpPrefix())
                }

                val inet6RouteExcludeAddress = options.inet6RouteExcludeAddress
                while (inet6RouteExcludeAddress.hasNext()) {
                    builder.excludeRoute(inet6RouteExcludeAddress.next().toIpPrefix())
                }
            } else {
                val inet4RouteAddress = options.inet4RouteRange
                if (inet4RouteAddress.hasNext()) {
                    while (inet4RouteAddress.hasNext()) {
                        val address = inet4RouteAddress.next()
                        builder.addRoute(address.address(), address.prefix())
                    }
                }

                val inet6RouteAddress = options.inet6RouteRange
                if (inet6RouteAddress.hasNext()) {
                    while (inet6RouteAddress.hasNext()) {
                        val address = inet6RouteAddress.next()
                        builder.addRoute(address.address(), address.prefix())
                    }
                }
            }

            if (Settings.perAppProxyEnabled) {
                val appList = Settings.perAppProxyList
                if (Settings.perAppProxyMode == Settings.PER_APP_PROXY_INCLUDE) {
                    var addedApplications = 0
                    VpnPackagePolicy.allowedPackages(appList, packageName).forEach {
                        try {
                            builder.addAllowedApplication(it)
                            addedApplications += 1
                        } catch (_: NameNotFoundException) {
                        }
                    }
                    check(addedApplications > 0) {
                        "android: per-app include list has no installed external applications"
                    }
                } else {
                    applyAppExclusions(builder, appList, appliedPackages, includeOptIns = false)
                }
            } else {
                val includePackage = options.includePackage
                val includedPackages = buildList {
                    while (includePackage.hasNext()) add(includePackage.next())
                }
                if (includedPackages.isNotEmpty()) {
                    var addedApplications = 0
                    VpnPackagePolicy.allowedPackages(includedPackages, packageName).forEach {
                        try {
                            builder.addAllowedApplication(it)
                            addedApplications += 1
                        } catch (_: NameNotFoundException) {
                        }
                    }
                    check(addedApplications > 0) {
                        "android: include list has no installed external applications"
                    }
                } else {
                    val excludePackage = options.excludePackage
                    val excludedPackages = buildList {
                        while (excludePackage.hasNext()) add(excludePackage.next())
                    }
                    applyAppExclusions(builder, excludedPackages, appliedPackages, includeOptIns = true)
                }
            }
        }

        if (!strict && options.isHTTPProxyEnabled && Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            systemProxyAvailable = true
            systemProxyEnabled = Settings.systemProxyEnabled
            if (systemProxyEnabled) builder.setHttpProxy(
                ProxyInfo.buildDirectProxy(
                    options.httpProxyServer,
                    options.httpProxyServerPort,
                    options.httpProxyBypassDomain.toList()
                )
            )
        } else {
            systemProxyAvailable = false
            systemProxyEnabled = false
        }

        val pfd =
            builder.establish() ?: error("android: the application is not prepared or is revoked")
        service.fileDescriptor = pfd
        activeTunStrict = strict
        rememberAppRoutes(pfd, appliedPackages)
        return pfd.fd
    }

    fun openXrayTun(
        androidDisallowedPackages: List<String> = emptyList(),
    ): ParcelFileDescriptor {
        if (prepare(this) != null) error("android: missing vpn permission")
        val strict = strictTunRequired()
        val appliedPackages = mutableListOf<String>()

        service.fileDescriptor?.close()
        service.fileDescriptor = null
        val dnsServers = XRAY_TUN_DNS_SERVERS
        val builder = Builder()
            .setSession("Yurich Connect Xray")
            .setMtu(1380)
            .addAddress("172.19.0.1", 30)
            .addAddress("fdfe:dcba:9876::1", 126)
            .addRoute("0.0.0.0", 0)
            .addRoute("::", 0)
        dnsServers.take(4).forEach { builder.addDnsServer(it) }
        Log.i(TAG, "Xray TUN DNS servers: ${dnsServers.take(4).joinToString(",")}")

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            builder.setMetered(false)
        }

        if (!strict) {
            applyAppExclusions(
                builder, androidDisallowedPackages, appliedPackages,
                includeOptIns = true, tolerateLegacyErrors = true,
            )
        }

        val pfd =
            builder.establish() ?: error("android: the application is not prepared or is revoked")
        service.fileDescriptor = pfd
        activeTunStrict = strict
        rememberAppRoutes(pfd, appliedPackages)
        return pfd
    }
    
    override fun protect(fd: Int): Boolean {
        return super.protect(fd)
    }
    
    fun writeLog(message: String) {
        service.writeLog(message)
    }
    
    override fun sendNotification(notification: io.nekohasekai.libbox.Notification) {
        service.sendNotification(notification)
    }
}
