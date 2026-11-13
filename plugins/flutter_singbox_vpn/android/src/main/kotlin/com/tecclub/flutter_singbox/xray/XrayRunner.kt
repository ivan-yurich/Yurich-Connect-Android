package com.tecclub.flutter_singbox.xray

import android.content.Context
import android.util.Base64
import android.util.Log
import com.tecclub.flutter_singbox.bg.VPNService
import com.tecclub.flutter_singbox.bg.NativeConfigBinding
import com.tecclub.flutter_singbox.diagnostics.HermesPilotGate
import dalvik.system.DexClassLoader
import java.io.File
import java.lang.reflect.Proxy
import java.nio.charset.StandardCharsets
import java.util.concurrent.atomic.AtomicInteger

class XrayRunner(
    private val service: VPNService,
) {
    companion object {
        private const val TAG = "XrayRunner"
        private const val ASSET_CLASSES = "xray/libxray-26.6.27-classes.jar"
        private const val LOCAL_CLASSES = "libxray-26.6.27-classes.jar"
        private val bridge = XrayDexBridge()
        private val runnerLock = Any()
    }

    @Volatile
    private var started = false
    @Volatile private var hermesRuntime: HermesRuntime? = null
    internal class HermesRuntime(val path: String, val fingerprint: String)
    internal fun hermesProof(): HermesRuntime? = hermesRuntime
    internal fun ownsHermesRuntime(proof: HermesRuntime): Boolean =
        hermesRuntime === proof && started && bridge.hermesBrowserDialerExcluded()
    private var hermesSocketFile: File? = null
    private var diagnosticLog: XrayDiagnosticLog? = null

    fun start(
        configJson: String,
        androidDisallowedPackages: List<String> = emptyList(),
        prepareHermesRoute: Boolean = false,
    ): String = synchronized(runnerLock) {
        stopLocked()

        val datDir = File(service.filesDir, "xray").apply {
            if (!exists() && !mkdirs()) {
                error("Unable to create Xray data directory: $absolutePath")
            }
        }

        bridge.ensureInitialized(service.applicationContext)
        val diagnostic = XrayDiagnosticLog.openIfEnabled(service)
        diagnosticLog = diagnostic
        val original = diagnostic?.attach(configJson) ?: configJson
        var runtimeConfig = original
        if (prepareHermesRoute && HermesPilotGate.enabled(service) && diagnostic == null &&
            bridge.hermesBrowserDialerExcluded()
        ) {
            val directory = File(service.filesDir, "h")
            // A short path in credential-encrypted private app data. Never use
            // the public loopback port or an abstract/global socket address.
            if (directory.isDirectory || directory.mkdir()) {
                val candidate = File(directory, java.util.UUID.randomUUID().toString().replace("-", ""))
                val patched = hermesXrayRoute.prepare(original, candidate.absolutePath)
                // A failed pilot config check must not disrupt an ordinary VPN.
                if (patched != null && runCatching { confirmedSuccess(validateConfig(datDir, patched)) }.getOrDefault(false)) {
                    runtimeConfig = patched
                    hermesSocketFile = candidate
                }
            }
        }
        Log.i(TAG, "Embedded Xray version: ${redact(bridge.xrayVersion()).take(96)}")
        if (hermesSocketFile == null) {
            val testResponse = validateConfig(datDir, runtimeConfig)
            if (looksFailed(testResponse)) {
                diagnostic?.record(XrayDiagnosticKind.config_failure)
                throw IllegalStateException("Xray config validation failed: $testResponse")
            }
        }

        val tun = service.openXrayTun(androidDisallowedPackages)
        bridge.registerProtectFd(service) { protected ->
            diagnostic?.record(if (protected) XrayDiagnosticKind.protect_ok else XrayDiagnosticKind.protect_failed)
        }
        bridge.setTunFd(tun.fd)

        val request = bridge.newRunFromJsonRequest(datDir.absolutePath, runtimeConfig)
        var response = bridge.runXrayFromJson(request)
        if (hermesSocketFile != null && (!confirmedSuccess(response) ||
                !runCatching { bridge.getXrayState() }.getOrDefault(false))) {
            // A kernel/OEM may reject the private listener. Never use that
            // route; recover the user's VPN with its original config only
            // after Xray's existing instance is confirmed stopped.
            bridge.stopXray()
            check(!bridge.getXrayState()) { "Pilot runtime cleanup not confirmed" }
            removeHermesSocket()
            runtimeConfig = original
            val fallback = bridge.newRunFromJsonRequest(datDir.absolutePath, original)
            response = bridge.runXrayFromJson(fallback)
            check(confirmedSuccess(response) && bridge.getXrayState()) { "Original Xray runtime could not start" }
        }
        if (looksFailed(response)) {
            throw IllegalStateException("Xray start failed: $response")
        }

        started = true
        val path = hermesSocketFile?.absolutePath
        if (path != null && confirmedSuccess(response) &&
            hermesXrayRoute.verifies(runtimeConfig, path) &&
            runCatching { bridge.getXrayState() }.getOrDefault(false)
        ) {
            hermesRuntime = HermesRuntime(path, NativeConfigBinding.fingerprint(runtimeConfig))
        }
        Log.i(TAG, "Xray started: ${redact(response)}")
        response
    }

    private fun validateConfig(datDir: File, configJson: String): String {
        val validationDir = File(service.cacheDir, "xray-validation").apply {
            if (!exists() && !mkdirs()) {
                error("Unable to create Xray validation directory: $absolutePath")
            }
            listFiles()?.forEach { stale ->
                runCatching { stale.delete() }
            }
        }
        val configFile = File.createTempFile("config-", ".json", validationDir)
        return try {
            configFile.writeText(configJson, StandardCharsets.UTF_8)
            val request = bridge.newRunRequest(datDir.absolutePath, configFile.absolutePath)
            bridge.testXray(request)
        } finally {
            if (!configFile.delete()) {
                Log.w(TAG, "Unable to remove temporary Xray validation config")
            }
        }
    }

    fun stop() = synchronized(runnerLock) {
        stopLocked()
    }

    private fun stopLocked() {
        hermesRuntime = null
        try {
            if (!bridge.isInitialized()) return
            if (started || bridge.getXrayState()) {
                val response = runCatching { bridge.stopXray() }
                    .onFailure { Log.w(TAG, "Xray stop failed", it) }
                    .getOrDefault("")
                Log.i(TAG, "Xray stopped: ${redact(response)}")
            }
        } finally {
            started = false
            diagnosticLog?.close()
            diagnosticLog = null
            removeHermesSocket()
        }
    }

    private fun removeHermesSocket() {
        // The path is unique to this runner, never a newer instance's listener.
        hermesSocketFile?.let {
            runCatching { it.delete() }
            runCatching { File(it.path + ".lock").delete() }
        }
        hermesSocketFile = null
    }

    fun isStarted(): Boolean =
        started && synchronized(runnerLock) {
            runCatching { bridge.getXrayState() }.getOrDefault(started)
        }

    private fun looksFailed(response: String?): Boolean {
        val text = decodeResponse(response)
        if (text.isNullOrBlank()) {
            return false
        }
        val lower = text.lowercase()
        if (lower.contains("\"success\":true") || lower.contains("\"status\":\"success\"")) {
            return false
        }
        return lower.contains("error") ||
            lower.contains("failed") ||
            lower.contains("panic") ||
            lower.contains("\"success\":false")
    }

    private fun confirmedSuccess(response: String?): Boolean = runCatching {
        org.json.JSONObject(decodeResponse(response).orEmpty()).opt("success") == true
    }.getOrDefault(false)

    private fun redact(value: String?): String {
        if (value.isNullOrBlank()) {
            return ""
        }
        return (decodeResponse(value) ?: value)
            .replace(
                Regex("(?i)(id|uuid|password|publicKey|shortId)=[^,}\\s]+"),
                "${'$'}1=***",
            )
            .take(500)
    }

    private fun decodeResponse(value: String?): String? {
        if (value.isNullOrBlank()) {
            return value
        }
        return runCatching {
            val decoded = Base64.decode(value, Base64.DEFAULT)
            String(decoded, StandardCharsets.UTF_8).takeIf { it.startsWith("{") }
        }.getOrNull() ?: value
    }

    private class XrayDexBridge {
        @Volatile
        private var initialized = false
        private lateinit var classLoader: ClassLoader
        private lateinit var libXrayClass: Class<*>
        private var dialerControllerProxy: Any? = null
        @Volatile private var cleanBrowserEnvironmentAtLoad = false
        private val protectCallCount = AtomicInteger(0)

        @Synchronized
        fun ensureInitialized(context: Context) {
            if (initialized) {
                return
            }

            val appContext = context.applicationContext
            val jarFile = prepareReadOnlyJar(appContext)
            val optimizedDir = File(appContext.codeCacheDir, "xray-dex").apply {
                if (!exists() && !mkdirs()) {
                    error("Unable to create Xray dex cache: $absolutePath")
                }
            }

            val freshLoader = DexClassLoader(
                jarFile.absolutePath,
                optimizedDir.absolutePath,
                appContext.applicationInfo.nativeLibraryDir,
                ClassLoader.getSystemClassLoader(),
            )
            try {
                val browserEnvironmentClean = hermesEnvironmentClean()
                val candidateClass = freshLoader.loadClass("libXray.LibXray")
                // touch() initializes libgojni via libXray class static initializer.
                candidateClass.getMethod("touch").invoke(null)
                classLoader = freshLoader
                libXrayClass = candidateClass
                cleanBrowserEnvironmentAtLoad = browserEnvironmentClean
                initialized = true
                return
            } catch (error: UnsatisfiedLinkError) {
                if (!error.message.isNullOrBlank() && error.message!!.contains("already opened")) {
                    Log.w(
                        TAG,
                        "libgojni already loaded by another classloader, trying existing runtime bridge",
                    )
                    val existing = kotlin.runCatching {
                        Class.forName("libXray.LibXray", false, appContext.classLoader)
                    }.getOrNull()
                    if (existing != null) {
                        existing.getMethod("touch").invoke(null)
                        classLoader = existing.classLoader ?: ClassLoader.getSystemClassLoader()
                        libXrayClass = existing
                        cleanBrowserEnvironmentAtLoad = false
                        initialized = true
                        return
                    }
                }
                throw error
            }
        }

        private fun prepareReadOnlyJar(context: Context): File {
            val xrayDir = File(context.filesDir, "xray").apply {
                if (!exists() && !mkdirs()) {
                    error("Unable to create Xray dex directory: $absolutePath")
                }
            }
            val jarFile = File(xrayDir, LOCAL_CLASSES)
            val tempFile = File(xrayDir, "$LOCAL_CLASSES.tmp")

            if (tempFile.exists()) {
                tempFile.setWritable(true, true)
                if (!tempFile.delete()) {
                    error("Unable to replace stale Xray dex temp file: ${tempFile.absolutePath}")
                }
            }
            if (jarFile.exists()) {
                jarFile.setWritable(true, true)
                if (!jarFile.delete()) {
                    error("Unable to replace Xray dex file: ${jarFile.absolutePath}")
                }
            }

            context.assets.open(ASSET_CLASSES).use { input ->
                tempFile.outputStream().use { output -> input.copyTo(output) }
            }
            if (!tempFile.setReadOnly()) {
                tempFile.setWritable(false, false)
            }
            if (tempFile.canWrite()) {
                error("Xray dex temp file must be read-only before loading: ${tempFile.absolutePath}")
            }
            if (!tempFile.renameTo(jarFile)) {
                error("Unable to install Xray dex file: ${jarFile.absolutePath}")
            }
            if (!jarFile.setReadOnly()) {
                jarFile.setWritable(false, false)
            }
            if (jarFile.canWrite()) {
                error("Xray dex file must be read-only before loading: ${jarFile.absolutePath}")
            }
            return jarFile
        }

        fun isInitialized(): Boolean = initialized

        fun hermesBrowserDialerExcluded(): Boolean =
            initialized && cleanBrowserEnvironmentAtLoad && hermesEnvironmentClean()

        private fun hermesEnvironmentClean(): Boolean = runCatching {
            // Xray's Go browser_dialer.init() reads these exact aliases.
            // Read before JNI first load and refuse uncertain prior loaders.
            android.system.Os.getenv("xray.browser.dialer").isNullOrEmpty() &&
                android.system.Os.getenv("XRAY_BROWSER_DIALER").isNullOrEmpty()
        }.getOrDefault(false)

        fun registerProtectFd(service: VPNService, observe: (Boolean) -> Unit = {}) {
            ensureInitialized(service.applicationContext)
            val controllerClass = classLoader.loadClass("libXray.DialerController")
            val proxy = Proxy.newProxyInstance(
                classLoader,
                arrayOf(controllerClass),
            ) { _, method, args ->
                when (method.name) {
                    "protectFd" -> {
                        val fd = (args?.firstOrNull() as? Number)?.toInt()
                        val protected = fd != null && service.protect(fd)
                        observe(protected)
                        val call = protectCallCount.incrementAndGet()
                        if (call <= PROTECT_LOG_LIMIT || !protected) {
                            Log.i(
                                TAG,
                                "Xray protectFd call=$call fd=${fd ?: -1} protected=$protected",
                            )
                        }
                        protected
                    }
                    "toString" -> "YurichConnectXrayDialerController"
                    else -> null
                }
            }
            libXrayClass
                .getMethod("registerDialerController", controllerClass)
                .invoke(null, proxy)
            dialerControllerProxy = proxy
        }

        fun xrayVersion(): String {
            check(initialized) { "Xray bridge is not initialized" }
            return libXrayClass.getMethod("xrayVersion").invoke(null) as String
        }

        fun setTunFd(fd: Int) {
            check(initialized) { "Xray bridge is not initialized" }
            libXrayClass.getMethod("setTunFd", Int::class.javaPrimitiveType).invoke(null, fd)
        }

        fun newRunFromJsonRequest(datDir: String, configJson: String): String {
            check(initialized) { "Xray bridge is not initialized" }
            return libXrayClass
                .getMethod("newXrayRunFromJSONRequest", String::class.java, String::class.java)
                .invoke(null, datDir, configJson) as String
        }

        fun newRunRequest(datDir: String, configPath: String): String {
            check(initialized) { "Xray bridge is not initialized" }
            return libXrayClass
                .getMethod("newXrayRunRequest", String::class.java, String::class.java)
                .invoke(null, datDir, configPath) as String
        }

        fun testXray(request: String): String {
            check(initialized) { "Xray bridge is not initialized" }
            return libXrayClass
                .getMethod("testXray", String::class.java)
                .invoke(null, request) as String
        }

        fun runXrayFromJson(request: String): String {
            check(initialized) { "Xray bridge is not initialized" }
            return libXrayClass
                .getMethod("runXrayFromJSON", String::class.java)
                .invoke(null, request) as String
        }

        fun stopXray(): String {
            check(initialized) { "Xray bridge is not initialized" }
            return libXrayClass.getMethod("stopXray").invoke(null) as String
        }

        fun getXrayState(): Boolean {
            check(initialized) { "Xray bridge is not initialized" }
            return libXrayClass.getMethod("getXrayState").invoke(null) as Boolean
        }

        companion object {
            private const val PROTECT_LOG_LIMIT = 3
        }
    }
}
