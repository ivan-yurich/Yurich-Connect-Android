package com.tecclub.flutter_singbox.diagnostics

import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import com.tecclub.flutter_singbox.BuildConfig

/** Two independent build gates: library constant plus the host's GitHub pilot manifest. */
object HermesPilotGate {
    const val ACCESS_CHANGED = "com.tecclub.flutter_singbox.HERMES_ACCESS_CHANGED"
    internal const val QUEUE_CHANGED = "com.tecclub.flutter_singbox.HERMES_QUEUE_CHANGED"
    internal const val EXTRA_MANAGED_CONFIG = "hermes_managed_config"
    private const val META = "online.dnsai.ivanvpn.HERMES_DELIVERY_PILOT"
    private val testVersion = Regex("""\d+\.\d+\.\d+-test\.\d{8}\.\d+""")

    @Suppress("DEPRECATION")
    fun enabled(context: Context): Boolean {
        if (!BuildConfig.HERMES_DELIVERY_PILOT || Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return false
        return runCatching {
            val pm = context.packageManager
            val host = pm.getApplicationInfo(context.packageName, PackageManager.GET_META_DATA)
            host.metaData?.getBoolean(META, false) == true &&
                testVersion.matches(pm.getPackageInfo(context.packageName, 0).versionName.orEmpty())
        }.getOrDefault(false)
    }

    internal fun validBearer(value: String): Boolean = HermesWireRequest.validBearer(value)

    internal fun signalAccessChange(context: Context) {
        if (enabled(context)) {
            runCatching { context.sendBroadcast(Intent(ACCESS_CHANGED).setPackage(context.packageName)) }
        }
    }

    internal fun signalQueueChange(context: Context) {
        if (enabled(context)) {
            runCatching { context.sendBroadcast(Intent(QUEUE_CHANGED).setPackage(context.packageName)) }
        }
    }
}
