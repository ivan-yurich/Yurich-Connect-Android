package com.tecclub.flutter_singbox.utils

import kotlin.test.Test
import kotlin.test.assertEquals

class ProtocolDisplayMapperTest {
    @Test
    fun distinguishesXhttpSecurityAndAliases() {
        for (transport in listOf("xhttp", "splithttp")) {
            for ((security, label) in listOf(
                "tls" to " (TLS)",
                "reality" to " (REALITY)",
                "" to ""
            )) {
                assertEquals(
                    "XHTTP$label",
                    ProtocolDisplayMapper.mapProtocolToDisplayName("vless", transport, security)
                )
            }
        }
    }

    @Test
    fun mapsHysteriaAliasesToPublicName() {
        for (protocol in listOf("hy2", "hysteria2", " HY2 ")) {
            assertEquals("Hysteria2", ProtocolDisplayMapper.mapProtocolToDisplayName(protocol))
        }
        assertEquals("Hysteria", ProtocolDisplayMapper.mapProtocolToDisplayName("hysteria"))
    }

    @Test
    fun mapsNaiveAliasesToPublicName() {
        for (protocol in listOf("naive", " NaiveProxy ")) {
            assertEquals("NaiveProxy", ProtocolDisplayMapper.mapProtocolToDisplayName(protocol))
        }
    }

    @Test
    fun preservesRealityAndUnknownProtocolLabels() {
        assertEquals(
            "Reality",
            ProtocolDisplayMapper.mapProtocolToDisplayName("vless", "tcp", "reality")
        )
        assertEquals("custom", ProtocolDisplayMapper.mapProtocolToDisplayName("custom"))
        assertEquals(
            "Reality (gRPC)",
            ProtocolDisplayMapper.mapProtocolToDisplayName(" VLESS ", " GRPC ", " REALITY ")
        )
        assertEquals(
            "VLESS TLS", ProtocolDisplayMapper.mapProtocolToDisplayName("vless", "tcp", "tls")
        )
    }
}
