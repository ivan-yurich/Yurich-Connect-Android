package com.tecclub.flutter_singbox.diagnostics

internal object DiagnosticPolicy {
    const val MODE_STANDARD = "standard"
    const val MODE_PASSIVE_24H = "passive_24h"
    const val DURATION_MS = 7 * 24 * 60 * 60 * 1000L
    const val PASSIVE_SOAK_DURATION_MS = 24 * 60 * 60 * 1000L
    const val SAMPLE_INTERVAL_MS = 5 * 60 * 1000L
    const val MAX_EVENTS = 40_000

    fun expired(startWall: Long, startElapsed: Long, startBoot: Int,
                nowWall: Long, nowElapsed: Long, nowBoot: Int,
                durationMs: Long = DURATION_MS): Boolean {
        val duration = normalizedDuration(durationMs)
        // Wall-clock changes must not shorten a run on the same known boot.
        if (startBoot >= 0 && startBoot == nowBoot) {
            return nowElapsed >= startElapsed && nowElapsed - startElapsed >= duration
        }
        return nowWall >= startWall + duration
    }

    fun belongsToRun(startWall: Long, startElapsed: Long, startBoot: Int,
                     eventWall: Long, eventElapsed: Long, eventBoot: Int): Boolean {
        // elapsedRealtime is monotonic only within one known boot. It therefore
        // remains authoritative when the user or network changes wall time.
        if (startBoot >= 0 && startBoot == eventBoot) {
            return eventElapsed >= startElapsed
        }
        return eventWall >= startWall
    }

    fun supportedDuration(durationMs: Long): Boolean =
        durationMs == DURATION_MS || durationMs == PASSIVE_SOAK_DURATION_MS

    fun normalizedDuration(durationMs: Long): Long =
        if (supportedDuration(durationMs)) durationMs else DURATION_MS

    fun normalizedMode(mode: String): String =
        if (mode == MODE_PASSIVE_24H) mode else MODE_STANDARD

    fun sameMode(currentMode: String, requestedMode: String): Boolean =
        normalizedMode(currentMode) == requestedMode

    private val codes = setOf(
        "process", "session", "network", "quorum", "probe_failure", "restart",
        "alert", "sample", "exit", "flutter_error", "ui", "task_removed", "destroy",
        "recycle", "recovery_deferred", "counter", "resource_pressure",
    )
    private val numericFields = setOf(
        "pid", "generation", "desired", "tun", "activeNet", "trackedNet", "sameNet",
        "success", "total", "durationMs", "screen", "idle", "pssKb", "heapKb",
        "txBytes", "rxBytes", "battery", "tempTenthsC", "charging", "reason",
        "status", "exitAtMs", "rssKb", "droppedQueue", "line", "api", "instanceMs", "current", "revision",
        "attempt", "cooldownMs", "cpuMs", "threads", "fds", "thermal",
        "probeId", "completed", "deadlineExceeded", "uiGeneration", "nativeSessionBytes", "displayBytes",
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
        "cause" to setOf("readiness", "network_reset", "degraded_quorum", "resource_pressure", "user_action", "core_switch", "other"),
        "protocol" to setOf("naive", "hysteria", "hysteria2", "reality", "vless", "xhttp", "socks", "unknown"),
        "transport" to setOf("wifi", "cellular", "other", "none", "unknown", "multiple"),
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
