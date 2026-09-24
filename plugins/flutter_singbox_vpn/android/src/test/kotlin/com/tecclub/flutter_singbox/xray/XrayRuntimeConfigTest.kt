package com.tecclub.flutter_singbox.xray

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

internal class XrayRuntimeConfigTest {
    @Test
    fun unwrapsXrayConfig() {
        val runtime = XrayRuntimeConfig.from(
            """
            {
              "_yurich": {"core": "xray", "schema": 1},
              "xray": {"inbounds": [], "outbounds": []}
            }
            """.trimIndent()
        )

        assertTrue(runtime.enabled)
        assertEquals("""{"inbounds":[],"outbounds":[]}""", runtime.configJson)
        assertTrue(runtime.androidDisallowedPackages.isEmpty())
    }

    @Test
    fun unwrapsAndroidDisallowedPackages() {
        val runtime = XrayRuntimeConfig.from(
            """
            {
              "_yurich": {
                "core": "xray",
                "schema": 1,
                "androidDisallowedPackages": [
                  " online.dnsai.ivanvpn ",
                  "ru.gosuslugi",
                  "",
                  "ru.gosuslugi",
                  "not-a-package",
                  123
                ]
              },
              "xray": {"inbounds": [], "outbounds": []}
            }
            """.trimIndent()
        )

        assertTrue(runtime.enabled)
        assertEquals(
            listOf("online.dnsai.ivanvpn", "ru.gosuslugi"),
            runtime.androidDisallowedPackages,
        )
    }

    @Test
    fun ignoresPlainSingBoxConfig() {
        val runtime = XrayRuntimeConfig.from(
            """{"inbounds": [], "outbounds": []}"""
        )

        assertFalse(runtime.enabled)
    }

    @Test
    fun detectsCompactHttpHealthProxy() {
        val config =
            """{"inbounds":[{"listen":"127.0.0.1","port":20808,"protocol":"http"}]}"""

        assertTrue(XrayRuntimeConfig.exposesHttpProxy(config, 20808))
    }

    @Test
    fun detectsFormattedHttpHealthProxy() {
        val config =
            """
            {
              "inbounds": [
                {"protocol": "http", "port": 20808}
              ]
            }
            """.trimIndent()

        assertTrue(XrayRuntimeConfig.exposesHttpProxy(config, 20808))
    }

    @Test
    fun rejectsNonHttpAndWrongPortHealthProxies() {
        val config =
            """{"inbounds":[{"port":20808,"protocol":"socks"},{"port":1080,"protocol":"http"}]}"""

        assertFalse(XrayRuntimeConfig.exposesHttpProxy(config, 20808))
    }

    @Test
    fun rejectsInvalidHealthProxyConfig() {
        assertFalse(XrayRuntimeConfig.exposesHttpProxy("not-json", 20808))
        assertFalse(XrayRuntimeConfig.exposesHttpProxy("{}", 20808))
        assertFalse(XrayRuntimeConfig.exposesHttpProxy("{\"inbounds\":[]}", 0))
    }
}
