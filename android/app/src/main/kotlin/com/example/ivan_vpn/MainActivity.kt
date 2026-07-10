package online.dnsai.ivanvpn

import android.Manifest
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
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.provider.Settings
import android.util.Log
import android.widget.Toast
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.renderer.FlutterUiDisplayListener
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException

class MainActivity : FlutterActivity() {
    private val mainHandler = Handler(Looper.getMainLooper())
    private var firstFrameRendered = false
    private var firstFrameWatchdog: Runnable? = null
    private var firstFrameListener: FlutterUiDisplayListener? = null
    private var firstFrameEngine: FlutterEngine? = null

    @Volatile
    private var ioExecutor: ExecutorService = newIoExecutor()

    private fun newIoExecutor(): ExecutorService = Executors.newSingleThreadExecutor { task ->
        Thread(task, "YurichConnectIo").apply { isDaemon = true }
    }

    @Synchronized
    private fun currentIoExecutor(): ExecutorService {
        if (ioExecutor.isShutdown || ioExecutor.isTerminated) {
            ioExecutor = newIoExecutor()
        }
        return ioExecutor
    }

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
        armFirstFrameWatchdog(flutterEngine)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "online.dnsai.ivanvpn/updater",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "getSupportedAbis" -> result.success(Build.SUPPORTED_ABIS.toList())
                "inspectApk" -> inspectApk(call.argument<String>("path"), result)
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
                "getInstalledPackages" -> runIo(result) { getInstalledPackages() }
                else -> result.notImplemented()
            }
        }
    }

    private fun inspectApk(path: String?, result: MethodChannel.Result) {
        runIo(result) { inspectApkData(path) }
    }

    private fun inspectApkData(path: String?): Map<String, Any> {
        if (path.isNullOrBlank()) {
            throw NativeMethodFailure("BAD_PATH", "APK path is empty")
        }

        val apkFile = File(path)
        if (!apkFile.exists() || !apkFile.canRead() || apkFile.length() <= 0L) {
            throw NativeMethodFailure("APK_NOT_READABLE", "APK file is empty or not readable")
        }

        try {
            val packageInfo = getArchivePackageInfo(apkFile)
                ?: throw IllegalStateException("Android cannot parse update APK")
            return mapOf(
                "packageName" to (packageInfo.packageName ?: ""),
                "versionName" to (packageInfo.versionName ?: ""),
                "versionCode" to packageInfo.versionCodeCompat(),
            )
        } catch (error: Exception) {
            throw NativeMethodFailure(
                "APK_INVALID",
                "${error.javaClass.simpleName}: ${error.message}",
            )
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

        if (!hasExternalInstallPermission()) {
            result.error(
                "EXTERNAL_INSTALL_DISABLED",
                "External APK installation is disabled in this Play-ready build.",
                null,
            )
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
        executeIo(result) {
            try {
                validateInstallSource(apkFile)
                val installFile = prepareInstallFile(apkFile)
                try {
                    installWithPackageInstaller(installFile)
                    successOnMain(result, null)
                } catch (error: Exception) {
                    Log.w(TAG, "PackageInstaller update failed, falling back to ACTION_VIEW", error)
                    openInstallIntentOnMain(installFile, result)
                }
            } catch (error: NativeMethodFailure) {
                errorOnMain(result, error.code, error.message ?: "Native method failed")
            } catch (error: Exception) {
                errorOnMain(
                    result,
                    "INSTALL_FAILED",
                    "${error.javaClass.simpleName}: ${error.message}",
                )
            }
        }
    }

    private fun validateInstallSource(apkFile: File) {
        if (!apkFile.exists()) {
            throw NativeMethodFailure("APK_NOT_FOUND", "APK file not found")
        }
        if (!apkFile.canRead() || apkFile.length() <= 0L) {
            throw NativeMethodFailure("APK_NOT_READABLE", "APK file is empty or not readable")
        }
        if (!isReadableApk(apkFile)) {
            throw NativeMethodFailure(
                "APK_INVALID",
                "Downloaded update file is not a valid APK. Please retry the update.",
            )
        }
    }

    private fun openInstallIntentOnMain(apkFile: File, result: MethodChannel.Result) {
        mainHandler.post {
            try {
                openInstallIntent(apkFile)
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
        if (!isReadableApk(target)) {
            throw IllegalStateException("Prepared update file is not a valid APK")
        }
        validateUpdatePackage(target)
        return target
    }

    private fun isReadableApk(file: File): Boolean {
        if (!file.exists() || !file.canRead() || file.length() < APK_MIN_BYTES) {
            return false
        }
        return try {
            file.inputStream().use { input ->
                val header = ByteArray(4)
                val read = input.read(header)
                read == 4 && header[0] == 0x50.toByte() && header[1] == 0x4B.toByte()
            }
        } catch (error: Exception) {
            Log.w(TAG, "Failed to validate APK file", error)
            false
        }
    }

    private fun validateUpdatePackage(file: File) {
        val packageInfo = getArchivePackageInfo(file)
            ?: throw IllegalStateException("Android cannot parse update APK")
        val archivePackageName = packageInfo.packageName
        if (archivePackageName != packageName) {
            throw IllegalStateException(
                "Update package mismatch: expected $packageName, got $archivePackageName",
            )
        }
        val currentVersionCode = currentVersionCode()
        val updateVersionCode = packageInfo.versionCodeCompat()
        if (currentVersionCode > 0L && updateVersionCode <= currentVersionCode) {
            throw IllegalStateException(
                "Update package is not newer: installed build $currentVersionCode, " +
                    "downloaded build $updateVersionCode",
            )
        }
    }

    private fun getArchivePackageInfo(file: File): android.content.pm.PackageInfo? =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            packageManager.getPackageArchiveInfo(
                file.absolutePath,
                PackageManager.PackageInfoFlags.of(0),
            )
        } else {
            @Suppress("DEPRECATION")
            packageManager.getPackageArchiveInfo(file.absolutePath, 0)
        }

    private fun android.content.pm.PackageInfo.versionCodeCompat(): Long =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            longVersionCode
        } else {
            @Suppress("DEPRECATION")
            versionCode.toLong()
        }

    private fun currentVersionCode(): Long =
        try {
            val info = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                packageManager.getPackageInfo(
                    packageName,
                    PackageManager.PackageInfoFlags.of(0),
                )
            } else {
                @Suppress("DEPRECATION")
                packageManager.getPackageInfo(packageName, 0)
            }
            info.versionCodeCompat()
        } catch (_: Exception) {
            0L
        }

    private fun openInstallSettings() {
        if (!hasExternalInstallPermission()) {
            Toast.makeText(
                this,
                "External APK installation is disabled in this build",
                Toast.LENGTH_LONG,
            ).show()
            return
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val intent = Intent(
                Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                Uri.fromParts("package", packageName, null),
            ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            startActivity(intent)
        }
    }

    private fun hasExternalInstallPermission(): Boolean {
        return try {
            val info = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                packageManager.getPackageInfo(
                    packageName,
                    PackageManager.PackageInfoFlags.of(PackageManager.GET_PERMISSIONS.toLong()),
                )
            } else {
                @Suppress("DEPRECATION")
                packageManager.getPackageInfo(packageName, PackageManager.GET_PERMISSIONS)
            }
            info.requestedPermissions?.contains(Manifest.permission.REQUEST_INSTALL_PACKAGES) == true
        } catch (_: Exception) {
            false
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

    override fun onDestroy() {
        disarmFirstFrameWatchdog()
        ioExecutor.shutdown()
        super.onDestroy()
    }

    private fun armFirstFrameWatchdog(flutterEngine: FlutterEngine) {
        firstFrameRendered = false
        disarmFirstFrameWatchdog()
        firstFrameEngine = flutterEngine

        val listener = object : FlutterUiDisplayListener {
            override fun onFlutterUiDisplayed() {
                firstFrameRendered = true
                resetFirstFrameRecoveryWindow()
                disarmFirstFrameWatchdog()
                Log.d(TAG, "Flutter first frame displayed")
            }

            override fun onFlutterUiNoLongerDisplayed() {
                // No-op. The watchdog only cares about the first visible frame.
            }
        }
        firstFrameListener = listener
        flutterEngine.renderer.addIsDisplayingFlutterUiListener(listener)

        val watchdog = Runnable {
            recoverFromMissingFirstFrame()
        }
        firstFrameWatchdog = watchdog
        mainHandler.postDelayed(watchdog, FIRST_FRAME_TIMEOUT_MS)
    }

    private fun disarmFirstFrameWatchdog() {
        firstFrameWatchdog?.let(mainHandler::removeCallbacks)
        firstFrameWatchdog = null
        val engine = firstFrameEngine
        val listener = firstFrameListener
        if (engine != null && listener != null) {
            runCatching {
                engine.renderer.removeIsDisplayingFlutterUiListener(listener)
            }
        }
        firstFrameListener = null
        firstFrameEngine = null
    }

    private fun recoverFromMissingFirstFrame() {
        if (firstFrameRendered || isFinishing || isActivityDestroyedCompat()) {
            return
        }
        if (!takeFirstFrameRecoverySlot()) {
            Log.w(TAG, "Flutter first frame watchdog skipped by cooldown")
            return
        }

        Log.w(TAG, "Flutter first frame was not rendered within timeout")
        disarmFirstFrameWatchdog()
    }

    private fun isActivityDestroyedCompat(): Boolean =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.JELLY_BEAN_MR1 && isDestroyed

    private fun executeIo(result: MethodChannel.Result, task: () -> Unit) {
        try {
            currentIoExecutor().execute(task)
        } catch (error: RejectedExecutionException) {
            Log.w(TAG, "IO executor rejected task, recreating", error)
            try {
                currentIoExecutor().execute(task)
            } catch (retryError: Exception) {
                Log.w(TAG, "Native channel retry failed", retryError)
                errorOnMain(
                    result,
                    "NATIVE_ERROR",
                    "${retryError.javaClass.simpleName}: ${retryError.message}",
                )
            }
        } catch (error: Exception) {
            Log.w(TAG, "Native channel submission failed", error)
            errorOnMain(
                result,
                "NATIVE_ERROR",
                "${error.javaClass.simpleName}: ${error.message}",
            )
        }
    }

    private fun <T> runIo(result: MethodChannel.Result, task: () -> T) {
        executeIo(result) {
            try {
                successOnMain(result, task())
            } catch (error: NativeMethodFailure) {
                errorOnMain(result, error.code, error.message ?: "Native method failed")
            } catch (error: Exception) {
                Log.w(TAG, "Native channel call failed", error)
                errorOnMain(
                    result,
                    "NATIVE_ERROR",
                    "${error.javaClass.simpleName}: ${error.message}",
                )
            }
        }
    }

    private fun successOnMain(result: MethodChannel.Result, value: Any?) {
        mainHandler.post { result.success(value) }
    }

    private fun errorOnMain(result: MethodChannel.Result, code: String, message: String) {
        mainHandler.post { result.error(code, message, null) }
    }

    private fun takeFirstFrameRecoverySlot(): Boolean {
        val now = System.currentTimeMillis()
        synchronized(MainActivity::class.java) {
            if (now - firstFrameRecoveryWindowStartedAt > FIRST_FRAME_RECOVERY_WINDOW_MS) {
                firstFrameRecoveryWindowStartedAt = now
                firstFrameRecoveryCount = 0
            }
            if (firstFrameRecoveryCount >= FIRST_FRAME_RECOVERY_LIMIT) {
                return false
            }
            firstFrameRecoveryCount += 1
            return true
        }
    }

    private fun resetFirstFrameRecoveryWindow() {
        synchronized(MainActivity::class.java) {
            firstFrameRecoveryWindowStartedAt = 0L
            firstFrameRecoveryCount = 0
        }
    }

    private class NativeMethodFailure(
        val code: String,
        override val message: String,
    ) : Exception(message)

    private companion object {
        const val TAG = "YurichUpdater"
        const val APK_MIN_BYTES = 64 * 1024L
        const val APK_MIME_TYPE = "application/vnd.android.package-archive"
        const val ACTION_PACKAGE_INSTALL_STATUS = "online.dnsai.ivanvpn.UPDATE_INSTALL_STATUS"
        const val EXTRA_PACKAGE_INSTALL_SESSION_ID = "package_install_session_id"
        const val FIRST_FRAME_TIMEOUT_MS = 8_000L
        const val FIRST_FRAME_RECOVERY_WINDOW_MS = 60_000L
        const val FIRST_FRAME_RECOVERY_LIMIT = 2
        var firstFrameRecoveryWindowStartedAt = 0L
        var firstFrameRecoveryCount = 0
        val INSTALL_CONFIRMATION_ALLOWED_FLAGS =
            Intent.FLAG_ACTIVITY_NEW_TASK or
                Intent.FLAG_ACTIVITY_CLEAR_TOP or
                Intent.FLAG_ACTIVITY_SINGLE_TOP or
                Intent.FLAG_ACTIVITY_NO_HISTORY
    }
}
