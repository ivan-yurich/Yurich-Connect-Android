package com.tecclub.flutter_singbox.xray

import android.content.Context
import android.content.pm.PackageManager
import android.os.ParcelFileDescriptor
import android.os.SystemClock
import android.util.AtomicFile
import kotlinx.serialization.json.*
import org.json.JSONObject
import java.io.File
import java.io.InputStreamReader
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/** Soak-only pipe. Raw Xray warnings stay in bounded RAM, never in a file. */
internal class XrayDiagnosticLog private constructor(context: Context) : AutoCloseable {
    private val directory = File(requireNotNull(context.getExternalFilesDir(null)), "soak-control")
    private val pipe = ParcelFileDescriptor.createPipe()
    private val input = ParcelFileDescriptor.AutoCloseInputStream(pipe[0])
    private val closed = AtomicBoolean()
    private val started = SystemClock.elapsedRealtime()
    private val counts = mutableMapOf<XrayDiagnosticKind, Long>()
    private val signatures = mutableMapOf<String, Long>()
    private val writer = Executors.newSingleThreadScheduledExecutor { task ->
        Thread(task, "XrayQACategories").apply { isDaemon = true }
    }

    init {
        Thread({ readWarnings() }, "XrayQAReader").apply { isDaemon = true; start() }
        writer.scheduleWithFixedDelay({ writeSnapshot() }, 0, 1, TimeUnit.SECONDS)
    }

    fun attach(config: String): String {
        val root = Json.parseToJsonElement(config).jsonObject
        val log = (root["log"] as? JsonObject)?.toMutableMap() ?: mutableMapOf()
        log["loglevel"] = JsonPrimitive("warning")
        log["access"] = JsonPrimitive("none")
        log["error"] = JsonPrimitive("/proc/self/fd/${pipe[1].fd}")
        return JsonObject(root.toMutableMap().apply { put("log", JsonObject(log)) }).toString()
    }

    fun record(kind: XrayDiagnosticKind) {
        if (closed.get()) return
        synchronized(counts) { counts[kind] = (counts[kind] ?: 0L) + 1L }
    }

    private fun readWarnings() {
        try {
            InputStreamReader(input, Charsets.UTF_8).use { reader ->
                val buffer = CharArray(2048)
                val line = StringBuilder(1024)
                while (!closed.get()) {
                    val size = reader.read(buffer)
                    if (size < 0) break
                    for (i in 0 until size) {
                        if (buffer[i] == '\n') {
                            if (line.isNotEmpty()) {
                                val text = line.toString()
                                val kind = XrayDiagnosticClassifier.classify(text)
                                record(kind)
                                if (kind == XrayDiagnosticKind.other_warning) {
                                    val signature = XrayDiagnosticClassifier.signature(text)
                                    if (signature.isNotEmpty()) synchronized(counts) {
                                        if (signature in signatures || signatures.size < 8) signatures[signature] = (signatures[signature] ?: 0L) + 1L
                                    }
                                }
                            }
                            line.setLength(0)
                        } else if (line.length < 4096) line.append(buffer[i])
                    }
                }
            }
        } catch (_: Exception) { /* Closing a diagnostic reader never changes VPN state. */ }
    }

    private fun writeSnapshot() {
        runCatching {
            check(directory.isDirectory || directory.mkdirs())
            val values = JSONObject()
            val shapes = JSONObject()
            synchronized(counts) {
                counts.forEach { (kind, count) -> values.put(kind.name, count) }
                signatures.forEach { (signature, count) -> shapes.put(signature, count) }
            }
            val result = JSONObject().put("startedElapsedMs", started)
                .put("elapsedMs", SystemClock.elapsedRealtime()).put("closed", closed.get())
                .put("rawLogsRetained", false).put("counts", values).put("signatures", shapes)
            val file = AtomicFile(File(directory, "xray-categories.json"))
            val output = file.startWrite()
            try { output.write(result.toString().toByteArray(Charsets.UTF_8)); file.finishWrite(output) }
            catch (error: Exception) { file.failWrite(output); throw error }
        }
    }

    override fun close() {
        if (!closed.compareAndSet(false, true)) return
        runCatching { pipe[1].close() }
        runCatching { input.close() }
        writer.execute { writeSnapshot() }
        writer.shutdown()
    }

    companion object {
        @Suppress("DEPRECATION")
        fun openIfEnabled(context: Context): XrayDiagnosticLog? = runCatching {
            val enabled = context.packageManager.getApplicationInfo(context.packageName, PackageManager.GET_META_DATA)
                .metaData?.getBoolean("online.dnsai.ivanvpn.SOAK_NATIVE_OBSERVER", false) == true
            if (enabled) XrayDiagnosticLog(context) else null
        }.getOrNull()
    }
}
