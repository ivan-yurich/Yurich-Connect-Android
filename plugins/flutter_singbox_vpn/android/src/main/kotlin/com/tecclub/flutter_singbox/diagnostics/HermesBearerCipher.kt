package com.tecclub.flutter_singbox.diagnostics

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import androidx.annotation.RequiresApi
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** Only ciphertext is persisted. The separate key never leaves Android Keystore. */
@RequiresApi(23)
internal object HermesBearerCipher {
    private const val STORE = "AndroidKeyStore"
    private const val ALIAS = "yurich_hermes_bearer_v1"
    private const val CIPHER = "AES/GCM/NoPadding"

    fun seal(value: String, epoch: String, revision: String): String {
        require(HermesPilotGate.validBearer(value))
        val cipher = Cipher.getInstance(CIPHER)
        cipher.init(Cipher.ENCRYPT_MODE, key(create = true))
        cipher.updateAAD(aad(epoch, revision))
        val plain = value.toByteArray(Charsets.US_ASCII)
        return try {
            val encrypted = cipher.doFinal(plain)
            Base64.encodeToString(cipher.iv + encrypted, Base64.NO_WRAP)
        } finally {
            plain.fill(0)
        }
    }

    fun open(envelope: String, epoch: String, revision: String): String {
        val bytes = Base64.decode(envelope, Base64.NO_WRAP)
        require(bytes.size in 29..540)
        val cipher = Cipher.getInstance(CIPHER)
        cipher.init(Cipher.DECRYPT_MODE, key(create = false), GCMParameterSpec(128, bytes, 0, 12))
        cipher.updateAAD(aad(epoch, revision))
        val plain = cipher.doFinal(bytes, 12, bytes.size - 12)
        return try {
            plain.toString(Charsets.US_ASCII).also { require(HermesPilotGate.validBearer(it)) }
        } finally {
            plain.fill(0)
        }
    }

    private fun aad(epoch: String, revision: String) =
        "Yurich Hermes v1:$epoch:$revision".toByteArray(Charsets.US_ASCII)

    private fun key(create: Boolean): SecretKey {
        val store = KeyStore.getInstance(STORE).apply { load(null) }
        (store.getKey(ALIAS, null) as? SecretKey)?.let { return it }
        check(create) { "Hermes credential key unavailable" }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, STORE).apply {
            init(KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setRandomizedEncryptionRequired(true)
                .setKeySize(256)
                .build())
        }.generateKey()
    }
}
