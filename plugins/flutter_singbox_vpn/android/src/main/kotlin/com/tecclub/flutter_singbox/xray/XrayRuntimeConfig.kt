package com.tecclub.flutter_singbox.xray

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

data class XrayRuntimeConfig(
    val enabled: Boolean,
    val configJson: String,
) {
    companion object {
        private const val CORE = "xray"

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
            return XrayRuntimeConfig(enabled = true, configJson = xray.toString())
        }

        fun isXray(content: String): Boolean = from(content).enabled
    }
}
