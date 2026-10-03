package com.tecclub.flutter_singbox.bg

import java.security.MessageDigest

internal data class NativeConfigBinding(val generation: Long, val fingerprint: String) {
    fun forGeneration(currentGeneration: Long): String? =
        fingerprint.takeIf { generation == currentGeneration && isFingerprint(it) }

    companion object {
        private val fingerprintPattern = Regex("[0-9a-f]{64}")
        fun isFingerprint(value: String): Boolean = fingerprintPattern.matches(value)
        fun fingerprint(config: String): String = MessageDigest.getInstance("SHA-256")
            .digest(config.toByteArray(Charsets.UTF_8))
            .joinToString("") { byte -> "%02x".format(byte) }
    }
}
