package com.tecclub.flutter_singbox.config

import java.net.URI
import java.net.URLDecoder
import java.util.Locale
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull

/** Validate pins before a runtime is cached, persisted, or restored without Dart. */
internal object RuntimeTlsPolicy {
    const val CURRENT_REVISION = 1
    const val INTENT_REVISION_EXTRA = "yurich_tls_policy_revision"
    const val UNSUPPORTED_PIN = "Unsupported TLS certificate pin; connection refused without weakening verification."
    const val INVALID_PIN = "Invalid TLS public-key SHA-256 pin."
    const val LEGACY_REVALIDATION = "Saved insecure TLS runtime requires validation from the app profile."
    private val unsupportedKeys = setOf(
        "pinsha256", "certificatesha256", "pinnedpeercertificatechainsha256",
        "pinnedpeercertificatesha256", "peerfingerprint",
    )
    private val publicKeyHash = Regex("[A-Za-z0-9+/]{43}=")

    fun queryError(uri: URI): String? = uri.rawQuery?.split('&')?.firstNotNullOfOrNull { item ->
        val name = normalizeKey(item.substringBefore('='))
        if (name in unsupportedKeys || name == "certificatepublickeysha256") UNSUPPORTED_PIN else null
    }

    fun queryError(query: Map<String, String>): String? = query.keys.firstNotNullOfOrNull { name ->
        val key = normalizeKey(name)
        if (key in unsupportedKeys || key == "certificatepublickeysha256") UNSUPPORTED_PIN else null
    }

    fun validationError(content: String, sourceRevision: Int = CURRENT_REVISION): String? {
        val root = runCatching { Json.parseToJsonElement(content) as? JsonObject }.getOrNull()
            ?: return "Invalid runtime configuration."
        val pinError = inspect(root, depth = 0)
        if (pinError != null) return pinError
        if (sourceRevision < CURRENT_REVISION && hasInsecureTls(root, depth = 0)) {
            return LEGACY_REVALIDATION
        }
        return null
    }

    private fun normalizeKey(raw: String): String {
        var name = raw
        repeat(2) {
            name = runCatching { URLDecoder.decode(name, "UTF-8") }.getOrDefault(name)
        }
        return name.lowercase(Locale.ROOT).replace("_", "").replace("-", "")
    }

    private fun inspect(element: JsonElement, depth: Int): String? {
        if (depth > 6) return UNSUPPORTED_PIN
        when (element) {
            is JsonArray -> element.forEach { inspect(it, depth + 1)?.let { error -> return error } }
            is JsonObject -> {
                val tls = element["tls"] as? JsonObject
                val type = (element["type"] as? JsonPrimitive)?.contentOrNull
                val reality = tls?.get("reality") as? JsonObject
                val transport = element["transport"] as? JsonObject
                if (tls != null) {
                    val disallowPublicKeyPin = type == "naive" ||
                        (reality?.get("enabled") as? JsonPrimitive)?.booleanOrNull == true ||
                        (transport?.get("type") as? JsonPrimitive)?.contentOrNull == "xhttp"
                    tlsError(tls, disallowPublicKeyPin)?.let { return it }
                }
                val stream = element["streamSettings"] as? JsonObject
                for (key in listOf("tlsSettings", "realitySettings")) {
                    (stream?.get(key) as? JsonObject)?.let { settings ->
                        tlsError(settings, true)?.let { return it }
                    }
                }
                for (key in listOf("outbounds", "outbound", "xray")) {
                    element[key]?.let { inspect(it, depth + 1)?.let { error -> return error } }
                }
            }
            else -> Unit
        }
        return null
    }

    private fun tlsError(tls: JsonObject, disallowPublicKeyPin: Boolean): String? {
        for ((rawKey, value) in tls) {
            val key = normalizeKey(rawKey)
            if (key in unsupportedKeys) return UNSUPPORTED_PIN
            if (key != "certificatepublickeysha256") continue
            if (rawKey != "certificate_public_key_sha256") return UNSUPPORTED_PIN
            if (value is JsonNull || (value is JsonArray && value.isEmpty())) continue
            val values = when (value) {
                is JsonArray -> value.toList()
                is JsonPrimitive -> listOf(value)
                else -> return INVALID_PIN
            }
            if (values.isEmpty() || values.any { item ->
                val pin = item as? JsonPrimitive
                pin == null || !pin.isString || !publicKeyHash.matches(pin.content)
            }) return INVALID_PIN
            if (disallowPublicKeyPin) return UNSUPPORTED_PIN
        }
        return null
    }

    private fun hasInsecureTls(element: JsonElement, depth: Int): Boolean {
        if (depth > 6) return true
        return when (element) {
            is JsonArray -> element.any { hasInsecureTls(it, depth + 1) }
            is JsonObject -> {
                val tls = element["tls"] as? JsonObject
                val stream = element["streamSettings"] as? JsonObject
                val xrayTls = stream?.get("tlsSettings") as? JsonObject
                (truthy(tls?.get("insecure")) && !hasValidatedPublicKeyPin(tls)) ||
                    truthy(xrayTls?.get("allowInsecure")) ||
                    listOf("outbounds", "outbound", "xray").any { key ->
                        element[key]?.let { hasInsecureTls(it, depth + 1) } == true
                    }
            }
            else -> false
        }
    }

    // inspect() has already rejected invalid hashes and backends that cannot
    // enforce them. Go TLS verifies this intact pin even with insecure=true.
    private fun hasValidatedPublicKeyPin(tls: JsonObject?): Boolean =
        when (val pins = tls?.get("certificate_public_key_sha256")) {
            is JsonArray -> pins.isNotEmpty()
            is JsonPrimitive -> pins.isString && pins.content.isNotEmpty()
            else -> false
        }

    private fun truthy(value: JsonElement?): Boolean =
        (value as? JsonPrimitive)?.contentOrNull?.lowercase(Locale.ROOT) in setOf("1", "true", "yes", "on")
}
