package online.dnsai.ivanvpn.qa

import android.content.Context
import android.content.Intent
import android.util.AtomicFile
import android.util.Log
import com.tecclub.flutter_singbox.diagnostics.OnDeviceDiagnostics
import org.json.JSONObject
import java.io.File
import java.io.FileInputStream
import java.io.FilterOutputStream
import java.io.IOException
import java.io.OutputStream
import java.security.MessageDigest

internal object PassiveSoakController {
    const val COMMAND_START = "passive-start"
    const val COMMAND_STATUS = "passive-status"
    const val COMMAND_STOP = "passive-stop"
    const val COMMAND_EXPORT = "passive-export"

    internal const val EXTRA_REQUEST_ID = "requestId"
    private const val STATUS_FILE = "passive-status.json"
    private const val ARTIFACT_FILE = "passive-soak.zip"
    private const val MAX_ARTIFACT_BYTES = 24L * 1024 * 1024
    private const val PASSIVE_MODE = "passive_24h"
    private const val TAG = "PassiveSoakController"
    private val requestIdPattern = Regex("[A-Za-z0-9_-]{1,64}")
    private val commands = setOf(COMMAND_START, COMMAND_STATUS, COMMAND_STOP, COMMAND_EXPORT)
    private val exportLock = Any()
    private val statusLock = Any()
    private val booleanFields = setOf("active", "available")
    private val numericFields = setOf(
        "startedAtMs", "endsAtMs", "endedAtMs", "events", "rotatedEvents",
        "durationMs", "durationHours", "durationDays",
    )

    fun supports(command: String?): Boolean = command in commands

    fun handle(context: Context, intent: Intent) {
        val command = intent.getStringExtra(SoakControlCommandHandler.EXTRA_COMMAND)
            ?.trim()?.lowercase().orEmpty()
        val suppliedRequestId = intent.getStringExtra(EXTRA_REQUEST_ID).orEmpty()
        val requestId = suppliedRequestId.takeIf(requestIdPattern::matches) ?: "invalid"
        val response = JSONObject()
            .put("schema", 1)
            .put("requestId", requestId)
            .put("command", command.takeIf { it in commands } ?: "invalid")
            .put("timestampMs", System.currentTimeMillis())
            .put("secretsIncluded", false)
            .put("sampling", "opportunistic")

        try {
            require(requestId != "invalid") { "Invalid request id" }
            val state = when (command) {
                COMMAND_START -> OnDeviceDiagnostics.startPassive(context)
                COMMAND_STATUS -> OnDeviceDiagnostics.status(context)
                COMMAND_STOP -> OnDeviceDiagnostics.stopPassive(context)
                COMMAND_EXPORT -> synchronized(exportLock) { export(context, response) }
                else -> error("Unsupported passive command")
            }
            appendSafeState(response, state)
            response.put("ok", true)
        } catch (error: Throwable) {
            response.put("ok", false)
            response.put("errorCode", errorCode(command, error))
            Log.w(TAG, "Passive QA command failed type=${error.javaClass.simpleName}")
        }

        writeStatus(context, response)
    }

    private fun export(context: Context, response: JSONObject): Map<String, Any> {
        val state = OnDeviceDiagnostics.status(context)
        if (state["available"] != true || state["mode"] != PASSIVE_MODE) {
            throw CommandFailure("no_passive_run")
        }
        val directory = soakDirectory(context)
        val target = File(directory, ARTIFACT_FILE)
        val atomic = AtomicFile(target)
        val stream = atomic.startWrite()
        try {
            OnDeviceDiagnostics.export(context, BoundedNonClosingOutputStream(stream, MAX_ARTIFACT_BYTES))
            atomic.finishWrite(stream)
        } catch (error: Throwable) {
            atomic.failWrite(stream)
            throw error
        }
        response.put("artifactFile", ARTIFACT_FILE)
        response.put("artifactBytes", target.length())
        response.put("artifactSha256", sha256(target))
        return OnDeviceDiagnostics.status(context)
    }

    private fun appendSafeState(target: JSONObject, state: Map<String, Any>) {
        booleanFields.forEach { key ->
            (state[key] as? Boolean)?.let { target.put(key, it) }
        }
        numericFields.forEach { key ->
            (state[key] as? Number)?.let { target.put(key, it.toLong()) }
        }
        val mode = state["mode"] as? String
        if (mode == "standard" || mode == PASSIVE_MODE) target.put("mode", mode)
    }

    private fun errorCode(command: String, error: Throwable): String = when {
        error is CommandFailure -> error.code
        error is IllegalArgumentException -> "invalid_request"
        error is IllegalStateException && command == COMMAND_START -> "active_run_conflict"
        error is IllegalStateException && command == COMMAND_STOP -> "active_run_conflict"
        error is ArtifactTooLargeException -> "artifact_too_large"
        else -> "internal_error"
    }

    private fun writeStatus(context: Context, response: JSONObject) {
        synchronized(statusLock) {
            val atomic = AtomicFile(File(soakDirectory(context), STATUS_FILE))
            val stream = atomic.startWrite()
            try {
                stream.write((response.toString() + "\n").toByteArray(Charsets.UTF_8))
                atomic.finishWrite(stream)
            } catch (error: Throwable) {
                atomic.failWrite(stream)
                throw error
            }
        }
    }

    private fun soakDirectory(context: Context): File {
        val directory = context.getExternalFilesDir("soak")
            ?: error("External app storage unavailable")
        check(directory.isDirectory || directory.mkdirs()) { "Unable to create soak directory" }
        return directory
    }

    private fun sha256(file: File): String {
        val digest = MessageDigest.getInstance("SHA-256")
        FileInputStream(file).use { input ->
            val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
            while (true) {
                val count = input.read(buffer)
                if (count < 0) break
                digest.update(buffer, 0, count)
            }
        }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }

    private class BoundedNonClosingOutputStream(
        delegate: OutputStream,
        private val limit: Long,
    ) : FilterOutputStream(delegate) {
        private var written = 0L

        override fun write(value: Int) {
            requireCapacity(1)
            out.write(value)
            written++
        }

        override fun write(buffer: ByteArray, offset: Int, length: Int) {
            requireCapacity(length)
            out.write(buffer, offset, length)
            written += length
        }

        private fun requireCapacity(count: Int) {
            if (count < 0 || written > limit - count) throw ArtifactTooLargeException()
        }

        override fun close() = flush()
    }

    private class ArtifactTooLargeException : IOException()
    private class CommandFailure(val code: String) : IllegalStateException()
}
