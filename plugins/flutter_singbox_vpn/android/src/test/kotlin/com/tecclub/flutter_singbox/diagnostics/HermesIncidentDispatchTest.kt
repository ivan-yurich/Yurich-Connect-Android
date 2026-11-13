package com.tecclub.flutter_singbox.diagnostics

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.time.Instant
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class HermesIncidentDispatchTest {
    private class MemoryStorage : LocalIncidentStorage {
        private var contents: String? = null
        override fun read(): String? = contents
        override fun write(value: String) { contents = value }
    }

    private val start = Instant.parse("2026-11-12T10:31:00Z").toEpochMilli()
    private var at = start
    private var proof: HermesIncidentAdmission? = null
    private val queue = LocalConnectionIncidentQueue { at }
    private val storage = MemoryStorage()
    private val dispatch = HermesIncidentDispatch(queue, storage, { at }, { proof })

    private fun enable(accessRevision: Long = 1L): HermesIncidentAdmission {
        val epoch = queue.setEnabled(storage, true).getValue("epoch") as String
        return HermesIncidentAdmission(epoch, accessRevision, tunnelRevision = 1L)
    }

    private fun record(epoch: String) {
        queue.record(storage, epoch, "1.0.132-test.20261112.14", "xhttp", "cellular", "transport", "timeout")
    }

    private fun reportId(bytes: ByteArray): String =
        Json.parseToJsonElement(bytes.decodeToString()).jsonObject.getValue("report_id").jsonPrimitive.content

    @Test
    fun `synthetic terminal failure stays local without admission and mock ack removes one record`() {
        assertNull(dispatch.claim())
        val admitted = enable()
        record(admitted.consentEpoch)
        assertNull(dispatch.claim()) // no verified route proof
        proof = admitted.copy(tunnelRevision = 0L)
        assertNull(dispatch.claim())
        assertEquals(1, queue.state(storage)["queued"])

        proof = admitted
        val ticket = assertNotNull(dispatch.claim())
        assertNull(dispatch.claim())
        assertFalse(dispatch.complete(ticket, 204)) // no write was allowed yet
        assertEquals(ticket.reportId, reportId(assertNotNull(dispatch.beginWrite(ticket))))
        assertNull(dispatch.beginWrite(ticket))
        assertTrue(dispatch.canContinue(ticket))
        assertTrue(dispatch.complete(ticket, 204))
        assertFalse(dispatch.complete(ticket, 204))
        assertEquals(0, queue.state(storage)["queued"])
    }

    @Test
    fun `network changes invalidate old claim and callback without changing the UUID`() {
        val admitted = enable()
        proof = admitted
        record(admitted.consentEpoch)
        val onOldRoute = assertNotNull(dispatch.claim())
        proof = admitted.copy(tunnelRevision = 2L)
        assertNull(dispatch.beginWrite(onOldRoute))
        val onNewRoute = assertNotNull(dispatch.claim())
        assertEquals(onOldRoute.reportId, onNewRoute.reportId)
        assertFalse(dispatch.complete(onOldRoute, 204))
        assertNotNull(dispatch.beginWrite(onNewRoute))
        proof = null
        assertFalse(dispatch.canContinue(onNewRoute))
        assertFalse(dispatch.complete(onNewRoute, 204))
        assertEquals(1, queue.state(storage)["queued"])
    }

    @Test
    fun `consent revocation clears queued reports and invalidates in-flight work`() {
        val old = enable()
        proof = old
        record(old.consentEpoch)
        val ticket = assertNotNull(dispatch.claim())
        assertNotNull(dispatch.beginWrite(ticket))
        queue.setEnabled(storage, false)
        // Even if the mock transport has not observed revocation, the queue is authoritative.
        assertFalse(dispatch.complete(ticket, 204))
        assertNull(dispatch.claim())
        assertEquals(0, queue.state(storage)["queued"])

        val fresh = enable(accessRevision = 2L)
        assertNotEquals(old.consentEpoch, fresh.consentEpoch)
        record(fresh.consentEpoch)
        proof = fresh
        at += HermesIncidentDispatch.MIN_REQUEST_INTERVAL_MS
        val newTicket = assertNotNull(dispatch.claim())
        assertNotEquals(ticket.reportId, newTicket.reportId)
        assertTrue(dispatch.invalidate())
        assertNull(dispatch.beginWrite(newTicket))
        assertFalse(dispatch.complete(ticket, 204))
        assertEquals(1, queue.state(storage)["queued"])
    }

    @Test
    fun `transport failures back off FIFO and preserve payload across mock retries`() {
        val admitted = enable()
        proof = admitted
        record(admitted.consentEpoch)
        record(admitted.consentEpoch)
        val first = assertNotNull(dispatch.claim())
        val bytes = assertNotNull(dispatch.beginWrite(first))
        assertTrue(dispatch.complete(first, null))
        at += 29_999
        assertNull(dispatch.claim())
        at++
        val second = assertNotNull(dispatch.claim())
        assertTrue(bytes.contentEquals(assertNotNull(dispatch.beginWrite(second))))
        assertTrue(dispatch.complete(second, 503))
        at += 59_999
        assertNull(dispatch.claim())
        at++
        val third = assertNotNull(dispatch.claim())
        assertEquals(first.reportId, third.reportId)
        assertNotNull(dispatch.beginWrite(third))
        assertTrue(dispatch.complete(third, 409))
        assertEquals(1, queue.state(storage)["queued"])
        assertNull(dispatch.claim()) // pacing applies even when the next row is ready
    }

    @Test
    fun `access rejection pauses all reports until a newer explicit revision`() {
        val admitted = enable(accessRevision = 5L)
        proof = admitted
        record(admitted.consentEpoch)
        val ticket = assertNotNull(dispatch.claim())
        assertNotNull(dispatch.beginWrite(ticket))
        assertTrue(dispatch.complete(ticket, 401))
        at += HermesIncidentDispatch.MIN_REQUEST_INTERVAL_MS
        proof = admitted.copy(tunnelRevision = 8L)
        assertNull(dispatch.claim())
        proof = admitted.copy(accessRevision = 4L)
        assertNull(dispatch.claim())
        proof = admitted.copy(accessRevision = 6L)
        assertEquals(ticket.reportId, assertNotNull(dispatch.claim()).reportId)
    }

    @Test
    fun `429 throttles later reports even when first record expires before retry`() {
        val admitted = enable()
        proof = admitted
        record(admitted.consentEpoch)
        at += HermesIncidentRetryPolicy.MAX_TTL_MS - 60_000
        record(admitted.consentEpoch)
        val first = assertNotNull(dispatch.claim())
        assertNotNull(dispatch.beginWrite(first))
        assertTrue(dispatch.complete(first, 429, "120"))
        assertEquals(1, queue.state(storage)["queued"])
        at += 119_999
        assertNull(dispatch.claim())
        at++
        assertNotEquals(first.reportId, assertNotNull(dispatch.claim()).reportId)
    }
}
