package com.tecclub.flutter_singbox.xray

import kotlin.test.*

class XrayDiagnosticClassifierTest {
    @Test fun unknownWarningSignatureUsesOnlyFinitePublicVocabulary() {
        val signature = XrayDiagnosticClassifier.signature("private-credential hidden.example 192.0.2.1 failed to read HTTP response: unexpected EOF")
        assertEquals("failed_read_http_response_unexpected_eof", signature)
    }
    @Test fun dnsErrorWinsOverNestedSocketRefusal() {
        assertEquals(XrayDiagnosticKind.dns_resolution, XrayDiagnosticClassifier.classify(
            "lookup private.example on 127.0.0.1:53: connection refused"))
    }
    @Test fun certificateFailureIsDistinctFromHandshakeTimeout() {
        assertEquals(XrayDiagnosticKind.tls_certificate, XrayDiagnosticClassifier.classify(
            "TLS handshake: x509: certificate expired for private.example"))
    }
    @Test fun reportsOnlyFiniteCategoriesNotInputValues() {
        for (text in listOf("private-credential", "dial private.example:443: timeout", "connection refused")) {
            val value = XrayDiagnosticClassifier.classify(text).name
            assertFalse(value.contains("private")); assertFalse(value.contains("443"))
        }
    }
    @Test fun configurationIsDistinctFromConnectivity() {
        assertEquals(XrayDiagnosticKind.config_failure, XrayDiagnosticClassifier.classify("unknown field sample"))
        assertEquals(XrayDiagnosticKind.connection_reset, XrayDiagnosticClassifier.classify("connection reset by peer"))
    }
}
