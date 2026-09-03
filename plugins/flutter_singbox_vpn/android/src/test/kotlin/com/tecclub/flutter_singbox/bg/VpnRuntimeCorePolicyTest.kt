package com.tecclub.flutter_singbox.bg

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

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

    @Test
    fun `requires a clean process only when the runtime core changes`() {
        assertFalse(
            VpnRuntimeCorePolicy.requiresCleanProcess(null, VpnRuntimeCore.Xray),
        )
        assertFalse(
            VpnRuntimeCorePolicy.requiresCleanProcess(
                VpnRuntimeCore.SingBox,
                VpnRuntimeCore.SingBox,
            ),
        )
        assertFalse(
            VpnRuntimeCorePolicy.requiresCleanProcess(
                VpnRuntimeCore.Xray,
                VpnRuntimeCore.Xray,
            ),
        )
        assertTrue(
            VpnRuntimeCorePolicy.requiresCleanProcess(
                VpnRuntimeCore.SingBox,
                VpnRuntimeCore.Xray,
            ),
        )
        assertTrue(
            VpnRuntimeCorePolicy.requiresCleanProcess(
                VpnRuntimeCore.Xray,
                VpnRuntimeCore.SingBox,
            ),
        )
    }
}
