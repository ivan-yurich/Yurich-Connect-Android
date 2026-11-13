package com.tecclub.flutter_singbox.diagnostics

/** Mock evidence only. These numbers do not prove VPN ownership or routing on Android. */
internal data class HermesIncidentAdmission(
    val consentEpoch: String,
    val accessRevision: Long,
    val tunnelRevision: Long,
)

/**
 * In-memory, transport-free model for a single mock dispatch lane. No Android
 * code must supply an admission until a real VPN-bound transport exists. The
 * caller serializes mock admission and queue changes with these operations;
 * this object does not own a socket, scheduler, credential, or cross-process lock.
 */
internal class HermesIncidentDispatch(
    private val queue: LocalConnectionIncidentQueue,
    private val storage: LocalIncidentStorage,
    private val now: () -> Long,
    private val admission: () -> HermesIncidentAdmission?,
) {
    internal class Ticket internal constructor(val reportId: String)

    private data class Attempt(val count: Int, val notBeforeMs: Long)

    private data class Flight(
        val ticket: Ticket,
        val admission: HermesIncidentAdmission,
        val expiresAtMs: Long,
        var attempt: Int = 0,
    )

    private val attempts = mutableMapOf<String, Attempt>()
    private var flight: Flight? = null
    private var pausedThroughAccessRevision = 0L
    private var rateLimitedUntilMs = Long.MIN_VALUE
    private var nextWriteAtMs = Long.MIN_VALUE

    @Synchronized
    fun claim(): Ticket? {
        val proof = admitted()
        if (proof == null) {
            flight = null
            return null
        }
        val active = flight
        val candidates = candidates(proof)
        val at = now()
        if (active != null && active.admission == proof && at < active.expiresAtMs &&
            candidates.any { it.reportId == active.ticket.reportId }
        ) return null
        flight = null

        val ids = candidates.mapTo(mutableSetOf()) { it.reportId }
        attempts.keys.retainAll(ids)
        if (at < maxOf(rateLimitedUntilMs, nextWriteAtMs)) return null
        // FIFO keeps an outage or backoff from creating a burst across the queue.
        val report = candidates.firstOrNull() ?: return null
        val expires = HermesIncidentRetryPolicy.expiresAt(report.occurredAtMillis)
        if (at >= expires || at < (attempts[report.reportId]?.notBeforeMs ?: Long.MIN_VALUE)) return null
        val ticket = Ticket(report.reportId)
        flight = Flight(ticket, proof, expires)
        return ticket
    }

    /** Releases a detached wire snapshot once, after rechecking the admission. */
    @Synchronized
    fun beginWrite(ticket: Ticket): ByteArray? {
        val active = matching(ticket) ?: return null
        if (active.attempt != 0) return null
        val report = liveReport(active) ?: return null
        val at = now()
        if (at >= active.expiresAtMs || at < maxOf(rateLimitedUntilMs, nextWriteAtMs)) {
            flight = null
            return null
        }
        val body = report.body()
        val last = attempts[ticket.reportId]?.count ?: 0
        active.attempt = if (last == Int.MAX_VALUE) last else last + 1
        nextWriteAtMs = if (at > Long.MAX_VALUE - MIN_REQUEST_INTERVAL_MS) {
            Long.MAX_VALUE
        } else {
            at + MIN_REQUEST_INTERVAL_MS
        }
        attempts[ticket.reportId] = Attempt(active.attempt, nextWriteAtMs)
        return body
    }

    @Synchronized
    fun canContinue(ticket: Ticket): Boolean {
        val active = matching(ticket) ?: return false
        return active.attempt != 0 && liveReport(active) != null
    }

    /** Ignores stale or duplicate callbacks; errors never expose body or storage details. */
    @Synchronized
    fun complete(ticket: Ticket, httpStatus: Int?, retryAfter: String? = null): Boolean {
        val active = matching(ticket) ?: return false
        if (active.attempt == 0) return false
        flight = null
        val proof = admitted() ?: return false
        if (proof != active.admission || !ownsConsent(proof)) return false
        val at = now()
        if (httpStatus == 429) {
            rateLimitedUntilMs = maxOf(
                rateLimitedUntilMs,
                HermesIncidentRetryPolicy.rateLimitUntil(retryAfter, active.attempt, at),
            )
        }
        return when (val decision = HermesIncidentRetryPolicy.decide(
            httpStatus, retryAfter, active.attempt, at, active.expiresAtMs,
        )) {
            HermesIncidentDisposition.Pause -> {
                pausedThroughAccessRevision = maxOf(pausedThroughAccessRevision, proof.accessRevision)
                true
            }
            HermesIncidentDisposition.Accepted, HermesIncidentDisposition.Drop -> {
                attempts.remove(ticket.reportId)
                try {
                    queue.removeHermesCandidate(storage, proof.consentEpoch, ticket.reportId)
                } catch (_: Exception) {
                    false
                }
            }
            is HermesIncidentDisposition.RetryAt -> {
                if (candidates(proof).none { it.reportId == ticket.reportId }) return false
                attempts[ticket.reportId] = Attempt(active.attempt, decision.atMs)
                true
            }
        }
    }

    /** Invalidate a mock ticket when consent, route, or authorization changes. */
    @Synchronized
    fun invalidate(): Boolean = (flight != null).also { flight = null }

    private fun matching(ticket: Ticket): Flight? = flight?.takeIf { it.ticket === ticket }

    private fun admitted(): HermesIncidentAdmission? = try {
        admission()?.takeIf {
            it.consentEpoch.isNotEmpty() &&
                it.accessRevision > pausedThroughAccessRevision && it.tunnelRevision > 0
        }
    } catch (_: Exception) {
        null
    }

    private fun ownsConsent(proof: HermesIncidentAdmission): Boolean = try {
        queue.state(storage)["epoch"] == proof.consentEpoch
    } catch (_: Exception) {
        false
    }

    private fun candidates(proof: HermesIncidentAdmission): List<HermesIncidentReport> = try {
        queue.hermesCandidates(storage, proof.consentEpoch)
    } catch (_: Exception) {
        emptyList()
    }

    private fun liveReport(active: Flight): HermesIncidentReport? {
        val proof = admitted()
        val report = if (proof != null && proof == active.admission && now() < active.expiresAtMs) {
            candidates(proof).firstOrNull { it.reportId == active.ticket.reportId }
        } else {
            null
        }
        if (report == null) flight = null
        return report
    }

    companion object {
        const val MIN_REQUEST_INTERVAL_MS = 30_000L
    }
}
