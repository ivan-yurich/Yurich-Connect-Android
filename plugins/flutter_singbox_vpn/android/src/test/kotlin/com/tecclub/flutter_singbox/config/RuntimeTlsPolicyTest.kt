package com.tecclub.flutter_singbox.config

import com.tecclub.flutter_singbox.config.parser.ConfigParseException
import com.tecclub.flutter_singbox.config.parser.ConfigParser
import java.net.URI
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNull

class RuntimeTlsPolicyTest {
    private val pin = "11".repeat(32)
    private val spki = "A".repeat(43) + "="

    private fun config(tls: String, type: String = "hysteria2"): String =
        """{"outbounds":[{"type":"$type","server":"edge.example.com","tls":$tls}]}"""

    @Test
    fun `unsupported certificate pins are rejected before caching or persistence`() {
        for (key in listOf("pinSHA256", "PIN-SHA256", "pin_sha256", "certificate_sha256")) {
            for (value in listOf("\"$pin\"", "\"\"", "[]", "null")) {
                assertEquals(RuntimeTlsPolicy.UNSUPPORTED_PIN,
                    RuntimeTlsPolicy.validationError(config("""{"enabled":true,"insecure":true,"$key":$value}""")))
            }
        }
    }

    @Test
    fun `unicode JSON keys are inspected after parsing`() {
        assertEquals(RuntimeTlsPolicy.UNSUPPORTED_PIN,
            RuntimeTlsPolicy.validationError(config("""{"enabled":true,"\u0070inSHA256":"$pin"}""")))
    }

    @Test
    fun `legacy unpinned insecure runtime requires source revalidation`() {
        val json = config("""{"enabled":true,"insecure":true}""")
        assertEquals(RuntimeTlsPolicy.LEGACY_REVALIDATION, RuntimeTlsPolicy.validationError(json, 0))
        assertNull(RuntimeTlsPolicy.validationError(json, RuntimeTlsPolicy.CURRENT_REVISION))
    }

    @Test
    fun `ordinary legacy WebPKI config remains restorable`() {
        assertNull(RuntimeTlsPolicy.validationError(config("""{"enabled":true,"server_name":"edge.example.com"}"""), 0))
    }

    @Test
    fun `wrapper cannot hide legacy Xray allowInsecure`() {
        val json = """{"_yurich":{"core":"xray"},"xray":{"outbounds":[{"protocol":"vless","streamSettings":{"tlsSettings":{"allowInsecure":true}}}]}}"""
        assertEquals(RuntimeTlsPolicy.LEGACY_REVALIDATION, RuntimeTlsPolicy.validationError(json, 0))
        assertNull(RuntimeTlsPolicy.validationError(json))
    }

    @Test
    fun `Xray pins cannot be silently accepted by a builder that drops them`() {
        val json = """{"xray":{"outbounds":[{"streamSettings":{"tlsSettings":{"allowInsecure":true,"pinnedPeerCertificateChainSha256":["$pin"]}}}]}}"""
        assertEquals(RuntimeTlsPolicy.UNSUPPORTED_PIN, RuntimeTlsPolicy.validationError(json))
    }

    @Test
    fun `supported Go TLS public key pins remain allowed`() {
        assertNull(RuntimeTlsPolicy.validationError(config("""{"enabled":true,"certificate_public_key_sha256":["$spki"]}""")))
    }

    @Test
    fun `legacy insecure runtime with intact supported SPKI remains restorable`() {
        for (value in listOf("\"$spki\"", "[\"$spki\"]")) {
            assertNull(RuntimeTlsPolicy.validationError(
                config("""{"enabled":true,"insecure":true,"certificate_public_key_sha256":$value}"""), 0))
        }
    }

    @Test
    fun `empty SPKI cannot exempt legacy insecure TLS from revalidation`() {
        for (value in listOf("null", "[]")) {
            assertEquals(RuntimeTlsPolicy.LEGACY_REVALIDATION, RuntimeTlsPolicy.validationError(
                config("""{"enabled":true,"insecure":true,"certificate_public_key_sha256":$value}"""), 0))
        }
    }

    @Test
    fun `one pinned outbound cannot exempt a different legacy insecure outbound`() {
        val json = """{"outbounds":[{"type":"hysteria2","tls":{"enabled":true,"insecure":true,"certificate_public_key_sha256":["$spki"]}},{"type":"vless","tls":{"enabled":true,"insecure":true}}]}"""
        assertEquals(RuntimeTlsPolicy.LEGACY_REVALIDATION, RuntimeTlsPolicy.validationError(json, 0))
    }

    @Test
    fun `Naive cannot silently ignore a Go TLS pin`() {
        assertEquals(RuntimeTlsPolicy.UNSUPPORTED_PIN,
            RuntimeTlsPolicy.validationError(config("""{"enabled":true,"certificate_public_key_sha256":["$spki"]}""", "naive")))
    }

    @Test
    fun `malformed public key pins are rejected`() {
        for (value in listOf("\"bad\"", "[123]", "[true]", "[\"\"]")) {
            assertEquals(RuntimeTlsPolicy.INVALID_PIN,
                RuntimeTlsPolicy.validationError(config("""{"certificate_public_key_sha256":$value}""")))
        }
    }

    @Test
    fun `display labels custom roots and Reality authentication are unaffected`() {
        val json = """{"name":"pinSHA256=$pin","outbounds":[{"type":"vless","tls":{"enabled":true,"certificate":["fixture CA"],"utls":{"fingerprint":"chrome"},"reality":{"enabled":true,"public_key":"test-key"}}}]}"""
        assertNull(RuntimeTlsPolicy.validationError(json, 0))
    }

    @Test
    fun `native URI parser rejects empty repeated and encoded pin parameters`() {
        for (query in listOf("pinSHA256=", "pinSHA256=&pinSHA256=$pin", "%70inSHA256=$pin", "%2570inSHA256=$pin", "PIN-SHA256=$pin")) {
            val uri = URI("hy2://synthetic-test-only@edge.example.com:443/?insecure=1&$query")
            assertEquals(RuntimeTlsPolicy.UNSUPPORTED_PIN, RuntimeTlsPolicy.queryError(uri))
            assertFailsWith<ConfigParseException> { ConfigParser.parseToSingBoxJson(uri.toString()) }
        }
    }

    @Test
    fun `direct ProxyConfig construction cannot hide a pin from serialization`() {
        val parsed = ConfigParser.parse("hy2://synthetic-test-only@edge.example.com:443/?insecure=1")
        assertFailsWith<ConfigParseException> { parsed.copy(query = parsed.query + ("pinSHA256" to pin)).toSingBoxJson() }
    }

    @Test
    fun `invalid runtime JSON errors never echo the original config`() {
        assertEquals("Invalid runtime configuration.", RuntimeTlsPolicy.validationError("not-json synthetic-test-only"))
    }
}
