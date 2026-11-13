package com.tecclub.flutter_singbox.config

import kotlinx.serialization.json.*

/** Applied in the VPN process, including cached/sticky/restore/reload starts.
 * Android lockdown owns the firewall; this policy removes in-core direct routes.
 * Raw/selector/multi-hop configurations outside this narrow contract fail closed.
 */
internal object RuntimeKillSwitchPolicy {
    data class Plan(val content: String, val strict: Boolean)

    fun prepare(content: String, lockdown: Boolean): Plan {
        if (!lockdown) return Plan(content, false)
        return try {
            val root = Json.parseToJsonElement(content).jsonObject
            val xray = (root["_yurich"] as? JsonObject)?.text("core") == "xray"
            Plan(if (xray) strictXray(root) else strictSingBox(root), true)
        } catch (_: Exception) {
            // Never include parser input (profiles or credentials) in an alert.
            error("Kill switch: unsupported runtime configuration; connection blocked")
        }
    }

    private fun strictSingBox(root: JsonObject): String {
        require(root.keys.all { it in setOf("log", "experimental", "dns", "inbounds", "outbounds", "route") })
        val originalInbounds = root.array("inbounds").map { it.jsonObject }
        require(originalInbounds.size == 2 && originalInbounds.count { it.text("type") == "tun" } == 1)
        require(originalInbounds.any { it.text("type") == "mixed" && it.text("listen") == "127.0.0.1" && it["listen_port"]?.jsonPrimitive?.intOrNull == 20808 })
        val outbounds = root.array("outbounds").map { it.jsonObject }
        val proxy = outbounds.single { it.text("tag") == "proxy" }
        require(outbounds.all { it === proxy || (it.text("tag") == "direct" && it.text("type") == "direct") })
        val protocol = proxy.text("type")
        require(protocol in setOf("vless", "naive", "http", "hysteria", "hysteria2"))
        require(proxy.text("detour").isBlank())
        val server = proxy.text("server")
        require(server.isNotBlank())
        val encrypted = (proxy["tls"] as? JsonObject)?.get("enabled")?.jsonPrimitive?.booleanOrNull == true
        require(encrypted)
        val safeProxy = JsonObject(proxy.toMutableMap().apply {
            put("domain_resolver", JsonPrimitive("local-dns"))
            remove("bind_interface")
            remove("inet4_bind_address")
            remove("inet6_bind_address")
            remove("routing_mark")
        })
        return buildJsonObject {
            put("log", obj("level" to "warn", "timestamp" to true))
            put("dns", singBoxDns(server))
            put("inbounds", buildJsonArray {
                add(buildJsonObject {
                    put("type", "tun"); put("tag", "tun-in")
                    put("address", strings("172.19.0.1/30", "fdfe:dcba:9876::1/126"))
                    put("mtu", 1380); put("auto_route", true); put("strict_route", true)
                    put("stack", "gvisor"); put("interface_name", "tun0")
                })
                add(buildJsonObject {
                    put("type", "mixed"); put("tag", "mixed-in")
                    put("listen", "127.0.0.1"); put("listen_port", 20808)
                })
            })
            put("outbounds", JsonArray(listOf(safeProxy)))
            put("route", buildJsonObject {
                put("auto_detect_interface", true)
                put("default_domain_resolver", "remote-dns-primary")
                put("final", "proxy")
                put("rules", buildJsonArray {
                    add(obj("action" to "sniff"))
                    add(buildJsonObject { put("port", 53); put("action", "hijack-dns") })
                    add(buildJsonObject { put("protocol", "dns"); put("action", "hijack-dns") })
                    add(buildJsonObject { put("port", 853); put("action", "reject") })
                    if (protocol in setOf("naive", "http")) {
                        add(obj("network" to "udp", "action" to "reject"))
                    }
                })
            })
        }.toString()
    }

    private fun singBoxDns(server: String): JsonObject = buildJsonObject {
        put("servers", buildJsonArray {
            add(obj("type" to "local", "tag" to "local-dns"))
            for ((tag, address, sni) in listOf(
                Triple("remote-dns-primary", "1.1.1.1", "cloudflare-dns.com"),
                Triple("remote-dns-secondary", "8.8.8.8", "dns.google"),
            )) add(buildJsonObject {
                put("type", "https"); put("tag", tag); put("server", address)
                put("server_port", 443); put("path", "/dns-query"); put("detour", "proxy")
                put("tls", obj("enabled" to true, "server_name" to sni))
            })
        })
        put("rules", buildJsonArray {
            // Only resolving the encrypted upstream itself may use system DNS.
            // User destination DNS has no local/direct fallback.
            add(buildJsonObject {
                put("domain", strings(server)); put("action", "route"); put("server", "local-dns")
            })
        })
        put("strategy", "ipv4_only"); put("cache_capacity", 8192)
        put("final", "remote-dns-primary")
    }

    private fun strictXray(root: JsonObject): String {
        require(root.keys == setOf("_yurich", "xray"))
        val meta = root["_yurich"]!!.jsonObject
        require(meta["schema"]?.jsonPrimitive?.intOrNull == 1)
        val config = root["xray"]!!.jsonObject
        require(config.keys.all { it in setOf("log", "dns", "inbounds", "outbounds", "routing") })
        val inbounds = config.array("inbounds").map { it.jsonObject }
        require(inbounds.size == 2 && inbounds.count { it.text("protocol") == "tun" } == 1)
        require(inbounds.any { it.text("protocol") == "http" && it.text("listen") == "127.0.0.1" && it["port"]?.jsonPrimitive?.intOrNull == 20808 })
        val outbounds = config.array("outbounds").map { it.jsonObject }
        val proxy = outbounds.single { it.text("tag") == "proxy" }
        require(proxy.text("protocol") == "vless")
        require(proxy.keys.all { it in setOf("tag", "protocol", "settings", "streamSettings", "mux") })
        require(outbounds.all { it === proxy || it.text("protocol") in setOf("dns", "freedom", "blackhole") })
        val stream = proxy["streamSettings"]!!.jsonObject
        require(stream.text("security") in setOf("tls", "reality"))
        val vnext = proxy["settings"]!!.jsonObject.array("vnext")
        require(vnext.size == 1)
        val server = vnext.single().jsonObject.text("address")
        require(server.isNotBlank())
        val strictConfig = buildJsonObject {
            put("log", obj("loglevel" to "warning"))
            put("dns", buildJsonObject {
                put("tag", "dns-generated"); put("queryStrategy", "UseIPv4")
                // Xray's fallback selects the default DNS clients, not a direct
                // network path. The transport upstream is bootstrapped on an
                // explicit physical Network before Xray starts; do not retain a
                // localhost client (which also adds implicit local-name rules).
                put("disableFallback", false); put("disableFallbackIfMatch", true)
                put("servers", buildJsonArray {
                    add(obj("address" to "https://1.1.1.1/dns-query", "queryStrategy" to "UseIPv4"))
                    add(obj("address" to "https://8.8.8.8/dns-query", "queryStrategy" to "UseIPv4"))
                })
            })
            put("inbounds", buildJsonArray {
                add(buildJsonObject {
                    put("tag", "tun-in"); put("protocol", "tun")
                    put("settings", buildJsonObject {
                        put("name", "yurich-xray0"); put("mtu", 1380)
                        put("gateway", strings("172.19.0.1/30", "fdfe:dcba:9876::1/126"))
                        put("dns", strings("1.1.1.1", "8.8.8.8")); put("userLevel", 0)
                    })
                })
                add(buildJsonObject {
                    put("tag", "health-http-in"); put("protocol", "http")
                    put("listen", "127.0.0.1"); put("port", 20808)
                })
            })
            put("outbounds", JsonArray(listOf(proxy, obj("tag" to "dns-out", "protocol" to "dns"))))
            put("routing", buildJsonObject {
                put("domainStrategy", "AsIs")
                put("rules", buildJsonArray {
                    add(buildJsonObject { put("type", "field"); put("protocol", strings("dns")); put("outboundTag", "dns-out") })
                    add(obj("type" to "field", "port" to "53", "outboundTag" to "dns-out"))
                    add(buildJsonObject { put("type", "field"); put("inboundTag", strings("dns-generated")); put("outboundTag", "proxy") })
                    add(obj("type" to "field", "network" to "tcp,udp", "outboundTag" to "proxy"))
                })
            })
        }
        return buildJsonObject {
            put("_yurich", JsonObject(meta - "androidDisallowedPackages"))
            put("xray", strictConfig)
        }.toString()
    }

    private fun JsonObject.text(key: String): String = (get(key) as? JsonPrimitive)?.contentOrNull.orEmpty()
    private fun JsonObject.array(key: String): JsonArray = get(key) as? JsonArray ?: error("Invalid runtime shape")
    private fun strings(vararg values: String) = JsonArray(values.map(::JsonPrimitive))
    private fun obj(vararg fields: Pair<String, Any>): JsonObject = buildJsonObject {
        for ((key, value) in fields) when (value) {
            is Boolean -> put(key, value)
            is String -> put(key, value)
        }
    }
}
