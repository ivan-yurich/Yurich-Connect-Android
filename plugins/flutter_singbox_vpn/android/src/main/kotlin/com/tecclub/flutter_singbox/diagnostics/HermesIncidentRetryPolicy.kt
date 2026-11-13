package com.tecclub.flutter_singbox.diagnostics

import java.text.ParsePosition
import java.text.SimpleDateFormat
import java.util.Locale
import java.util.TimeZone

internal sealed interface HermesIncidentDisposition {
    data object Accepted : HermesIncidentDisposition
    data object Drop : HermesIncidentDisposition
    /** Stop attempts for this authorization until explicit readmission. */
    data object Pause : HermesIncidentDisposition
    data class RetryAt(val atMs: Long) : HermesIncidentDisposition
}

/** Pure post-attempt policy: the caller owns the queue, credentials, and clock. */
internal object HermesIncidentRetryPolicy {
    const val MAX_TTL_MS = 72L * 60 * 60 * 1_000
    private const val MIN_RETRY_MS = 30_000L
    private const val MAX_BACKOFF_MS = 60 * 60 * 1_000L
    private const val MAX_EXPONENT = 7
    private const val MAX_HEADER_LENGTH = 128
    private val httpDate = Regex(
        "[A-Za-z]{3}, [0-9]{2} [A-Za-z]{3} [0-9]{4} [0-9]{2}:[0-9]{2}:[0-9]{2} GMT",
    )

    /** [attempt] is the 1-based attempt that just completed. null status is an I/O failure. */
    fun decide(
        httpStatus: Int?,
        retryAfter: String? = null,
        attempt: Int,
        nowMs: Long,
        expiresAtMs: Long,
    ): HermesIncidentDisposition {
        // A rejected credential blocks the lane even when the attempted row expired in flight.
        if (httpStatus == 401 || httpStatus == 403) return HermesIncidentDisposition.Pause
        if (nowMs >= expiresAtMs) return HermesIncidentDisposition.Drop

        return when {
            httpStatus == 204 -> HermesIncidentDisposition.Accepted
            httpStatus == 429 -> beforeExpiry(rateLimitUntil(retryAfter, attempt, nowMs), expiresAtMs)
            httpStatus == null || httpStatus in 500..599 ->
                beforeExpiry(addDelay(nowMs, backoffMs(attempt)), expiresAtMs)
            // 400/409/413, redirects, and unexpected responses are not retried.
            else -> HermesIncidentDisposition.Drop
        }
    }

    fun expiresAt(occurredAtMs: Long): Long = addDelay(occurredAtMs, MAX_TTL_MS)

    /** A 429 limits the sender, even if the affected report is discarded at its own expiry. */
    fun rateLimitUntil(retryAfter: String?, attempt: Int, nowMs: Long): Long =
        retryAfterTime(retryAfter, nowMs)?.coerceAtLeast(addDelay(nowMs, MIN_RETRY_MS))
            ?: addDelay(nowMs, backoffMs(attempt))

    private fun beforeExpiry(atMs: Long, expiresAtMs: Long): HermesIncidentDisposition =
        if (atMs < expiresAtMs) HermesIncidentDisposition.RetryAt(atMs) else HermesIncidentDisposition.Drop

    private fun backoffMs(attempt: Int): Long {
        val exponent = attempt.coerceIn(1, MAX_EXPONENT + 1) - 1
        return (MIN_RETRY_MS shl exponent).coerceAtMost(MAX_BACKOFF_MS)
    }

    private fun retryAfterTime(header: String?, nowMs: Long): Long? {
        if (header == null) return null
        val value = header.trim(' ', '\t')
        if (value.isEmpty()) return null
        // An excessive server delay must not be shortened to our fallback backoff.
        if (value.all { it in '0'..'9' }) {
            val seconds = value.trimStart('0').ifEmpty { "0" }.toLongOrNull() ?: return Long.MAX_VALUE
            return addDelay(nowMs, seconds.coerceAtMost(Long.MAX_VALUE / 1_000) * 1_000)
        }
        if (value.length > MAX_HEADER_LENGTH || !httpDate.matches(value)) return null

        // IMF-fixdate. java.text is available below Android API 26, unlike java.time.
        val formatter = SimpleDateFormat("EEE, dd MMM yyyy HH:mm:ss 'GMT'", Locale.US).apply {
            timeZone = TimeZone.getTimeZone("GMT")
            isLenient = false
        }
        val position = ParsePosition(0)
        val parsed = formatter.parse(value, position) ?: return null
        return parsed.time.takeIf { position.index == value.length && formatter.format(parsed) == value }
    }

    private fun addDelay(nowMs: Long, delayMs: Long): Long =
        if (nowMs > Long.MAX_VALUE - delayMs) Long.MAX_VALUE else nowMs + delayMs
}
