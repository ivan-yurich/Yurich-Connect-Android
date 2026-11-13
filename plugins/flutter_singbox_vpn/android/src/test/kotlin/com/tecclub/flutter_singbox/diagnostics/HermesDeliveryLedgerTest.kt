package com.tecclub.flutter_singbox.diagnostics

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFails
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class HermesDeliveryLedgerTest {
    private val now = 1_767_225_600_000L
    private val epoch = "00000000-0000-4000-8000-000000000001"
    private val revision = "00000000-0000-4000-8000-000000000002"
    private val report = assertNotNull(HermesIncidentContract.decode(assertNotNull(
        LocalConnectionIncidentQueue().hermesPreview("1.0.132-test.20261113.22"),
    ).toByteArray()))
    private val expires = HermesIncidentRetryPolicy.expiresAt(report.occurredAtMillis)

    @Test fun `ordinary or empty journal has no consent`() {
        assertNull(HermesLedger.decode(null).grant)
        assertNull(HermesLedger.decode(HermesLedger().encode()).grant)
        assertFails { HermesLedger.decode("{}") }
        assertFails { HermesLedger.decode(HermesLedger().encode().replace("\"earliest\":0", "\"earliest\":\"0\"")) }
    }

    @Test fun `reservation is durable across process restart and preserves report identity`() {
        val first = assertNotNull(HermesPacing().reserve(report, now))
        assertEquals(report.reportId, first.reportId)
        val restored = HermesLedger.decode(HermesLedger(pacing = first).encode()).pacing
        assertNull(restored.reserve(report, now + 29_999))
        val retry = assertNotNull(restored.reserve(report, now + 30_000))
        assertEquals(2, retry.attempts)
        assertEquals(report.reportId, retry.reportId)
        assertNull(retry.reserve(report, now + 89_999))
        assertNull(retry.reserve(report, expires))
    }

    @Test fun `retry-after throttles the whole queue even when report is dropped`() {
        val attempt = assertNotNull(HermesPacing().reserve(report, expires - 60_000))
        val (pacing, decision) = attempt.complete(expires - 60_000, expires, 429, "120")
        assertEquals(HermesIncidentDisposition.Drop, decision)
        assertEquals(expires + 60_000, pacing.limitedUntil)
        assertNull(pacing.reportId)
        assertEquals(pacing, HermesLedger.decode(HermesLedger(pacing = pacing).encode()).pacing)
    }

    @Test fun `credential pause and revoke barrier round trip without a report body`() {
        val block = HermesGrant(epoch, revision, "A".repeat(40), blocked = true)
        val journal = HermesLedger(grant = block).encode()
        val saved = assertNotNull(HermesLedger.decode(journal).grant)
        assertEquals(revision, saved.revision)
        assertTrue(saved.blocked)
        assertFalse(journal.contains("occurred_at"))
        val revoked = HermesLedger(pendingClearEpoch = epoch)
        assertNull(HermesLedger.decode(revoked.encode()).grant)
        assertEquals(epoch, HermesLedger.decode(revoked.encode()).pendingClearEpoch)
        assertFails { HermesLedger.decode(HermesLedger(grant = block, pendingClearEpoch = epoch).encode()) }
    }

    @Test fun `remote revoke drops rows and old tickets without removing local opt in`() {
        val queue = LocalConnectionIncidentQueue { now }
        val storage = object : LocalIncidentStorage {
            private var data: String? = null
            override fun read() = data
            override fun write(value: String) { data = value }
        }
        val oldEpoch = queue.setEnabled(storage, true)["epoch"] as String
        queue.record(storage, oldEpoch, "1.0.132-test.20261113.22", "xhttp", "wifi", "vpn_start", "timeout")
        assertNotNull(queue.hermesHead(storage, oldEpoch))
        queue.clearForRemoteRevocation(storage, oldEpoch)
        val newEpoch = queue.state(storage)["epoch"] as String
        assertNotEquals(oldEpoch, newEpoch)
        assertNull(queue.hermesHead(storage, oldEpoch))
        assertEquals(0, queue.state(storage)["queued"])
        queue.record(storage, newEpoch, "1.0.132-test.20261113.22", "xhttp", "wifi", "vpn_start", "timeout")
        queue.clearForRemoteRevocation(storage, oldEpoch)
        assertEquals(1, queue.state(storage)["queued"])
    }
}
