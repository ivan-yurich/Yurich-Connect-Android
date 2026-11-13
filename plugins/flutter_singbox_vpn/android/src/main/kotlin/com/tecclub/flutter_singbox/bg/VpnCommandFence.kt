package com.tecclub.flutter_singbox.bg

import android.content.Context
import android.util.AtomicFile
import java.io.File
import java.io.RandomAccessFile
import java.util.UUID

/** Orders app-issued VPN commands in main and :vpn, not system-owned starts. */
internal object VpnCommandFence {
    const val EXTRA_TOKEN = "yurich_vpn_command_token"
    private val mutex = Any()
    private const val TOKEN_LENGTH = 38

    enum class Kind(val prefix: String) { Start("s:"), Stop("x:") }

    fun issue(context: Context, kind: Kind): String = locked(context) { file ->
        val token = kind.prefix + UUID.randomUUID()
        val output = file.startWrite()
        try {
            output.write(token.toByteArray(Charsets.US_ASCII))
            file.finishWrite(output)
        } catch (error: Exception) {
            file.failWrite(output)
            throw error
        }
        check(read(file) == token) { "VPN command was not committed" }
        token
    }

    /** Lock only the synchronous service ingress; never wait for runtime or network inside. */
    fun <T> runCurrent(context: Context, token: String?, kind: Kind, action: () -> T): T? = try {
        locked(context) { file ->
            if (accepts(read(file), token, kind)) action() else null
        }
    } catch (_: Exception) {
        // I/O unavailable is not authorization to start or reload. Do not
        // throw from onStartCommand or an Android broadcast receiver.
        null
    }

    fun isCurrentStart(context: Context, token: String): Boolean = runCatching {
        runCurrent(context, token, Kind.Start) { true } == true
    }.getOrDefault(false)

    internal fun accepts(current: String?, incoming: String?, kind: Kind): Boolean =
        incoming != null && incoming.length == TOKEN_LENGTH && incoming.startsWith(kind.prefix) && incoming == current

    private fun read(file: AtomicFile): String? = runCatching {
        file.openRead().use { input ->
            val bytes = ByteArray(TOKEN_LENGTH + 1)
            val count = input.read(bytes)
            if (count == TOKEN_LENGTH && input.read() == -1) {
                String(bytes, 0, TOKEN_LENGTH, Charsets.US_ASCII)
            } else null
        }
    }.getOrNull()

    private fun <T> locked(context: Context, action: (AtomicFile) -> T): T = synchronized(mutex) {
        val directory = File(context.createDeviceProtectedStorageContext().noBackupFilesDir, "vpn-command")
        check(directory.isDirectory || directory.mkdirs() || directory.isDirectory) { "VPN command storage unavailable" }
        RandomAccessFile(File(directory, "command.lock"), "rw").use { lock ->
            lock.channel.lock().use { action(AtomicFile(File(directory, "latest"))) }
        }
    }
}
