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
            return "Xray REALITY TCP / Стабильный"
        }
        if (
            normalizedProtocol == "vless" &&
            (normalizedTransport == "xhttp" || normalizedTransport == "splithttp")
        ) {
            val securityName = when (normalizedSecurity) {
                "reality" -> "REALITY "
                "tls" -> "TLS "
                else -> ""
            }
            return "Xray ${securityName}XHTTP / Современный"
        }
        if (
            normalizedProtocol == "vless" &&
            normalizedSecurity == "reality" &&
            normalizedTransport == "grpc"
        ) {
            return "Xray REALITY gRPC / Резервный"
        }
        if (normalizedProtocol == "naive" || normalizedProtocol == "naiveproxy") {
            return "Веб"
        }
        if (
            normalizedProtocol == "hysteria2" ||
            normalizedProtocol == "hy2" ||
            normalizedProtocol == "hysteria"
        ) {
            return "ИИ"
        }

        return protocol?.trim()?.takeIf { it.isNotEmpty() } ?: "Unknown protocol"
    }
}
