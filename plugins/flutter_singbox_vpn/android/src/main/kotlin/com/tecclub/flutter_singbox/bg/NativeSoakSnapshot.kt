package com.tecclub.flutter_singbox.bg

import com.tecclub.flutter_singbox.session.VpnSessionPhase

internal data class NativeSoakSnapshot(
    val pid: Int,
    val instanceElapsedMs: Long,
    val elapsedMs: Long,
    val generation: Long,
    val phase: VpnSessionPhase,
    val desiredRunning: Boolean,
    val runtime: VpnRuntimeCore?,
    val tunOpen: Boolean,
    val uidTxBytes: Long,
    val uidRxBytes: Long,
    val network: NativeNetworkSnapshot = NativeNetworkSnapshot(),
    val configFingerprint: String? = null,
) {
    fun encode(request: String, version: Int = 1): String {
        require(validRequest(request))
        require(version in 1..3)
        require(configFingerprint == null || NativeConfigBinding.isFingerprint(configFingerprint))
        val core = when (runtime) {
            VpnRuntimeCore.SingBox -> "singbox"
            VpnRuntimeCore.Xray -> "xray"
            null -> "unknown"
        }
        // Deliberately excludes profile labels, configs, destinations and errors.
        val base = "v=$version request=$request pid=$pid instance=$instanceElapsedMs " +
            "elapsed=$elapsedMs generation=$generation phase=${phase.name} " +
            "desired=$desiredRunning runtime=$core tun=$tunOpen " +
            "tx=$uidTxBytes rx=$uidRxBytes source=uid"
        if (version == 1) return base
        val withNetwork = base +
            " activeNet=${network.activeFlags} trackedNet=${network.trackedFlags} sameNet=${network.sameNetwork}"
        return if (version == 2) withNetwork else
            "$withNetwork config=${configFingerprint ?: "unknown"}"
    }

    companion object {
        private val requestPattern = Regex("[A-Za-z0-9_]{1,64}")
        fun validRequest(request: String?): Boolean =
            request != null && requestPattern.matches(request)
    }
}
