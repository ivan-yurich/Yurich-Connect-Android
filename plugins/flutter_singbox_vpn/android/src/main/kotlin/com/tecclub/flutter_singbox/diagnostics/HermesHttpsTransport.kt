package com.tecclub.flutter_singbox.diagnostics

import androidx.annotation.RequiresApi
import java.io.EOFException
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.net.ProtocolException
import java.nio.ByteBuffer
import javax.net.ssl.SNIHostName
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLEngine
import javax.net.ssl.SSLEngineResult
import javax.net.ssl.SSLException

internal class HermesWireRequest(
    val body: ByteArray,
    val bearer: String,
    val stillAllowed: () -> Boolean = { true },
) {
    companion object {
        const val MAX_BEARER_LENGTH = 512
        private val bearerPattern = Regex("[A-Za-z0-9._~+/-]+={0,8}")

        fun validBearer(value: String): Boolean =
            value.length in 1..MAX_BEARER_LENGTH && bearerPattern.matches(value)
    }
}

internal data class HermesWireResponse(val status: Int, val retryAfter: String?)

/**
 * One HTTPS exchange over a stream already connected and authenticated by the
 * VPN process. No socket creation, DNS resolution, proxy discovery, redirect,
 * connection pool, or retry exists here. The owner must bound the exchange and
 * close the underlying stream on invalidation, including during blocking I/O.
 */
@RequiresApi(24)
internal class HermesHttpsTransport(private val tlsContext: SSLContext = SSLContext.getDefault()) {
    /** [beforeWrite] releases secrets only after the authenticated TLS handshake. */
    fun post(
        host: String,
        input: InputStream,
        output: OutputStream,
        routeAllowed: () -> Boolean = { true },
        beforeWrite: () -> HermesWireRequest?,
    ): HermesWireResponse? {
        if (!routeAllowed()) return null
        require(host.length in 1..253 && host.split('.').all(hostLabel::matches)) { "Invalid HTTPS host" }
        val engine = tlsContext.createSSLEngine(host, 443).apply {
            useClientMode = true
            val allowed = enabledProtocols.filter(tlsProtocols::contains)
            if (allowed.isEmpty()) throw SSLException("No supported HTTPS protocol")
            enabledProtocols = allowed.toTypedArray()
            sslParameters = sslParameters.apply {
                endpointIdentificationAlgorithm = "HTTPS"
                // A numeric address is used only by the loopback test fixture.
                if (host.any { it in 'a'..'z' || it in 'A'..'Z' }) {
                    serverNames = listOf(SNIHostName(host))
                }
            }
        }
        val stream = TlsStream(engine, input, output)
        try {
            stream.handshake(routeAllowed)
            val request = beforeWrite() ?: return null
            if (!request.stillAllowed()) return null
            val wire = wireBytes(host, request)
            try {
                stream.write(wire, request.stillAllowed)
                return response(stream, request.stillAllowed).takeIf { request.stillAllowed() }
            } finally {
                wire.fill(0)
            }
        } catch (_: DeliveryRevoked) {
            return null
        } finally {
            stream.release()
        }
    }

    private fun wireBytes(host: String, request: HermesWireRequest): ByteArray {
        require(HermesWireRequest.validBearer(request.bearer)) { "Invalid bearer credential" }
        require(HermesIncidentContract.decode(request.body) != null) { "Invalid incident body" }
        val prefix = ("POST ${HermesIncidentContract.PATH} HTTP/1.1\r\n" +
            "Host: $host\r\nContent-Type: ${HermesIncidentContract.CONTENT_TYPE}\r\n" +
            "Content-Length: ${request.body.size}\r\nConnection: close\r\nAuthorization: Bearer ")
            .toByteArray(Charsets.US_ASCII)
        return ByteArray(prefix.size + request.bearer.length + 4 + request.body.size).apply {
            prefix.copyInto(this)
            var at = prefix.size
            request.bearer.forEach { this[at++] = it.code.toByte() }
            for (byte in CRLF_CRLF) this[at++] = byte
            request.body.copyInto(this, at)
        }
    }

    private fun response(stream: TlsStream, allowed: () -> Boolean): HermesWireResponse {
        var remaining = MAX_RESPONSE_HEADERS
        fun line(): String {
            val value = StringBuilder()
            while (remaining-- > 0) {
                val byte = stream.readByte(allowed)
                if (byte == '\r'.code) {
                    if (remaining-- <= 0 || stream.readByte(allowed) != '\n'.code) {
                        throw ProtocolException("Invalid HTTPS response framing")
                    }
                    return value.toString()
                }
                if (byte != '\t'.code && byte !in 32..126 || value.length >= MAX_HEADER_LINE) {
                    throw ProtocolException("Invalid HTTPS response header")
                }
                value.append(byte.toChar())
            }
            throw ProtocolException("HTTPS response headers too large")
        }

        // Some proxies add informational responses. They cannot trigger a
        // request or a protocol upgrade; only the final status reaches policy.
        repeat(MAX_INFORMATIONAL + 1) {
            val code = statusLine.matchEntire(line())?.groupValues?.get(1)?.toInt()
                ?: throw ProtocolException("Invalid HTTPS response status")
            var retryAfter: String? = null
            var duplicateRetryAfter = false
            while (true) {
                val header = line()
                if (header.isEmpty()) break
                val end = header.indexOf(':')
                if (end <= 0 || !headerName.matches(header.substring(0, end))) {
                    throw ProtocolException("Invalid HTTPS response header name")
                }
                if (code == 429 && header.substring(0, end).equals("retry-after", ignoreCase = true)) {
                    if (retryAfter != null) duplicateRetryAfter = true
                    else retryAfter = header.substring(end + 1).trim(' ', '\t')
                }
            }
            if (code >= 200) {
                // Duplicate Retry-After is ambiguous. Never use it to shorten
                // a server-requested throttle or accidentally send a burst.
                return HermesWireResponse(code, if (duplicateRetryAfter) MAX_RETRY_AFTER else retryAfter)
            }
            if (code == 101) throw ProtocolException("HTTPS protocol upgrade not allowed")
        }
        throw ProtocolException("Too many informational HTTPS responses")
    }

    private class DeliveryRevoked : IOException("Incident delivery no longer allowed")

    /** Bounded TLS record pump. Keep all bytes on the owner-provided streams. */
    private class TlsStream(
        private val engine: SSLEngine,
        private val input: InputStream,
        private val output: OutputStream,
    ) {
        private val networkIn = emptyBuffer()
        private val networkOut = ByteBuffer.allocate(MAX_TLS_BUFFER)
        private val plainIn = emptyBuffer()
        private val empty = ByteBuffer.allocate(0)
        private var inputBytes = 0
        private var outputBytes = 0

        fun handshake(allowed: () -> Boolean) {
            engine.beginHandshake()
            pumpHandshake(allowed)
            if (engine.session.protocol !in tlsProtocols || engine.session.peerCertificates.isEmpty() ||
                plainIn.hasRemaining()
            ) throw SSLException("HTTPS peer not verified")
        }

        fun write(data: ByteArray, allowed: () -> Boolean) {
            val source = ByteBuffer.wrap(data)
            repeat(MAX_TLS_STEPS) {
                if (!source.hasRemaining()) return
                pumpHandshake(allowed)
                val before = engine.handshakeStatus
                val result = wrap(source, allowed)
                requireProgress(result, before)
            }
            throw SSLException("HTTPS write exceeded TLS work limit")
        }

        fun readByte(allowed: () -> Boolean): Int {
            repeat(MAX_TLS_STEPS) {
                if (plainIn.hasRemaining()) return plainIn.get().toInt() and 0xff
                pumpHandshake(allowed)
                if (plainIn.hasRemaining()) return plainIn.get().toInt() and 0xff
                receive(engine.handshakeStatus, allowed)
            }
            throw SSLException("HTTPS read exceeded TLS work limit")
        }

        private fun pumpHandshake(allowed: () -> Boolean) {
            repeat(MAX_TLS_STEPS) {
                checkAllowed(allowed)
                val before = engine.handshakeStatus
                // Some Android runtimes do not expose NEED_UNWRAP_AGAIN as a
                // compiled enum constant. Comparing the name keeps both safe.
                when (before.name) {
                    "NOT_HANDSHAKING", "FINISHED" -> return
                    "NEED_TASK" -> (engine.delegatedTask ?: throw SSLException("TLS task unavailable")).run()
                    "NEED_WRAP" -> requireProgress(wrap(empty, allowed), before)
                    "NEED_UNWRAP", "NEED_UNWRAP_AGAIN" -> receive(before, allowed)
                    else -> throw SSLException("Unsupported TLS state")
                }
            }
            throw SSLException("HTTPS handshake exceeded TLS work limit")
        }

        private fun wrap(source: ByteBuffer, allowed: () -> Boolean): SSLEngineResult {
            checkAllowed(allowed)
            networkOut.clear()
            val result = engine.wrap(source, networkOut)
            if (result.status != SSLEngineResult.Status.OK) throw SSLException("TLS write failed")
            val produced = networkOut.position()
            if (produced > 0) {
                if (outputBytes + produced > MAX_TLS_WIRE_BYTES) throw SSLException("TLS output limit exceeded")
                outputBytes += produced
                checkAllowed(allowed)
                output.write(networkOut.array(), 0, produced)
                checkAllowed(allowed)
                output.flush()
            }
            return result
        }

        private fun receive(before: SSLEngineResult.HandshakeStatus, allowed: () -> Boolean) {
            checkAllowed(allowed)
            plainIn.compact()
            val result = engine.unwrap(networkIn, plainIn)
            plainIn.flip()
            when (result.status) {
                SSLEngineResult.Status.OK -> requireProgress(result, before)
                SSLEngineResult.Status.BUFFER_UNDERFLOW -> {
                    if (!plainIn.hasRemaining() && (before == result.handshakeStatus ||
                            result.handshakeStatus.name in setOf("NEED_UNWRAP", "NEED_UNWRAP_AGAIN"))) {
                        refill(allowed)
                    }
                }
                SSLEngineResult.Status.CLOSED -> {
                    if (!plainIn.hasRemaining()) throw EOFException("HTTPS peer closed before final headers")
                }
                else -> throw SSLException("TLS input buffer limit exceeded")
            }
        }

        private fun refill(allowed: () -> Boolean) {
            checkAllowed(allowed)
            networkIn.compact()
            val capacity = minOf(networkIn.remaining(), MAX_TLS_WIRE_BYTES - inputBytes)
            if (capacity <= 0) throw SSLException("TLS input limit exceeded")
            val offset = networkIn.position()
            val read = input.read(networkIn.array(), offset, capacity)
            if (read <= 0) throw EOFException("Incomplete TLS record")
            inputBytes += read
            networkIn.position(offset + read)
            networkIn.flip()
        }

        private fun requireProgress(result: SSLEngineResult, before: SSLEngineResult.HandshakeStatus) {
            if (result.bytesConsumed() == 0 && result.bytesProduced() == 0 &&
                result.handshakeStatus == before && engine.handshakeStatus == before
            ) throw SSLException("TLS exchange made no progress")
        }

        fun release() {
            // Never write on a revoked or no-longer-current socket, even to
            // emit close_notify. The owner closes the underlying stream.
            runCatching { engine.session.invalidate() }
            runCatching { engine.closeOutbound() }
            runCatching { engine.closeInbound() }
            plainIn.array().fill(0)
        }

        private fun checkAllowed(allowed: () -> Boolean) {
            if (!allowed()) throw DeliveryRevoked()
        }

        private fun emptyBuffer() = ByteBuffer.allocate(MAX_TLS_BUFFER).apply { limit(0) }
    }

    private companion object {
        const val MAX_TLS_BUFFER = 64 * 1024
        const val MAX_TLS_WIRE_BYTES = 512 * 1024
        const val MAX_TLS_STEPS = 256
        const val MAX_RESPONSE_HEADERS = 8 * 1024
        const val MAX_HEADER_LINE = 2048
        const val MAX_INFORMATIONAL = 4
        const val MAX_RETRY_AFTER = "9223372036854775807"
        val CRLF_CRLF = byteArrayOf(13, 10, 13, 10)
        val tlsProtocols = setOf("TLSv1.2", "TLSv1.3")
        val hostLabel = Regex("[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?")
        val statusLine = Regex("HTTP/1\\.[01] ([1-5][0-9]{2})(?: [\\t -~]*)?")
        val headerName = Regex("[!#${'$'}%&'*+.^_`|~0-9A-Za-z-]+")
    }
}
