package com.tecclub.flutter_singbox.xray

import android.content.Context
import android.util.Base64
import android.util.Log
import com.tecclub.flutter_singbox.bg.VPNService
import dalvik.system.DexClassLoader
import java.io.File
import java.lang.reflect.Proxy
import java.nio.charset.StandardCharsets

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

    fun start(configJson: String): String = synchronized(runnerLock) {
        stopLocked()

        val datDir = File(service.filesDir, "xray").apply {
            if (!exists() && !mkdirs()) {
                error("Unable to create Xray data directory: $absolutePath")
            }
        }

        val configFile = File(datDir, "xray-config.json").apply {
            writeText(configJson, StandardCharsets.UTF_8)
        }
        bridge.ensureInitialized(service.applicationContext)
        val testRequest = bridge.newRunRequest(datDir.absolutePath, configFile.absolutePath)
        val testResponse = bridge.testXray(testRequest)
        if (looksFailed(testResponse)) {
            throw IllegalStateException("Xray config validation failed: $testResponse")
        }

        val tun = service.openXrayTun()
        bridge.registerProtectFd(service)
        bridge.setTunFd(tun.fd)

        val request = bridge.newRunFromJsonRequest(datDir.absolutePath, configJson)
        val response = bridge.runXrayFromJson(request)
        if (looksFailed(response)) {
            throw IllegalStateException("Xray start failed: $response")
        }

        started = true
        Log.i(TAG, "Xray started: ${redact(response)}")
        response
    }

    fun stop() = synchronized(runnerLock) {
        stopLocked()
    }

    private fun stopLocked() {
        if (!bridge.isInitialized()) {
            return
        }

        if (started || bridge.getXrayState()) {
            val response = runCatching { bridge.stopXray() }
                .onFailure { Log.w(TAG, "Xray stop failed", it) }
                .getOrDefault("")
            Log.i(TAG, "Xray stopped: ${redact(response)}")
        }
        started = false
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
                val candidateClass = freshLoader.loadClass("libXray.LibXray")
                // touch() initializes libgojni via libXray class static initializer.
                candidateClass.getMethod("touch").invoke(null)
                classLoader = freshLoader
                libXrayClass = candidateClass
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

        fun registerProtectFd(service: VPNService) {
            ensureInitialized(service.applicationContext)
            val controllerClass = classLoader.loadClass("libXray.DialerController")
            val proxy = Proxy.newProxyInstance(
                classLoader,
                arrayOf(controllerClass),
            ) { _, method, args ->
                when (method.name) {
                    "protectFd" -> {
                        val fd = (args?.firstOrNull() as? Number)?.toInt()
                        fd != null && service.protect(fd)
                    }
                    "toString" -> "YurichConnectXrayDialerController"
                    else -> null
                }
            }
            libXrayClass
                .getMethod("registerDialerController", controllerClass)
                .invoke(null, proxy)
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
    }
}
