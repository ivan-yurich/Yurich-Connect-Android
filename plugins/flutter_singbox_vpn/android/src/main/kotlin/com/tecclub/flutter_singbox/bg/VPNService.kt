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

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        Application.initializeBaseIfNeeded(applicationContext)
        android.util.Log.e("VPNService", "onStartCommand called with intent: ${intent?.action}")
        
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
                SimpleConfigManager.cacheConfig(configContent)
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

        if (options.autoRoute) {
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
                    appList.forEach {
                        try {
                            builder.addAllowedApplication(it)
                        } catch (_: NameNotFoundException) {
                        }
                    }
                    builder.addAllowedApplication(packageName)
                } else {
                    appList.forEach {
                        try {
                            builder.addDisallowedApplication(it)
                        } catch (_: NameNotFoundException) {
                        }
                    }
                }
            } else {
                val includePackage = options.includePackage
                if (includePackage.hasNext()) {
                    while (includePackage.hasNext()) {
                        try {
                            builder.addAllowedApplication(includePackage.next())
                        } catch (_: NameNotFoundException) {
                        }
                    }
                }

                val excludePackage = options.excludePackage
                if (excludePackage.hasNext()) {
                    while (excludePackage.hasNext()) {
                        try {
                            builder.addDisallowedApplication(excludePackage.next())
                        } catch (_: NameNotFoundException) {
                        }
                    }
                }
            }
        }

        if (options.isHTTPProxyEnabled && Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
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
        return pfd.fd
    }

    fun openXrayTun(): ParcelFileDescriptor {
        if (prepare(this) != null) error("android: missing vpn permission")

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

        runCatching {
            builder.addDisallowedApplication(packageName)
        }.onFailure {
            Log.w(TAG, "Unable to exclude own package from Xray VPN", it)
        }

        val pfd =
            builder.establish() ?: error("android: the application is not prepared or is revoked")
        service.fileDescriptor = pfd
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
