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
    ): Boolean = previous != null && previous != incoming
}
