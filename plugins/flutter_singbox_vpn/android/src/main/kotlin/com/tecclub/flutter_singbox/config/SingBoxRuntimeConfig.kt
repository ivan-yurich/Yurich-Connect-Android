package com.tecclub.flutter_singbox.config

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

internal object SingBoxRuntimeConfig {
    fun exposesMixedProxy(content: String, port: Int): Boolean {
        if (content.isBlank() || port !in 1..65535) {
            return false
        }

        val root = runCatching {
            Json.parseToJsonElement(content).jsonObject
        }.getOrElse {
            return false
        }
        val inbounds = root["inbounds"] as? JsonArray ?: return false
        return inbounds.any { element ->
            val inbound = element as? JsonObject ?: return@any false
            inbound["type"]?.jsonPrimitive?.contentOrNull == "mixed" &&
                inbound["listen_port"]?.jsonPrimitive?.intOrNull == port
        }
    }
}
