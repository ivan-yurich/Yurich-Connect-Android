package com.tecclub.flutter_singbox.xray

import kotlinx.serialization.json.*

/** Only the generated single VLESS upstream is resolved. User destinations are not. */
internal class XrayBootstrapPlan private constructor(
    private val root: JsonObject,
    private val outboundIndex: Int,
    val hostname: String?,
) {
    fun withAddress(address: String): String {
        require(isNumeric(address)) { "Bootstrap answer must be numeric" }
        val host = hostname ?: return root.toString()
        val outbounds = root.getValue("outbounds").jsonArray.toMutableList()
        val proxy = outbounds[outboundIndex].jsonObject
        val settings = proxy.getValue("settings").jsonObject
        val peer = settings.getValue("vnext").jsonArray.single().jsonObject
        val stream = proxy.getValue("streamSettings").jsonObject.toMutableMap()
        val security = stream["security"]?.jsonPrimitive?.content
        val tlsKey = if (security == "reality") "realitySettings" else "tlsSettings"
        val tls = (stream[tlsKey] as? JsonObject)?.toMutableMap() ?: mutableMapOf()
        if ((tls["serverName"] as? JsonPrimitive)?.contentOrNull.isNullOrBlank()) tls["serverName"] = JsonPrimitive(host)
        stream[tlsKey] = JsonObject(tls)
        if ((stream["network"] as? JsonPrimitive)?.contentOrNull in setOf("xhttp", "splithttp")) {
            val transport = (stream["xhttpSettings"] as? JsonObject)?.toMutableMap() ?: mutableMapOf()
            if ((transport["host"] as? JsonPrimitive)?.contentOrNull.isNullOrBlank()) transport["host"] = JsonPrimitive(host)
            stream["xhttpSettings"] = JsonObject(transport)
        }
        outbounds[outboundIndex] = JsonObject(proxy.toMutableMap().apply {
            put("settings", JsonObject(settings.toMutableMap().apply {
                put("vnext", JsonArray(listOf(JsonObject(peer.toMutableMap().apply { put("address", JsonPrimitive(address)) }))))
            }))
            put("streamSettings", JsonObject(stream))
        })
        return JsonObject(root.toMutableMap().apply { put("outbounds", JsonArray(outbounds)) }).toString()
    }

    override fun toString() = "XrayBootstrapPlan(required=${hostname != null})"

    companion object {
        private fun isNumeric(value: String): Boolean {
            val v4 = value.split('.')
            if (v4.size == 4 && v4.all { it.isNotEmpty() && it.all(Char::isDigit) && it.toIntOrNull() in 0..255 }) return true
            if (':' !in value || !value.matches(Regex("[0-9a-fA-F:.]+"))) return false
            return runCatching { java.net.InetAddress.getByName(value); true }.getOrDefault(false)
        }

        fun parse(config: String): XrayBootstrapPlan {
            val root = Json.parseToJsonElement(config).jsonObject
            val outbounds = root.getValue("outbounds").jsonArray
            val indexes = outbounds.indices.filter { outbounds[it].jsonObject["tag"]?.jsonPrimitive?.content == "proxy" }
            require(indexes.size == 1) { "Single upstream required" }
            val index = indexes.single()
            val proxy = outbounds[index].jsonObject
            require(proxy["protocol"]?.jsonPrimitive?.content == "vless") { "Unsupported upstream" }
            val peers = proxy.getValue("settings").jsonObject.getValue("vnext").jsonArray
            require(peers.size == 1) { "Single upstream required" }
            val stream = proxy.getValue("streamSettings").jsonObject
            require(stream["security"]?.jsonPrimitive?.content in setOf("tls", "reality")) { "Encrypted upstream required" }
            val host = peers.single().jsonObject.getValue("address").jsonPrimitive.content
            require(host.isNotBlank()) { "Upstream missing" }
            return XrayBootstrapPlan(root, index, if (isNumeric(host)) null else host)
        }
    }
}
