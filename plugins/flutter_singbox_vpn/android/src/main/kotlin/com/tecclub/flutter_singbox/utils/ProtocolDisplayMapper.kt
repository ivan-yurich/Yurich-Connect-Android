package com.tecclub.flutter_singbox.utils

object ProtocolDisplayMapper {
    fun mapProtocolToDisplayName(
        protocol: String?,
        transport: String? = null,
        security: String? = null
    ): String {
        val normalizedProtocol = protocol?.trim()?.lowercase().orEmpty()
        val normalizedTransport = transport?.trim()?.lowercase().orEmpty()
        val normalizedSecurity = security?.trim()?.lowercase().orEmpty()

        if (
            normalizedProtocol == "vless" &&
            normalizedSecurity == "reality" &&
            (normalizedTransport.isEmpty() || normalizedTransport == "tcp")
        ) {
            return "Reality"
        }
        if (
            normalizedProtocol == "vless" &&
            (normalizedTransport == "xhttp" || normalizedTransport == "splithttp")
        ) {
            val securityName = when (normalizedSecurity) {
                "reality" -> " (REALITY)"
                "tls" -> " (TLS)"
                else -> ""
            }
            return "XHTTP$securityName"
        }
        if (
            normalizedProtocol == "vless" &&
            normalizedSecurity == "reality" &&
            normalizedTransport == "grpc"
        ) {
            return "Reality (gRPC)"
        }
        if (normalizedProtocol == "naive" || normalizedProtocol == "naiveproxy") {
            return "NaiveProxy"
        }
        if (
            normalizedProtocol == "hysteria2" ||
            normalizedProtocol == "hy2"
        ) {
            return "Hysteria2"
        }
        if (normalizedProtocol == "hysteria") {
            return "Hysteria"
        }
        if (normalizedProtocol == "vless" && normalizedSecurity == "tls") {
            return if (normalizedTransport == "grpc") "VLESS TLS (gRPC)" else "VLESS TLS"
        }

        return protocol?.trim()?.takeIf { it.isNotEmpty() } ?: "Unknown protocol"
    }
}
