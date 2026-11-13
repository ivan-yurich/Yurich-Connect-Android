package com.tecclub.flutter_singbox.diagnostics

import java.time.Instant
import kotlin.test.Test
import kotlin.test.assertEquals

class HermesIncidentRetryPolicyTest {
    private val now = Instant.parse("2026-11-12T10:31:00Z").toEpochMilli()
    private val expiry = HermesIncidentRetryPolicy.expiresAt(now)

    private fun decide(status: Int?, header: String? = null, attempt: Int = 1, expires: Long = expiry) =
        HermesIncidentRetryPolicy.decide(status, header, attempt, now, expires)

    @Test
    fun `only 204 acknowledges and unexpected statuses never cause a retry`() {
        assertEquals(HermesIncidentDisposition.Accepted, decide(204))
        for (status in listOf(200, 202, 301, 302, 303, 307, 308, 400, 404, 409, 413)) {
            assertEquals(HermesIncidentDisposition.Drop, decide(status, "120"), "HTTP $status")
        }
    }

    @Test
    fun `rejected credential pauses the lane even if the row expired in flight`() {
        for (status in listOf(401, 403)) {
            assertEquals(HermesIncidentDisposition.Pause, decide(status))
            assertEquals(HermesIncidentDisposition.Pause, decide(status, expires = now))
        }
    }

    @Test
    fun `network and 5xx use positive exponential capped backoff`() {
        assertEquals(HermesIncidentDisposition.RetryAt(now + 30_000), decide(null))
        assertEquals(HermesIncidentDisposition.RetryAt(now + 60_000), decide(502, attempt = 2))
        assertEquals(HermesIncidentDisposition.RetryAt(now + 120_000), decide(599, attempt = 3))
        assertEquals(HermesIncidentDisposition.RetryAt(now + 3_600_000), decide(503, attempt = Int.MAX_VALUE))
        assertEquals(HermesIncidentDisposition.RetryAt(now + 30_000), decide(null, attempt = Int.MIN_VALUE))
    }

    @Test
    fun `429 respects numeric and dated Retry-After without immediate retry`() {
        assertEquals(HermesIncidentDisposition.RetryAt(now + 90_000), decide(429, "\t0090 "))
        assertEquals(HermesIncidentDisposition.RetryAt(now + 150_000), decide(429, "Thu, 12 Nov 2026 10:33:30 GMT"))
        assertEquals(HermesIncidentDisposition.RetryAt(now + 30_000), decide(429, "0"))
        assertEquals(HermesIncidentDisposition.RetryAt(now + 30_000), decide(429, "Thu, 12 Nov 2026 10:30:00 GMT"))
        assertEquals(HermesIncidentDisposition.RetryAt(now + 60_000), decide(429, "Wed, 12 Nov 2026 10:33:30 GMT", attempt = 2))
        assertEquals(HermesIncidentDisposition.RetryAt(now + 60_000), decide(429, "+90", attempt = 2))
    }

    @Test
    fun `nothing retries at expiry or earlier than a long Retry-After`() {
        assertEquals(72 * 60 * 60 * 1_000L, expiry - now)
        assertEquals(HermesIncidentDisposition.Drop, decide(null, expires = now))
        assertEquals(HermesIncidentDisposition.Drop, decide(500, expires = now + 30_000))
        assertEquals(HermesIncidentDisposition.Drop, decide(429, "90", expires = now + 60_000))
        assertEquals(now + 90_000, HermesIncidentRetryPolicy.rateLimitUntil("90", attempt = 1, nowMs = now))
        assertEquals(HermesIncidentDisposition.Drop, decide(429, "9".repeat(140)))
        assertEquals(HermesIncidentDisposition.Drop, decide(429, Long.MAX_VALUE.toString()))
        assertEquals(Long.MAX_VALUE, HermesIncidentRetryPolicy.expiresAt(Long.MAX_VALUE - 1))
    }
}
