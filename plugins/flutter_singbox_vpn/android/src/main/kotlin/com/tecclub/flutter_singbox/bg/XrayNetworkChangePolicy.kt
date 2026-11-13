package com.tecclub.flutter_singbox.bg

import com.tecclub.flutter_singbox.session.VpnSessionPhase

/** Bundled libXray has no transport-pool reset API; rebind a ready session once. */
internal object XrayNetworkChangePolicy {
    fun shouldRebind(
        core: VpnRuntimeCore?,
        phase: VpnSessionPhase,
        reason: String,
        networkChanged: Boolean,
        networkAvailable: Boolean,
        desiredRunning: Boolean,
    ): Boolean = core == VpnRuntimeCore.Xray && networkChanged && networkAvailable &&
        desiredRunning && (phase == VpnSessionPhase.Connected ||
        phase == VpnSessionPhase.Reconnecting && reason.startsWith("readiness:"))
}
