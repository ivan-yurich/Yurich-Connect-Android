package com.tecclub.flutter_singbox.diagnostics

import kotlinx.serialization.json.*

/**
 * Small journal next to the existing queue. No report bodies or endpoint data.
 * All transitions run under the queue's cross-process lock.
 */
internal data class HermesPacing(
    val earliest: Long = 0,
    val limitedUntil: Long = 0,
    val reportId: String? = null,
    val attempts: Int = 0,
    val retryAt: Long = 0,
) {
    fun mayReserve(report: HermesIncidentReport, now: Long): Boolean =
        now >= maxOf(earliest, limitedUntil, if (reportId == report.reportId) retryAt else 0) &&
            now < HermesIncidentRetryPolicy.expiresAt(report.occurredAtMillis)

    fun reserve(report: HermesIncidentReport, now: Long): HermesPacing? {
        if (!mayReserve(report, now)) return null
        val attempt = if (reportId == report.reportId) attempts.coerceAtMost(Int.MAX_VALUE - 1) + 1 else 1
        val next = (now + HermesIncidentDispatch.MIN_REQUEST_INTERVAL_MS).coerceAtLeast(now)
        // Persist a failure delay before opening a stream. Death/cancellation
        // cannot bypass pacing or turn an uncertain write into a new UUID.
        val expiry = HermesIncidentRetryPolicy.expiresAt(report.occurredAtMillis)
        val failure = HermesIncidentRetryPolicy.decide(null, null, attempt, now, expiry)
        val retry = (failure as? HermesIncidentDisposition.RetryAt)?.atMs ?: expiry
        return copy(earliest = next, reportId = report.reportId, attempts = attempt, retryAt = retry)
    }

    fun complete(now: Long, expiresAt: Long, status: Int?, retryAfter: String?): Pair<HermesPacing, HermesIncidentDisposition> {
        val next = if (status == 429) maxOf(
            limitedUntil, HermesIncidentRetryPolicy.rateLimitUntil(retryAfter, attempts, now),
        ) else limitedUntil
        val decision = HermesIncidentRetryPolicy.decide(status, retryAfter, attempts, now, expiresAt)
        val pacing = when (decision) {
            is HermesIncidentDisposition.RetryAt -> copy(limitedUntil = next, retryAt = decision.atMs)
            HermesIncidentDisposition.Pause -> copy(limitedUntil = next)
            HermesIncidentDisposition.Accepted, HermesIncidentDisposition.Drop ->
                copy(limitedUntil = next, reportId = null, attempts = 0, retryAt = 0)
        }
        return pacing to decision
    }
}

internal class HermesGrant(val epoch: String, val revision: String, val ciphertext: String, val blocked: Boolean = false)

internal class HermesLedger(
    val grant: HermesGrant? = null,
    val pendingClearEpoch: String? = null,
    val pacing: HermesPacing = HermesPacing(),
) {
    fun encode(): String = buildJsonObject {
        put("v", 1)
        put("grant", grant?.let {
            buildJsonObject {
                put("epoch", it.epoch)
                put("revision", it.revision)
                put("ciphertext", it.ciphertext)
                put("blocked", it.blocked)
            }
        } ?: JsonNull)
        put("clear", pendingClearEpoch?.let(::JsonPrimitive) ?: JsonNull)
        put("earliest", pacing.earliest)
        put("limited", pacing.limitedUntil)
        put("report", pacing.reportId?.let(::JsonPrimitive) ?: JsonNull)
        put("attempts", pacing.attempts)
        put("retryAt", pacing.retryAt)
    }.toString()

    companion object {
        private val uuid = Regex("[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}")
        private val cipher = Regex("[A-Za-z0-9+/]+={0,2}")
        fun decode(raw: String?): HermesLedger {
            if (raw == null) return HermesLedger()
            val root = Json.parseToJsonElement(raw).jsonObject
            require(root.keys == setOf("v", "grant", "clear", "earliest", "limited", "report", "attempts", "retryAt"))
            require(root["v"] == JsonPrimitive(1))
            val grant = root.getValue("grant").takeUnless { it == JsonNull }?.jsonObject?.let {
                require(it.keys == setOf("epoch", "revision", "ciphertext", "blocked"))
                val encrypted = it.getValue("ciphertext").jsonPrimitive
                require(encrypted.isString && encrypted.content.length in 40..720 && cipher.matches(encrypted.content))
                val blocked = it.getValue("blocked")
                require(blocked == JsonPrimitive(true) || blocked == JsonPrimitive(false))
                HermesGrant(requireNotNull(it.id("epoch")), requireNotNull(it.id("revision")), encrypted.content,
                    blocked == JsonPrimitive(true))
            }
            val pending = root.id("clear")
            require(pending == null || grant == null)
            val report = root.id("report")
            val attempts = root.time("attempts")
            require(attempts <= Int.MAX_VALUE && (report == null) == (attempts == 0L))
            return HermesLedger(grant, pending,
                HermesPacing(root.time("earliest"), root.time("limited"), report, attempts.toInt(), root.time("retryAt")))
        }

        private fun JsonObject.id(key: String): String? {
            val primitive = getValue(key).jsonPrimitive
            if (primitive == JsonNull) return null
            require(primitive.isString && uuid.matches(primitive.content))
            return primitive.content
        }

        private fun JsonObject.time(key: String): Long = getValue(key).jsonPrimitive.let {
            require(!it.isString)
            requireNotNull(it.longOrNull).also { value -> require(value >= 0) }
        }
    }
}
