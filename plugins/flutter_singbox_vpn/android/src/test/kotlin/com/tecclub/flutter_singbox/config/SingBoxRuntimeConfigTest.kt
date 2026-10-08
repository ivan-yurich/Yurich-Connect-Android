package com.tecclub.flutter_singbox.config

import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

internal class SingBoxRuntimeConfigTest {
    @Test
    fun detectsHysteria2ByOutboundType() {
        assertTrue(SingBoxRuntimeConfig.usesHysteria2(
            """{"outbounds":[{"type":"direct"},{"type":"hysteria2","tag":"proxy"}]}""",
        ))
    }

    @Test
    fun namesAndNestedStringsDoNotTriggerHysteria2Policy() {
        assertFalse(SingBoxRuntimeConfig.usesHysteria2(
            """{"outbounds":[{"type":"vless","tag":"hysteria2"}],"remark":"hysteria2"}""",
        ))
    }

    @Test
    fun malformedHysteria2ConfigDoesNotCrashClassifier() {
        for (config in listOf("not-json", "[]", "{}", """{"outbounds":{}}""")) {
            assertFalse(SingBoxRuntimeConfig.usesHysteria2(config))
        }
    }

    @Test
    fun unexpectedOutboundElementsAreIgnored() {
        assertFalse(SingBoxRuntimeConfig.usesHysteria2(
            """{"outbounds":[null,"hysteria2",{"type":{}},{"type":true}]}""",
        ))
    }

    @Test
    fun detectsConfiguredMixedProxyPort() {
        val config =
            """
            {
              "inbounds": [
                {"type": "tun", "tag": "tun-in"},
                {
                  "type": "mixed",
                  "listen": "127.0.0.1",
                  "listen_port": 20808
                }
              ]
            }
            """.trimIndent()

        assertTrue(SingBoxRuntimeConfig.exposesMixedProxy(config, 20808))
    }

    @Test
    fun rejectsMissingWrongAndMalformedMixedProxyConfigs() {
        assertFalse(
            SingBoxRuntimeConfig.exposesMixedProxy(
                """{"inbounds":[{"type":"mixed","listen_port":20809}]}""",
                20808,
            )
        )
        assertFalse(
            SingBoxRuntimeConfig.exposesMixedProxy(
                """{"inbounds":[{"type":"socks","listen_port":20808}]}""",
                20808,
            )
        )
        assertFalse(SingBoxRuntimeConfig.exposesMixedProxy("not-json", 20808))
    }

    @Test
    fun rejectsInaccessibleOrAuthenticatedHealthProxies() {
        assertFalse(SingBoxRuntimeConfig.exposesMixedProxy(
            """{"inbounds":[{"type":"mixed","listen":"192.168.1.2","listen_port":20808}]}""",
            20808,
        ))
        assertFalse(SingBoxRuntimeConfig.exposesMixedProxy(
            """{"inbounds":[{"type":"mixed","listen":"127.0.0.1","listen_port":20808,"users":[{"username":"u","password":"p"}]}]}""",
            20808,
        ))
    }
}
