package com.tecclub.flutter_singbox.config

import android.content.Context
import android.util.AtomicFile
import java.io.File
import java.io.FileNotFoundException
import java.io.RandomAccessFile

/** Non-secret intent only, NOT proof that Android's firewall is enabled.
 * Device-protected + atomic + cross-process lock: SharedPreferences caches in
 * main/:vpn must not downgrade a strict session during a TUN-less restart.
 */
internal object KillSwitchIntentStore {
    private val mutex = Any()

    fun hasStoredIntent(context: Context): Boolean = locked(context) { file ->
        file.baseFile.parentFile?.list()?.any { it != "intent.lock" } ?: true
    }

    fun requested(context: Context): Boolean = try {
        locked(context) { file ->
            try {
                file.openRead().use { StrictProtectionIntent.decode(it.readBytes().toString(Charsets.US_ASCII).trim()) }
            } catch (_: FileNotFoundException) {
                // A process may die during the first atomic commit. Do not
                // reinterpret a staged/backup intent as a never-enabled mode.
                StrictProtectionIntent.missingRead(
                    file.baseFile.exists(),
                    File(file.baseFile.path + ".new").exists(),
                    File(file.baseFile.path + ".bak").exists(),
                )
            }
        }
    } catch (_: Exception) {
        true // Unreadable/corrupt intent must never create a direct fallback.
    }

    fun setRequested(context: Context, enabled: Boolean) = locked(context) { file ->
        val output = file.startWrite()
        try {
            output.write(if (enabled) byteArrayOf(49) else byteArrayOf(48))
            file.finishWrite(output)
        } catch (error: Exception) {
            file.failWrite(output)
            throw error
        }
    }

    private fun <T> locked(context: Context, action: (AtomicFile) -> T): T = synchronized(mutex) {
        val directory = File(context.createDeviceProtectedStorageContext().filesDir, "vpn-protection")
        check(directory.isDirectory || directory.mkdirs()) { "Protection intent storage unavailable" }
        RandomAccessFile(File(directory, "intent.lock"), "rw").use { lockFile ->
            lockFile.channel.use { channel ->
                channel.lock().use { action(AtomicFile(File(directory, "strict-requested"))) }
            }
        }
    }
}

internal object StrictProtectionIntent {
    fun missingRead(basePresent: Boolean, stagedPresent: Boolean, backupPresent: Boolean): Boolean =
        basePresent || stagedPresent || backupPresent

    fun decode(value: String): Boolean = when (value) {
        "1" -> true
        "0" -> false
        else -> error("Invalid protection intent")
    }

    // False from VpnService before establish() is NOT a request to downgrade.
    fun required(persisted: Boolean, systemStart: Boolean, liveSystemOn: Boolean): Boolean =
        persisted || systemStart || liveSystemOn
}
