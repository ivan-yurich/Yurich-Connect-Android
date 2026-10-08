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
    fun `non QUIC configs require a clean process only when the runtime core changes`() {
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

    @Test
    fun `fresh hysteria2 process does not restart itself`() {
        assertFalse(VpnRuntimeCorePolicy.requiresCleanProcess(
            null, VpnRuntimeCore.SingBox, incomingUsesHysteria2 = true,
        ))
    }

    @Test
    fun `entering and leaving hysteria2 does not reuse native process state`() {
        assertTrue(VpnRuntimeCorePolicy.requiresCleanProcess(
            VpnRuntimeCore.SingBox, VpnRuntimeCore.SingBox, incomingUsesHysteria2 = true,
        ))
        assertTrue(VpnRuntimeCorePolicy.requiresCleanProcess(
            VpnRuntimeCore.SingBox, VpnRuntimeCore.SingBox, previousUsedHysteria2 = true,
        ))
        assertFalse(VpnRuntimeCorePolicy.requiresCleanProcess(
            VpnRuntimeCore.Xray, VpnRuntimeCore.Xray, incomingUsesHysteria2 = true,
        ))
    }
}
