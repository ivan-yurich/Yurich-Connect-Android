package com.tecclub.flutter_singbox.xray

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

data class XrayRuntimeConfig(
    val enabled: Boolean,
    val configJson: String,
    val androidDisallowedPackages: List<String> = emptyList(),
) {
    companion object {
        private const val CORE = "xray"
        private const val MAX_ANDROID_DISALLOWED_PACKAGES = 512
        private val ANDROID_PACKAGE_NAME =
            Regex("""[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+""")

        fun from(content: String): XrayRuntimeConfig {
            if (content.isBlank()) {
                return XrayRuntimeConfig(enabled = false, configJson = content)
            }

            val root = runCatching {
                Json.parseToJsonElement(content).jsonObject
            }.getOrElse {
                return XrayRuntimeConfig(enabled = false, configJson = content)
            }

            val meta = root["_yurich"] as? JsonObject
            if (meta?.get("core")?.jsonPrimitive?.content != CORE) {
                return XrayRuntimeConfig(enabled = false, configJson = content)
            }

            val xray = root["xray"] as? JsonObject
                ?: error("Xray wrapper missing xray config object.")
            return XrayRuntimeConfig(
                enabled = true,
                configJson = xray.toString(),
                androidDisallowedPackages = androidDisallowedPackages(meta),
            )
        }

        fun isXray(content: String): Boolean = from(content).enabled

        fun exposesHttpProxy(configJson: String, port: Int): Boolean {
            if (configJson.isBlank() || port !in 1..65535) {
                return false
            }

            val root = runCatching {
                Json.parseToJsonElement(configJson).jsonObject
            }.getOrElse {
                return false
            }
            val inbounds = root["inbounds"] as? JsonArray ?: return false
            return inbounds.any { element ->
                val inbound = element as? JsonObject ?: return@any false
                inbound["protocol"]?.jsonPrimitive?.contentOrNull == "http" &&
                    inbound["port"]?.jsonPrimitive?.intOrNull == port
            }
        }

        private fun androidDisallowedPackages(meta: JsonObject): List<String> {
            val packages = meta["androidDisallowedPackages"] as? JsonArray
                ?: return emptyList()
            return packages
                .mapNotNull { element ->
                    (element as? JsonPrimitive)
                        ?.contentOrNull
                        ?.trim()
                        ?.takeIf { it.isNotEmpty() }
                        ?.takeIf { ANDROID_PACKAGE_NAME.matches(it) }
                }
                .distinct()
                .take(MAX_ANDROID_DISALLOWED_PACKAGES)
        }
    }
}
