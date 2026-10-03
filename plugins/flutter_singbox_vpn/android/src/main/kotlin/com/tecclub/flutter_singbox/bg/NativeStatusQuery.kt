package com.tecclub.flutter_singbox.bg

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import com.tecclub.flutter_singbox.constant.Action
import com.tecclub.flutter_singbox.constant.Status
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withTimeoutOrNull
import kotlin.coroutines.resume

internal object NativeStatusQuery {
    fun encode(status: Status): Int = status.ordinal + 1

    fun matchesConfig(actual: String?, expected: String?): Boolean =
        actual != null && expected != null && NativeConfigBinding.isFingerprint(actual) && actual == expected

    fun decode(code: Int, fingerprint: String?, expected: String?): Status? {
        val status = Status.values().getOrNull(code - 1) ?: return null
        return if (status == Status.Started && !matchesConfig(fingerprint, expected)) Status.Starting else status
    }

    suspend fun read(context: Context, expected: String?): Status? = withTimeoutOrNull(750L) {
        suspendCancellableCoroutine { continuation ->
            val reply = object : BroadcastReceiver() {
                override fun onReceive(context: Context?, intent: Intent?) {
                    if (continuation.isActive) {
                        continuation.resume(decode(resultCode, resultData, expected))
                    }
                }
            }
            try {
                context.sendOrderedBroadcast(
                    Intent(Action.SERVICE_STATUS_QUERY)
                        .setPackage(context.packageName)
                        .addFlags(Intent.FLAG_RECEIVER_REGISTERED_ONLY),
                    null, reply, Handler(Looper.getMainLooper()), 0, null, null,
                )
            } catch (_: Exception) {
                if (continuation.isActive) continuation.resume(null)
            }
        }
    }
}
