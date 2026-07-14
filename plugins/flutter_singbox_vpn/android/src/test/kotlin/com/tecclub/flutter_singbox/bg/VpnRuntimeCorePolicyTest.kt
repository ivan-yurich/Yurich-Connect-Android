package com.tecclub.flutter_singbox.bg

import kotlin.test.Test
import kotlin.test.assertEquals

class VpnRuntimeCorePolicyTest {
    @Test
    fun `classifies wrapped Xray config`() {
        val config =
            """{"_yurich":{"core":"xray"},"xray":{"inbounds":[],"outbounds":[]}}"""

        assertEquals(VpnRuntimeCore.Xray, VpnRuntimeCorePolicy.classify(config))
    }

    @Test
    fun `classifies plain config as sing-box`() {
        assertEquals(
            VpnRuntimeCore.SingBox,
            VpnRuntimeCorePolicy.classify("""{"inbounds":[],"outbounds":[]}"""),
        )
    }
}
