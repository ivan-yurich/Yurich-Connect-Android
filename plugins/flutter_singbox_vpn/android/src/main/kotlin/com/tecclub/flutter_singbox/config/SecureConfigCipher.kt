package com.tecclub.flutter_singbox.config

import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

internal object SecureConfigCipher {
    private const val KEYSTORE = "AndroidKeyStore"
    private const val KEY_ALIAS = "yurich_connect_runtime_config_v1"
    private const val PREFIX = "yc1"
    private const val SEPARATOR = ":"
    private const val TRANSFORMATION = "AES/GCM/NoPadding"
    private const val GCM_TAG_BITS = 128
    @Volatile private var cachedKey: SecretKey? = null

    fun isEncrypted(value: String): Boolean = value.startsWith("$PREFIX$SEPARATOR")

    @Synchronized
    fun encrypt(plainText: String): String {
        check(Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            "Encrypted runtime config requires Android 6.0 or newer"
        }
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, getOrCreateKey())
        val encrypted = cipher.doFinal(plainText.toByteArray(Charsets.UTF_8))
        return listOf(
            PREFIX,
            Base64.encodeToString(cipher.iv, Base64.NO_WRAP),
            Base64.encodeToString(encrypted, Base64.NO_WRAP),
        ).joinToString(SEPARATOR)
    }

    @Synchronized
    fun decrypt(envelope: String): String {
        check(Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            "Encrypted runtime config requires Android 6.0 or newer"
        }
        val parts = envelope.split(SEPARATOR, limit = 3)
        require(parts.size == 3 && parts[0] == PREFIX) { "Invalid encrypted config envelope" }
        val iv = Base64.decode(parts[1], Base64.NO_WRAP)
        val encrypted = Base64.decode(parts[2], Base64.NO_WRAP)
        require(iv.size == 12 && encrypted.isNotEmpty()) { "Invalid encrypted config payload" }

        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.DECRYPT_MODE, getOrCreateKey(), GCMParameterSpec(GCM_TAG_BITS, iv))
        return String(cipher.doFinal(encrypted), Charsets.UTF_8)
    }

    private fun getOrCreateKey(): SecretKey {
        cachedKey?.let { return it }
        val keyStore = KeyStore.getInstance(KEYSTORE).apply { load(null) }
        (keyStore.getKey(KEY_ALIAS, null) as? SecretKey)?.let {
            cachedKey = it
            return it
        }

        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, KEYSTORE)
        generator.init(
            KeyGenParameterSpec.Builder(
                KEY_ALIAS,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setRandomizedEncryptionRequired(true)
                .setKeySize(256)
                .build(),
        )
        return generator.generateKey().also { cachedKey = it }
    }
}
