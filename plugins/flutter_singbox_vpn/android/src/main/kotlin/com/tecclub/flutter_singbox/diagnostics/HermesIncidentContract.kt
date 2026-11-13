package com.tecclub.flutter_singbox.diagnostics

import com.tecclub.flutter_singbox.BuildConfig
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import java.text.ParsePosition
import java.text.SimpleDateFormat
import java.util.Locale
import java.util.TimeZone

/** The only shape accepted for a Hermes request body. Transport and consent live elsewhere. */
internal object HermesIncidentContract {
    val HOST: String get() = BuildConfig.HERMES_DELIVERY_HOST
    const val PATH = "/v1/mobile/incidents"
    const val CONTENT_TYPE = "application/json"
    const val MAX_BODY_BYTES = 1024

    /** Project a sanitized local event; never reinterpret names or connection details. */
    fun projectLocal(event: JsonObject): HermesIncidentReport? =
        HermesIncidentReport.validate(event, localProjection = true)

    /** Read back a body previously emitted by this client, not arbitrary peer JSON. */
    fun decode(body: ByteArray): HermesIncidentReport? {
        if (body.size !in 1..MAX_BODY_BYTES) return null
        val text = body.toString(Charsets.UTF_8)
        // Canonical payloads contain only ASCII scalar values. Avoid even parsing
        // nested or escaped input, and reject duplicate keys with the round-trip check.
        if (text.firstOrNull() != '{' || text.lastOrNull() != '}' ||
            text.count { it == '{' || it == '}' } != 2 ||
            text.any { it == '[' || it == ']' || it == '\\' || it.code !in 32..126 }
        ) return null
        val json = try {
            Json.parseToJsonElement(text) as? JsonObject ?: return null
        } catch (_: IllegalArgumentException) {
            return null
        }
        return HermesIncidentReport.validate(json, localProjection = false)
            ?.takeIf { it.body().contentEquals(body) }
    }
}

/** An immutable, validated payload. Retries use exactly the same bytes and report ID. */
internal class HermesIncidentReport private constructor(
    val reportId: String,
    val occurredAtMillis: Long,
    private val canonical: String,
) {
    fun body(): ByteArray = canonical.toByteArray(Charsets.UTF_8)

    companion object {
        private const val UNKNOWN = "unknown"
        private val keys = setOf(
            "schema_version", "report_id", "occurred_at", "app_version", "location", "ingress",
            "protocol", "network", "stage", "code",
        )
        private val uuidV4 = Regex("[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}")
        private val utcMinute = Regex("[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:00Z")
        private val appVersion = Regex(
            """(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)(?:-test\.([0-9]{8})\.(?:0|[1-9][0-9]*))?""",
        )
        private val locations = setOf("bucharest", "finland", "kazakhstan", "netherlands", "singapore", "warsaw", UNKNOWN)
        private val ingresses = setOf("moscow", "spb", "direct", UNKNOWN)
        private val protocols = setOf("naive", "hysteria2", "reality", "xhttp", UNKNOWN)
        private val networks = setOf("wifi", "cellular", "other", UNKNOWN)
        private val stages = setOf("network", "permission", "vpn_start", "dns", "transport", "tls", "auth", "traffic", UNKNOWN)
        private val codes = setOf(
            "no_network", "permission_denied", "start_failed", "stop_timeout", "timeout", "dns_failure",
            "tls_error", "auth_failed", "no_traffic", UNKNOWN,
        )

        internal fun validate(json: JsonObject, localProjection: Boolean): HermesIncidentReport? {
            if (json.keys != keys || json["schema_version"] != JsonPrimitive(1)) return null
            val id = json.string("report_id")?.takeIf(uuidV4::matches) ?: return null
            val occurred = json.string("occurred_at")?.takeIf(utcMinute::matches) ?: return null
            val at = parseUtc(occurred, "yyyy-MM-dd'T'HH:mm':00Z'") ?: return null
            val version = json.string("app_version")?.takeIf(::validVersion) ?: return null
            val location = json.string("location")?.takeIf(locations::contains) ?: return null
            val ingress = json.string("ingress")?.takeIf(ingresses::contains) ?: return null
            if (localProjection && (location != UNKNOWN || ingress != UNKNOWN)) return null
            val protocol = json.string("protocol")?.takeIf(protocols::contains) ?: return null
            val network = json.string("network")?.takeIf(networks::contains) ?: return null
            val stage = json.string("stage")?.takeIf(stages::contains) ?: return null
            val code = json.string("code")?.takeIf(codes::contains) ?: return null
            val canonical = buildJsonObject {
                put("schema_version", 1)
                put("report_id", id)
                put("occurred_at", occurred)
                put("app_version", version)
                put("location", location)
                put("ingress", ingress)
                put("protocol", protocol)
                put("network", network)
                put("stage", stage)
                put("code", code)
            }.toString()
            if (canonical.toByteArray(Charsets.UTF_8).size > HermesIncidentContract.MAX_BODY_BYTES) return null
            return HermesIncidentReport(id, at, canonical)
        }

        private fun validVersion(value: String): Boolean {
            if (value.length > HermesIncidentContract.MAX_BODY_BYTES) return false
            val match = appVersion.matchEntire(value) ?: return false
            val date = match.groups[1]?.value ?: return true
            return parseUtc(date, "yyyyMMdd") != null
        }

        private fun parseUtc(value: String, pattern: String): Long? {
            val format = SimpleDateFormat(pattern, Locale.ROOT).apply {
                timeZone = TimeZone.getTimeZone("UTC")
                isLenient = false
            }
            val position = ParsePosition(0)
            val parsed = format.parse(value, position) ?: return null
            return parsed.time.takeIf { position.index == value.length }
        }

        private fun JsonObject.string(key: String): String? =
            (this[key] as? JsonPrimitive)?.takeIf { it.isString }?.content
    }
}
