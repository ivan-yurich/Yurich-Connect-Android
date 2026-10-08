package com.tecclub.flutter_singbox.bg

import com.tecclub.flutter_singbox.xray.XrayRuntimeConfig

internal enum class VpnRuntimeCore {
    SingBox,
    Xray,
}

internal object VpnRuntimeCorePolicy {
    fun classify(config: String): VpnRuntimeCore {
        val isXray = runCatching { XrayRuntimeConfig.isXray(config) }
            .getOrDefault(false)
        return if (isXray) VpnRuntimeCore.Xray else VpnRuntimeCore.SingBox
    }

    fun requiresCleanProcess(
        previous: VpnRuntimeCore?,
        incoming: VpnRuntimeCore,
        previousUsedHysteria2: Boolean = false,
        incomingUsesHysteria2: Boolean = false,
    ): Boolean = previous != null && (
        previous != incoming || previousUsedHysteria2 ||
            (incoming == VpnRuntimeCore.SingBox && incomingUsesHysteria2)
        )
}
