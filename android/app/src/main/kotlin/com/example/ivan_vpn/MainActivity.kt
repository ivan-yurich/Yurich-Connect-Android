package online.dnsai.ivanvpn

import android.content.ClipData
import android.content.ActivityNotFoundException
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.app.PendingIntent
import android.content.pm.ApplicationInfo
import android.content.pm.PackageInstaller
import android.content.pm.PackageManager
import android.content.pm.ResolveInfo
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import android.provider.Settings
import android.util.Log
import android.widget.Toast
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        handlePackageInstallerCallback(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handlePackageInstallerCallback(intent)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "online.dnsai.ivanvpn/updater",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "getSupportedAbis" -> result.success(Build.SUPPORTED_ABIS.toList())
                "installApk" -> installApk(call.argument<String>("path"), result)
                "openInstallSettings" -> {
                    openInstallSettings()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "online.dnsai.ivanvpn/power",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "isIgnoringBatteryOptimizations" ->
                    result.success(isIgnoringBatteryOptimizations())
                "requestIgnoreBatteryOptimizations" -> {
                    requestIgnoreBatteryOptimizations()
                    result.success(null)
                }
                "openBatteryOptimizationSettings" -> {
                    openBatteryOptimizationSettings()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "online.dnsai.ivanvpn/apps",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "getInstalledPackages" -> result.success(getInstalledPackages())
                else -> result.notImplemented()
            }
        }
    }

    private fun getInstalledPackages(): List<String> {
        return try {
            val apps = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                packageManager.getInstalledApplications(
                    PackageManager.ApplicationInfoFlags.of(0L),
                )
            } else {
                @Suppress("DEPRECATION")
                packageManager.getInstalledApplications(0)
            }
            apps.map { it.packageName }.distinct().sorted()
        } catch (error: Exception) {
            Log.w(TAG, "Failed to list installed packages", error)
            emptyList()
        }
    }

    private fun installApk(path: String?, result: MethodChannel.Result) {
        if (path.isNullOrBlank()) {
            result.error("BAD_PATH", "APK path is empty", null)
            return
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            !packageManager.canRequestPackageInstalls()
        ) {
            openInstallSettings()
            result.error("INSTALL_PERMISSION", "Allow APK installation from Yurich Connect", null)
            return
        }

        val apkFile = File(path)
        if (!apkFile.exists()) {
            result.error("APK_NOT_FOUND", "APK file not found", null)
            return
        }
        if (!apkFile.canRead() || apkFile.length() <= 0L) {
            result.error("APK_NOT_READABLE", "APK file is empty or not readable", null)
            return
        }

        try {
            val installFile = prepareInstallFile(apkFile)
            openInstallIntent(installFile)
            result.success(null)
        } catch (error: Exception) {
            Log.w(TAG, "ACTION_VIEW update failed, falling back to PackageInstaller", error)
            try {
                val installFile = prepareInstallFile(apkFile)
                installWithPackageInstaller(installFile)
                result.success(null)
            } catch (fallbackError: ActivityNotFoundException) {
                result.error("INSTALL_FAILED", "Android package installer was not found", null)
            } catch (fallbackError: Exception) {
                result.error(
                    "INSTALL_FAILED",
                    "${fallbackError.javaClass.simpleName}: ${fallbackError.message}",
                    null,
                )
            }
        }
    }

    private fun installWithPackageInstaller(apkFile: File) {
        val installer = packageManager.packageInstaller
        val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL)
            .apply {
                setAppPackageName(packageName)
            }
        val sessionId = installer.createSession(params)
        var session: PackageInstaller.Session? = null
        try {
            session = installer.openSession(sessionId)
            apkFile.inputStream().use { input ->
                session.openWrite("YurichConnect-${apkFile.name}", 0, apkFile.length()).use { output ->
                    input.copyTo(output)
                    session.fsync(output)
                }
            }

            val callbackIntent = Intent(this, MainActivity::class.java).apply {
                action = ACTION_PACKAGE_INSTALL_STATUS
                putExtra(EXTRA_PACKAGE_INSTALL_SESSION_ID, sessionId)
                addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP)
            }
            val pendingIntent = PendingIntent.getActivity(
                this,
                sessionId,
                callbackIntent,
                pendingIntentFlags(),
            )
            session.commit(pendingIntent.intentSender)
        } catch (error: Exception) {
            try {
                installer.abandonSession(sessionId)
            } catch (_: Exception) {
            }
            throw error
        } finally {
            try {
                session?.close()
            } catch (_: Exception) {
            }
        }
    }

    private fun openInstallIntent(apkFile: File) {
        val uri = FileProvider.getUriForFile(this, "$packageName.cache", apkFile)
        val intent = buildInstallIntent(uri)
        val installers = findInstallers(intent)
        if (installers.isEmpty()) {
            throw ActivityNotFoundException("Android package installer was not found")
        }
        installers.forEach { resolveInfo ->
            grantUriPermission(
                resolveInfo.activityInfo.packageName,
                uri,
                Intent.FLAG_GRANT_READ_URI_PERMISSION,
            )
        }
        startActivity(intent)
    }

    private fun handlePackageInstallerCallback(intent: Intent?) {
        if (intent?.action != ACTION_PACKAGE_INSTALL_STATUS) {
            return
        }
        try {
            when (intent.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE)) {
                PackageInstaller.STATUS_PENDING_USER_ACTION -> {
                    val confirmation = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                        intent.getParcelableExtra(Intent.EXTRA_INTENT, Intent::class.java)
                    } else {
                        @Suppress("DEPRECATION")
                        intent.getParcelableExtra(Intent.EXTRA_INTENT)
                    }
                    val safeConfirmation = confirmation?.let(::sanitizeInstallConfirmation)
                    if (safeConfirmation != null) {
                        startActivity(safeConfirmation)
                    } else {
                        Toast.makeText(this, "Не удалось открыть установщик Android", Toast.LENGTH_LONG)
                            .show()
                    }
                }
                PackageInstaller.STATUS_SUCCESS -> {
                    Toast.makeText(this, "Yurich Connect обновлён", Toast.LENGTH_SHORT).show()
                }
                else -> {
                    val message = intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE)
                        ?: "Установка обновления не завершилась"
                    Log.w(TAG, "PackageInstaller status: $message")
                    Toast.makeText(this, message, Toast.LENGTH_LONG).show()
                }
            }
        } catch (error: ActivityNotFoundException) {
            Toast.makeText(this, "Установщик Android не найден", Toast.LENGTH_LONG).show()
        }
    }

    private fun sanitizeInstallConfirmation(rawIntent: Intent): Intent? {
        if (!isPackageInstallerAction(rawIntent.action)) {
            Log.w(TAG, "Package installer confirmation intent action was rejected: ${rawIntent.action}")
            return null
        }

        val trustedInstaller = findTrustedInstaller(rawIntent) ?: return null
        return Intent(rawIntent).apply {
            component = ComponentName(
                trustedInstaller.activityInfo.packageName,
                trustedInstaller.activityInfo.name,
            )
            `package` = trustedInstaller.activityInfo.packageName
            flags = rawIntent.flags and INSTALL_CONFIRMATION_ALLOWED_FLAGS
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
    }

    private fun isPackageInstallerAction(action: String?): Boolean =
        action == null ||
            action == Intent.ACTION_VIEW ||
            action.startsWith("android.content.pm.action.") ||
            action.startsWith("android.intent.action.INSTALL")

    private fun findTrustedInstaller(intent: Intent): ResolveInfo? =
        packageManager.queryIntentActivities(intent, PackageManager.MATCH_DEFAULT_ONLY)
            .firstOrNull { resolveInfo ->
                val appInfo = resolveInfo.activityInfo?.applicationInfo ?: return@firstOrNull false
                val flags = appInfo.flags
                resolveInfo.activityInfo.packageName != packageName &&
                    (flags and ApplicationInfo.FLAG_SYSTEM != 0 ||
                        flags and ApplicationInfo.FLAG_UPDATED_SYSTEM_APP != 0)
            }

    private fun buildInstallIntent(uri: Uri): Intent =
        Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, APK_MIME_TYPE)
            clipData = ClipData.newUri(contentResolver, "Yurich Connect update", uri)
            putExtra(Intent.EXTRA_NOT_UNKNOWN_SOURCE, true)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }

    private fun findInstallers(intent: Intent) =
        packageManager.queryIntentActivities(intent, PackageManager.MATCH_DEFAULT_ONLY)

    private fun prepareInstallFile(source: File): File {
        val safeName = source.name
            .ifBlank { "YurichConnect-update.apk" }
            .replace(Regex("[^A-Za-z0-9._-]"), "_")
            .let { if (it.endsWith(".apk", ignoreCase = true)) it else "$it.apk" }
        val updatesRoot = externalCacheDir ?: cacheDir
        val updatesDir = File(updatesRoot, "updates").apply { mkdirs() }
        val target = File(updatesDir, safeName)
        if (source.canonicalPath != target.canonicalPath) {
            source.copyTo(target, overwrite = true)
        }
        return target
    }

    private fun openInstallSettings() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val intent = Intent(
                Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                Uri.fromParts("package", packageName, null),
            ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            startActivity(intent)
        }
    }

    private fun isIgnoringBatteryOptimizations(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
            return true
        }
        val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
        return powerManager.isIgnoringBatteryOptimizations(packageName)
    }

    private fun requestIgnoreBatteryOptimizations() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M ||
            isIgnoringBatteryOptimizations()
        ) {
            return
        }

        val requestIntent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).apply {
            data = Uri.parse("package:$packageName")
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        try {
            startActivity(requestIntent)
        } catch (error: ActivityNotFoundException) {
            openBatteryOptimizationSettings()
        } catch (error: SecurityException) {
            Log.w(TAG, "Battery optimization exemption request rejected", error)
            openBatteryOptimizationSettings()
        }
    }

    private fun openBatteryOptimizationSettings() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            val intent = Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            startActivity(intent)
        } else {
            val intent = Intent(Settings.ACTION_SETTINGS)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            startActivity(intent)
        }
    }

    private fun pendingIntentFlags(): Int =
        PendingIntent.FLAG_UPDATE_CURRENT or
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                PendingIntent.FLAG_MUTABLE
            } else {
                0
            }

    private companion object {
        const val TAG = "YurichUpdater"
        const val APK_MIME_TYPE = "application/vnd.android.package-archive"
        const val ACTION_PACKAGE_INSTALL_STATUS = "online.dnsai.ivanvpn.UPDATE_INSTALL_STATUS"
        const val EXTRA_PACKAGE_INSTALL_SESSION_ID = "package_install_session_id"
        val INSTALL_CONFIRMATION_ALLOWED_FLAGS =
            Intent.FLAG_ACTIVITY_NEW_TASK or
                Intent.FLAG_ACTIVITY_CLEAR_TOP or
                Intent.FLAG_ACTIVITY_SINGLE_TOP or
                Intent.FLAG_ACTIVITY_NO_HISTORY
    }
}
