package com.tecclub.flutter_singbox.config

import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

internal class SingBoxRuntimeConfigTest {
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
}
