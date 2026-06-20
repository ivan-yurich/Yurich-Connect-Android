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
            normalizedSecurity == "reality" &&
            (normalizedTransport == "xhttp" || normalizedTransport == "splithttp")
        ) {
            return "Xray REALITY XHTTP / Современный"
        }
        if (
            normalizedProtocol == "vless" &&
            normalizedSecurity == "reality" &&
            normalizedTransport == "grpc"
        ) {
            return "Xray REALITY gRPC / Резервный"
        }
        if (normalizedProtocol == "naive" || normalizedProtocol == "naiveproxy") {
            return "Yurich Proxy Naive / Быстрый"
        }
        if (
            normalizedProtocol == "hysteria2" ||
            normalizedProtocol == "hy2" ||
            normalizedProtocol == "hysteria"
        ) {
            return "Hysteria 2 / Турбо"
        }

        return protocol?.trim()?.takeIf { it.isNotEmpty() } ?: "Unknown protocol"
    }
}
