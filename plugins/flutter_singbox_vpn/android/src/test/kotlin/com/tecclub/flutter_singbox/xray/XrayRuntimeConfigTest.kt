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
    }

    @Test
    fun ignoresPlainSingBoxConfig() {
        val runtime = XrayRuntimeConfig.from(
            """{"inbounds": [], "outbounds": []}"""
        )

        assertFalse(runtime.enabled)
    }
}
