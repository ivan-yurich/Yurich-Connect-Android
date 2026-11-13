package com.tecclub.flutter_singbox.xray

internal enum class XrayDiagnosticKind {
    protect_ok, protect_failed, dns_resolution, tls_certificate, tls_handshake,
    connection_refused, connection_reset, network_unreachable, timeout,
    config_failure, authentication, other_warning,
}

/** Only a finite category leaves the reader, never its input. */
internal object XrayDiagnosticClassifier {
    private val vocabulary = setOf("failed", "find", "available", "destination", "retry", "attempts", "http", "http2", "http3", "request", "response", "status", "received", "upload", "download", "payload", "xhttp", "splithttp", "dns", "resolve", "lookup", "connection", "closed", "reset", "timeout", "canceled", "cancelled", "eof", "headers", "header", "stream", "protocol", "unexpected", "server", "invalid", "authentication", "certificate", "tls", "error", "handshake", "internal", "inbound", "outbound", "direct", "no", "route", "port", "write", "read", "pipe", "context", "key", "empty", "socket", "remote")
    fun signature(message: String): String = Regex("[A-Za-z]+")
        .findAll(message.lowercase()).map { it.value }.filter { it in vocabulary }
        .toList().takeLast(24).joinToString("_")

    fun classify(message: String): XrayDiagnosticKind {
        val text = message.lowercase()
        return when {
            "lookup " in text || "no such host" in text || "name resolution" in text -> XrayDiagnosticKind.dns_resolution
            "x509:" in text || "certificate" in text && ("verify" in text || "invalid" in text || "expired" in text || "unknown" in text) -> XrayDiagnosticKind.tls_certificate
            "handshake" in text -> XrayDiagnosticKind.tls_handshake
            "connection refused" in text -> XrayDiagnosticKind.connection_refused
            "connection reset" in text || "broken pipe" in text -> XrayDiagnosticKind.connection_reset
            "network is unreachable" in text || "no route to host" in text -> XrayDiagnosticKind.network_unreachable
            "timeout" in text || "timed out" in text || "deadline" in text -> XrayDiagnosticKind.timeout
            "unknown field" in text || "invalid config" in text || "failed to parse" in text -> XrayDiagnosticKind.config_failure
            "authentication" in text || "unauthorized" in text -> XrayDiagnosticKind.authentication
            else -> XrayDiagnosticKind.other_warning
        }
    }
}
