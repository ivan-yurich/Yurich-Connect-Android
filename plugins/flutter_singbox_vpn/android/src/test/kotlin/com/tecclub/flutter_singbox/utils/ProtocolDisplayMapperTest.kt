package com.tecclub.flutter_singbox.utils

import kotlin.test.Test
import kotlin.test.assertEquals

class ProtocolDisplayMapperTest {
    @Test
    fun distinguishesXhttpSecurityAndAliases() {
        for (transport in listOf("xhttp", "splithttp")) {
            for ((security, label) in listOf(
                "tls" to "TLS ",
                "reality" to "REALITY ",
                "" to ""
            )) {
                assertEquals(
                    "Xray ${label}XHTTP / Современный",
                    ProtocolDisplayMapper.mapProtocolToDisplayName("vless", transport, security)
                )
            }
        }
    }

    @Test
    fun mapsHysteriaAliasesToPublicName() {
        for (protocol in listOf("hysteria", "hysteria2", " HY2 ")) {
            assertEquals("ИИ", ProtocolDisplayMapper.mapProtocolToDisplayName(protocol))
        }
    }

    @Test
    fun mapsNaiveAliasesToPublicName() {
        for (protocol in listOf("naive", " NaiveProxy ")) {
            assertEquals("Веб", ProtocolDisplayMapper.mapProtocolToDisplayName(protocol))
        }
    }

    @Test
    fun preservesRealityAndUnknownProtocolLabels() {
        assertEquals(
            "Xray REALITY TCP / Стабильный",
            ProtocolDisplayMapper.mapProtocolToDisplayName("vless", "tcp", "reality")
        )
        assertEquals("custom", ProtocolDisplayMapper.mapProtocolToDisplayName("custom"))
    }
}
