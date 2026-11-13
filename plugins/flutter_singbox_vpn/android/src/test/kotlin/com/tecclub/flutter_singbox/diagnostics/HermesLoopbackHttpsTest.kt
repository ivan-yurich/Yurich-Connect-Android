package com.tecclub.flutter_singbox.diagnostics

import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.InputStream
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ProtocolException
import java.net.Proxy
import java.net.URL
import java.nio.file.Files
import java.nio.file.Path
import java.security.KeyStore
import java.util.UUID
import java.util.Locale
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import javax.net.ssl.HttpsURLConnection
import javax.net.ssl.KeyManagerFactory
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLHandshakeException
import javax.net.ssl.SSLServerSocket
import javax.net.ssl.SSLSocket
import javax.net.ssl.TrustManagerFactory
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertSame
import kotlin.test.assertTrue

/** JVM-only fixture. Not a production transport and not evidence of VPN routing. */
internal class HermesLoopbackHttpsFixture(
    certificateMatchesLoopback: Boolean = true,
    private val responseStatus: Int = 204,
    private val retryAfter: String? = null,
    private val responseGate: CountDownLatch? = null,
) : AutoCloseable {
    private val directory = Files.createTempDirectory(
        Files.createDirectories(Path.of("build", "hermes-loopback-tests")), "tls-",
    )
    private val executor = Executors.newCachedThreadPool()
    private var server: SSLServerSocket? = null
    private val sockets = ConcurrentHashMap.newKeySet<SSLSocket>()
    @Volatile private var closed = false
    private lateinit var clientTls: SSLContext
    val received = AtomicReference<ByteArray>()
    val requestCount = AtomicInteger()
    val redirectedRequestCount = AtomicInteger()
    val reachedRequest = CountDownLatch(1)
    val endpoint: URL get() = URL("https://127.0.0.1:${server!!.localPort}/v1/mobile/incidents")

    init {
        try {
            val storeFile = directory.resolve("fixture.p12")
            val password = UUID.randomUUID().toString()
            val executable = if (System.getProperty("os.name")?.startsWith("Windows") == true) {
                "keytool.exe"
            } else {
                "keytool"
            }
            val keytool = Path.of(System.getProperty("java.home"), "bin", executable)
            val process = ProcessBuilder(
                keytool.toString(), "-genkeypair", "-alias", "loopback", "-keyalg", "RSA",
                "-keysize", "2048", "-validity", "2", "-dname", "CN=localhost",
                "-ext", if (certificateMatchesLoopback) "SAN=ip:127.0.0.1" else "SAN=dns:localhost",
                "-storetype", "PKCS12",
                "-keystore", storeFile.toString(), "-storepass", password, "-noprompt",
            ).redirectErrorStream(true).redirectOutput(directory.resolve("keytool.log").toFile()).start()
            if (!process.waitFor(30, TimeUnit.SECONDS)) {
                process.destroyForcibly().waitFor(5, TimeUnit.SECONDS)
                error("Local test certificate generation timed out")
            }
            check(process.exitValue() == 0) { "Local test certificate generation failed" }
            val store = KeyStore.getInstance("PKCS12").apply {
                Files.newInputStream(storeFile).use { load(it, password.toCharArray()) }
            }
            val keys = KeyManagerFactory.getInstance(KeyManagerFactory.getDefaultAlgorithm()).apply {
                init(store, password.toCharArray())
            }
            val trust = KeyStore.getInstance(KeyStore.getDefaultType()).apply {
                load(null, null)
                setCertificateEntry("loopback", store.getCertificate("loopback"))
            }
            val managers = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm()).apply { init(trust) }
            clientTls = SSLContext.getInstance("TLS").apply { init(null, managers.trustManagers, null) }
            val serverTls = SSLContext.getInstance("TLS").apply { init(keys.keyManagers, null, null) }
            val listener = (serverTls.serverSocketFactory.createServerSocket() as SSLServerSocket).apply {
                bind(InetSocketAddress(InetAddress.getByName("127.0.0.1"), 0), 8)
            }
            server = listener
            executor.execute {
                while (!closed) {
                    val socket = try { listener.accept() as SSLSocket } catch (_: IOException) { break }
                    sockets.add(socket)
                    if (closed) {
                        socket.close()
                        sockets.remove(socket)
                        break
                    }
                    // One bounded request per connection; no keep-alive or chunked decoding.
                    try { executor.execute { serve(socket) } } catch (_: java.util.concurrent.RejectedExecutionException) {
                        socket.close()
                        sockets.remove(socket)
                    }
                }
            }
        } catch (failure: Throwable) {
            close()
            throw failure
        }
    }

    private fun serve(socket: SSLSocket) {
        try {
            socket.use {
                socket.soTimeout = 3000
                socket.startHandshake()
                val input = socket.inputStream
                val headerBytes = ByteArrayOutputStream()
                var tail = 0
                while (headerBytes.size() < 8192) {
                    val next = input.read()
                    if (next < 0) throw IOException("Incomplete mock request")
                    headerBytes.write(next)
                    tail = (tail shl 8) or next
                    if (tail == 0x0d0a0d0a) break
                }
                if (tail != 0x0d0a0d0a) throw IOException("Mock headers too large")
                val lines = headerBytes.toString("US-ASCII").removeSuffix("\r\n\r\n").split("\r\n")
                val request = lines.first().split(' ')
                if (request.size != 3 || request[2] != "HTTP/1.1") throw IOException("Invalid mock request line")
                val headers = mutableMapOf<String, String>()
                for (line in lines.drop(1)) {
                    val separator = line.indexOf(':')
                    if (separator <= 0) throw IOException("Invalid mock header")
                    val name = line.substring(0, separator).lowercase(Locale.ROOT)
                    if (headers.put(name, line.substring(separator + 1).trim()) != null) {
                        throw IOException("Duplicate mock header")
                    }
                }
                val length = headers["content-length"]?.toIntOrNull()
                if (length == null || length < 0 || "transfer-encoding" in headers) {
                    respond(socket, 400)
                    return
                }
                if (length > HermesIncidentContract.MAX_BODY_BYTES) {
                    respond(socket, 413)
                    return
                }
                val body = readBody(input, length)
                when (request[1]) {
                    "/v1/mobile/incidents" -> {
                        requestCount.incrementAndGet()
                        received.set(body)
                        reachedRequest.countDown()
                        if (responseGate?.await(3, TimeUnit.SECONDS) == false) return
                        respond(socket, when {
                            request[0] != "POST" -> 405
                            headers["content-type"] != HermesIncidentContract.CONTENT_TYPE -> 400
                            headers["authorization"] != FIXTURE_AUTH -> 401
                            HermesIncidentContract.decode(body) == null -> 400
                            else -> responseStatus
                        })
                    }
                    "/redirect" -> respond(socket, 307)
                    "/redirect-target" -> {
                        redirectedRequestCount.incrementAndGet()
                        respond(socket, 204)
                    }
                    else -> respond(socket, 404)
                }
            }
        } catch (_: IOException) {
            // Expected for negative TLS cases and connections cancelled by fixture shutdown.
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
        } finally { sockets.remove(socket) }
    }

    private fun readBody(input: InputStream, length: Int): ByteArray {
        val body = ByteArray(length)
        var offset = 0
        while (offset < length) {
            val count = input.read(body, offset, length - offset)
            if (count < 0) throw IOException("Incomplete mock body")
            offset += count
        }
        return body
    }

    private fun respond(socket: SSLSocket, status: Int) {
        val location = if (status == 307) "Location: /redirect-target\r\n" else ""
        val retry = if (status == 429 && retryAfter != null) "Retry-After: $retryAfter\r\n" else ""
        socket.outputStream.apply {
            write("HTTP/1.1 $status Mock\r\n$location${retry}Content-Length: 0\r\nConnection: close\r\n\r\n".toByteArray(Charsets.US_ASCII))
            flush()
        }
    }

    /** Only the fixture dials 127.0.0.1. The production exchange gets streams. */
    fun withTransport(
        trustFixture: Boolean = true,
        exchange: (HermesHttpsTransport, InputStream, java.io.OutputStream) -> HermesWireResponse?,
    ): HermesWireResponse? = transportSocket().use { socket ->
        val transport = if (trustFixture) HermesHttpsTransport(clientTls) else HermesHttpsTransport()
        exchange(transport, socket.inputStream, socket.outputStream)
    }

    fun transportSocket(): java.net.Socket = java.net.Socket().apply {
        soTimeout = 3000
        connect(InetSocketAddress(InetAddress.getByAddress(byteArrayOf(127, 0, 0, 1)), server!!.localPort), 3000)
    }

    fun trustedTransport() = HermesHttpsTransport(clientTls)

    /** Direct sockets are allowed here ONLY to our own loopback mock; never use in app code. */
    fun post(body: ByteArray, path: String = "/v1/mobile/incidents", trustFixture: Boolean = true): Int {
        require(path in setOf("/v1/mobile/incidents", "/redirect"))
        require(body.size <= 1024)
        val url = URL("https://127.0.0.1:${server!!.localPort}$path")
        val connection = url.openConnection(Proxy.NO_PROXY) as HttpsURLConnection
        try {
            if (trustFixture) connection.sslSocketFactory = clientTls.socketFactory
            // Do not replace HostnameVerifier or the global SSL defaults.
            connection.instanceFollowRedirects = false
            connection.connectTimeout = 3000
            connection.readTimeout = 3000
            connection.requestMethod = "POST"
            connection.doOutput = true
            connection.setRequestProperty("Content-Type", HermesIncidentContract.CONTENT_TYPE)
            connection.setRequestProperty("Authorization", FIXTURE_AUTH)
            connection.setFixedLengthStreamingMode(body.size)
            connection.outputStream.use { it.write(body) }
            val status = connection.responseCode
            if (status in 300..399) throw ProtocolException("Mock redirect rejected")
            return status
        } finally { connection.disconnect() }
    }

    override fun close() {
        closed = true
        server?.close()
        server = null
        sockets.forEach { runCatching { it.close() } }
        executor.shutdownNow()
        // Delete only this fixture's own generated temporary artifacts.
        Files.walk(directory).use { paths -> paths.sorted(Comparator.reverseOrder()).forEach { Files.deleteIfExists(it) } }
    }

    private companion object {
        const val FIXTURE_AUTH = "Bearer hermes-loopback-test-only"
    }
}

class HermesLoopbackHttpsTest {
    private val syntheticBody = requireNotNull(LocalConnectionIncidentQueue().hermesPreview("1.0.132-test.20261112.14"))
        .toByteArray(Charsets.UTF_8)

    @Test fun `isolated trust delivers synthetic payload without changing platform defaults`() {
        val factory = HttpsURLConnection.getDefaultSSLSocketFactory()
        val verifier = HttpsURLConnection.getDefaultHostnameVerifier()
        HermesLoopbackHttpsFixture().use { fixture ->
            assertEquals(204, fixture.post(syntheticBody))
            assertContentEquals(syntheticBody, fixture.received.get())
            assertEquals(1, fixture.requestCount.get())
        }
        assertSame(factory, HttpsURLConnection.getDefaultSSLSocketFactory())
        assertSame(verifier, HttpsURLConnection.getDefaultHostnameVerifier())
    }

    @Test fun `default trust rejects untrusted mock before HTTP delivery`() {
        HermesLoopbackHttpsFixture().use { fixture ->
            assertFailsWith<SSLHandshakeException> { fixture.post(syntheticBody, trustFixture = false) }
            assertEquals(0, fixture.requestCount.get())
        }
    }

    @Test fun `hostname mismatch is rejected despite trusting fixture certificate`() {
        HermesLoopbackHttpsFixture(certificateMatchesLoopback = false).use { fixture ->
            assertFailsWith<SSLHandshakeException> { fixture.post(syntheticBody) }
            assertEquals(0, fixture.requestCount.get())
        }
    }

    @Test fun `redirect is not followed and oversized payload never opens socket`() {
        HermesLoopbackHttpsFixture().use { fixture ->
            assertFailsWith<ProtocolException> { fixture.post(syntheticBody, path = "/redirect") }
            assertEquals(0, fixture.redirectedRequestCount.get())
            assertFailsWith<IllegalArgumentException> { fixture.post(ByteArray(1025)) }
            assertEquals(0, fixture.requestCount.get())
        }
    }

    @Test fun `queue to HTTPS needs admission and a 204 removes only the confirmed report`() {
        val now = 1_767_225_600_000L
        val queue = LocalConnectionIncidentQueue { now }
        val storage = object : LocalIncidentStorage {
            private var contents: String? = null
            override fun read() = contents
            override fun write(value: String) { contents = value }
        }
        val epoch = queue.setEnabled(storage, true)["epoch"] as String
        queue.record(storage, epoch, "1.0.132-test.20261112.14", "xhttp", "wifi", "vpn_start", "timeout")
        var admission: HermesIncidentAdmission? = null
        val dispatch = HermesIncidentDispatch(queue, storage, { now }, { admission })
        HermesLoopbackHttpsFixture().use { fixture ->
            assertNull(dispatch.claim())
            assertEquals(0, fixture.requestCount.get())
            admission = HermesIncidentAdmission(epoch, accessRevision = 1, tunnelRevision = 1)
            val ticket = assertNotNull(dispatch.claim())
            val body = assertNotNull(dispatch.beginWrite(ticket))
            assertEquals(ticket.reportId, HermesIncidentContract.decode(body)?.reportId)
            assertTrue(dispatch.canContinue(ticket))
            val status = fixture.post(body)
            assertEquals(204, status)
            assertTrue(dispatch.complete(ticket, status))
            assertContentEquals(body, fixture.received.get())
            assertEquals(0, queue.state(storage)["queued"])
        }
    }
}
