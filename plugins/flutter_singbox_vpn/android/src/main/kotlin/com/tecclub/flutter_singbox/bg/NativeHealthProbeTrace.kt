package com.tecclub.flutter_singbox.bg

internal enum class NativeProbeStage(val code: String) {
    ProxyConnect("proxy_connect"), ProxyResponse("proxy_response"), Tls("tls"), Http("http"),
}

internal enum class NativeProbeFailure(val code: String) {
    None("none"), Timeout("timeout"), Tls("tls"), Io("io"), Other("other"),
    ProxyStatus("proxy_status"), HttpStatus("http_status"),
}

internal enum class NativeProbeEndpoint(val code: String) {
    Cloudflare("cloudflare"), Gstatic("gstatic"), Google("google");

    companion object {
        fun fromHost(host: String): NativeProbeEndpoint? = when (host) {
            "www.cloudflare.com" -> Cloudflare
            "connectivitycheck.gstatic.com" -> Gstatic
            "www.google.com" -> Google
            else -> null
        }
    }
}

internal class NativeHealthProbeTrace(
    private val endpoint: NativeProbeEndpoint,
    private val generation: Long,
    private val revision: Long,
    private val startedMs: Long,
    private val network: NativeNetworkSnapshot,
) {
    private var stage = NativeProbeStage.ProxyConnect
    private var stageStartedMs = startedMs
    private val durations = LongArray(NativeProbeStage.entries.size) { -1 }

    fun enter(next: NativeProbeStage, nowMs: Long) {
        durations[stage.ordinal] = duration(stageStartedMs, nowMs)
        stage = next
        stageStartedMs = nowMs
    }

    fun finish(nowMs: Long, success: Boolean, failure: NativeProbeFailure): String {
        durations[stage.ordinal] = duration(stageStartedMs, nowMs)
        return "SOAK_HEALTH v=1 endpoint=${endpoint.code} generation=$generation revision=$revision " +
            "started=$startedMs finished=$nowMs stage=${stage.code} ok=$success failure=${failure.code} " +
            "proxyConnectMs=${durations[0]} proxyResponseMs=${durations[1]} " +
            "tlsMs=${durations[2]} httpMs=${durations[3]} " +
            "activeNet=${network.activeFlags} trackedNet=${network.trackedFlags} sameNet=${network.sameNetwork}"
    }

    private fun duration(start: Long, end: Long) = if (start >= 0 && end >= start) end - start else -1
}
