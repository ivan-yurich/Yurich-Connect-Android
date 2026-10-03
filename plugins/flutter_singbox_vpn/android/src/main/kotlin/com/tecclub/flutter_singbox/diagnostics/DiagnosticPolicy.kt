package com.tecclub.flutter_singbox.diagnostics

internal object DiagnosticPolicy {
    const val DURATION_MS = 7 * 24 * 60 * 60 * 1000L
    const val SAMPLE_INTERVAL_MS = 5 * 60 * 1000L
    const val MAX_EVENTS = 40_000

    fun expired(startWall: Long, startElapsed: Long, startBoot: Int,
                nowWall: Long, nowElapsed: Long, nowBoot: Int): Boolean =
        nowWall >= startWall + DURATION_MS ||
            (startBoot == nowBoot && nowElapsed >= startElapsed &&
                nowElapsed - startElapsed >= DURATION_MS)

    private val codes = setOf(
        "process", "session", "network", "quorum", "probe_failure", "restart",
        "alert", "sample", "exit", "flutter_error", "ui", "task_removed", "destroy",
    )
    private val numericFields = setOf(
        "pid", "generation", "desired", "tun", "activeNet", "trackedNet", "sameNet",
        "success", "total", "durationMs", "screen", "idle", "pssKb", "heapKb",
        "txBytes", "rxBytes", "battery", "tempTenthsC", "charging", "reason",
        "status", "exitAtMs", "rssKb", "droppedQueue", "line", "api", "instanceMs", "current", "revision",
    )
    private val labelValues = mapOf(
        "phase" to setOf("Stopped", "Starting", "Connected", "Reconnecting", "Stopping", "Failed"),
        "core" to setOf("singbox", "xray", "unknown"),
        "endpoint" to setOf("cloudflare", "gstatic", "google", "unknown"),
        "failure" to setOf("timeout", "tls", "io", "other", "proxy_status", "http_status", "cancelled"),
        "source" to setOf("default_network", "screen_on", "user_present", "idle_mode", "other"),
        "role" to setOf("main", "vpn", "other"),
        "state" to setOf("resumed", "hidden"),
        "errorType" to setOf("framework", "uncaught", "event_stream"),
        "stage" to setOf("proxy_connect", "proxy_response", "tls", "http"),
        "cause" to setOf("readiness", "degraded_quorum", "user_action", "core_switch", "other"),
        "protocol" to setOf("naive", "hysteria", "hysteria2", "reality", "vless", "xhttp", "socks", "unknown"),
    )

    // Free-form exception messages, configs, URLs and profile names are never accepted.
    fun validate(code: String, numbers: Map<String, Long>, labels: Map<String, String>): Boolean =
        code in codes && numbers.size <= numericFields.size &&
            numbers.all { (key, value) -> key in numericFields && value >= -1L } &&
            labels.all { (key, value) -> value in labelValues[key].orEmpty() }

    fun role(processName: String, packageName: String): String = when (processName) {
        packageName -> "main"
        "$packageName:vpn" -> "vpn"
        else -> "other"
    }
}
