package com.tecclub.flutter_singbox.diagnostics

import java.io.IOException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import javax.net.ssl.SSLException
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class HermesHttpsTransportTest {
    @Test fun `denied route never reads or writes TLS bytes`() {
        val input = object : java.io.InputStream() {
            override fun read(): Int = error("Denied route must not read")
        }
        val output = java.io.ByteArrayOutputStream()
        assertNull(HermesHttpsTransport().post("127.0.0.1", input, output, routeAllowed = { false }) {
            error("Denied route must not release a report or bearer")
        })
        assertEquals(0, output.size())
    }

    private val synthetic = requireNotNull(
        LocalConnectionIncidentQueue().hermesPreview("1.0.132-test.20261112.21"),
    ).encodeToByteArray()

    @Test fun `real stream transport sends exact contract after TLS and only one request`() {
        HermesLoopbackHttpsFixture().use { fixture ->
            var grants = 0
            val response = fixture.withTransport { transport, input, output ->
                transport.post("127.0.0.1", input, output) {
                    grants++
                    HermesWireRequest(synthetic, FIXTURE_BEARER)
                }
            }
            assertEquals(HermesWireResponse(204, null), response)
            assertEquals(1, grants)
            assertEquals(1, fixture.requestCount.get())
            assertContentEquals(synthetic, fixture.received.get())
        }
    }

    @Test fun `TLS identity and trust are verified before obtaining the report or bearer`() {
        HermesLoopbackHttpsFixture(certificateMatchesLoopback = false).use { fixture ->
            assertFailsWith<SSLException> {
                fixture.withTransport { transport, input, output ->
                    transport.post("127.0.0.1", input, output) { error("Unauthenticated TLS released a report") }
                }
            }
            assertEquals(0, fixture.requestCount.get())
        }
        HermesLoopbackHttpsFixture().use { fixture ->
            assertFailsWith<SSLException> {
                fixture.withTransport(trustFixture = false) { transport, input, output ->
                    transport.post("127.0.0.1", input, output) { error("Untrusted TLS released a report") }
                }
            }
            assertEquals(0, fixture.requestCount.get())
        }
    }

    @Test fun `an expired or revoked lease never sends HTTP even after valid TLS`() {
        HermesLoopbackHttpsFixture().use { fixture ->
            val neverAdmitted = fixture.withTransport { transport, input, output ->
                transport.post("127.0.0.1", input, output) { null }
            }
            var checks = 0
            val revokedBeforeWrap = fixture.withTransport { transport, input, output ->
                transport.post("127.0.0.1", input, output) {
                    HermesWireRequest(synthetic, FIXTURE_BEARER) { ++checks < 3 }
                }
            }
            assertNull(neverAdmitted)
            assertNull(revokedBeforeWrap)
            assertEquals(3, checks)
            assertFalse(fixture.reachedRequest.await(120, TimeUnit.MILLISECONDS))
            assertEquals(0, fixture.requestCount.get())
        }
    }

    @Test fun `oversized body and header injection are rejected before HTTP`() {
        HermesLoopbackHttpsFixture().use { fixture ->
            val invalid = listOf(
                HermesWireRequest(ByteArray(1025), FIXTURE_BEARER),
                HermesWireRequest(synthetic, "fake\r\nX-Injected: value"),
            )
            for (request in invalid) assertFailsWith<IllegalArgumentException> {
                fixture.withTransport { transport, input, output ->
                    transport.post("127.0.0.1", input, output) { request }
                }
            }
            assertFalse(fixture.reachedRequest.await(120, TimeUnit.MILLISECONDS))
            assertEquals(0, fixture.requestCount.get())
        }
    }

    @Test fun `closing an in-flight stream aborts a pending response on revocation`() {
        val responseGate = CountDownLatch(1)
        val allowed = AtomicBoolean(true)
        val worker = Executors.newSingleThreadExecutor()
        try {
            HermesLoopbackHttpsFixture(responseGate = responseGate).use { fixture ->
                fixture.transportSocket().use { socket ->
                    val result = worker.submit<Boolean> {
                        try {
                            fixture.trustedTransport().post("127.0.0.1", socket.inputStream, socket.outputStream) {
                                HermesWireRequest(synthetic, FIXTURE_BEARER, allowed::get)
                            } == null
                        } catch (_: IOException) {
                            !allowed.get()
                        }
                    }
                    assertTrue(fixture.reachedRequest.await(2, TimeUnit.SECONDS))
                    assertFalse(result.isDone)
                    allowed.set(false)
                    socket.close()
                    // The server has not sent its reply. Closing the owner
                    // stream, not an HTTP deadline, must release the worker.
                    assertTrue(result.get(1, TimeUnit.SECONDS))
                    assertEquals(1, fixture.requestCount.get())
                    responseGate.countDown()
                }
            }
        } finally {
            responseGate.countDown()
            worker.shutdownNow()
        }
    }

    @Test fun `redirect is exposed only as status and Retry-After reaches retry policy`() {
        HermesLoopbackHttpsFixture(responseStatus = 307).use { fixture ->
            val response = fixture.withTransport { transport, input, output ->
                transport.post("127.0.0.1", input, output) { HermesWireRequest(synthetic, FIXTURE_BEARER) }
            }
            assertEquals(HermesWireResponse(307, null), response)
            assertEquals(1, fixture.requestCount.get())
            assertEquals(0, fixture.redirectedRequestCount.get())
        }
        HermesLoopbackHttpsFixture(responseStatus = 429, retryAfter = "120").use { fixture ->
            val response = assertNotNull(fixture.withTransport { transport, input, output ->
                transport.post("127.0.0.1", input, output) { HermesWireRequest(synthetic, FIXTURE_BEARER) }
            })
            val now = 1_767_225_600_000L
            val decision = HermesIncidentRetryPolicy.decide(response.status, response.retryAfter, 1, now, now + 300_000)
            assertEquals(HermesIncidentDisposition.RetryAt(now + 120_000), decision)
            assertEquals(1, fixture.requestCount.get())
        }
    }

    @Test fun `one synthetic report keeps its bytes and UUID across transport retry`() {
        var now = 1_767_225_600_000L
        val queue = LocalConnectionIncidentQueue { now }
        val storage = object : LocalIncidentStorage {
            private var contents: String? = null
            override fun read() = contents
            override fun write(value: String) { contents = value }
        }
        val epoch = queue.setEnabled(storage, true).getValue("epoch") as String
        queue.record(storage, epoch, "1.0.132-test.20261112.21", "xhttp", "wifi", "vpn_start", "timeout")
        val admission = HermesIncidentAdmission(epoch, accessRevision = 1, tunnelRevision = 1)
        val dispatch = HermesIncidentDispatch(queue, storage, { now }, { admission })
        fun attempt(fixture: HermesLoopbackHttpsFixture): String {
            val ticket = assertNotNull(dispatch.claim())
            val response = assertNotNull(fixture.withTransport { transport, input, output ->
                transport.post("127.0.0.1", input, output) {
                    dispatch.beginWrite(ticket)?.let { HermesWireRequest(it, FIXTURE_BEARER) { dispatch.canContinue(ticket) } }
                }
            })
            assertTrue(dispatch.complete(ticket, response.status, response.retryAfter))
            return ticket.reportId
        }
        HermesLoopbackHttpsFixture(responseStatus = 503).use { busy ->
            val reportId = attempt(busy)
            assertNull(dispatch.claim())
            now += 30_000
            HermesLoopbackHttpsFixture().use { available ->
                assertEquals(reportId, attempt(available))
                assertContentEquals(busy.received.get(), available.received.get())
                assertEquals(0, queue.state(storage)["queued"])
            }
        }
    }

    private companion object {
        const val FIXTURE_BEARER = "hermes-loopback-test-only"
    }
}
