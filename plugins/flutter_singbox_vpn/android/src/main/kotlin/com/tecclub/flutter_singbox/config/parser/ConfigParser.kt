package com.tecclub.flutter_singbox.config.parser

import kotlinx.serialization.encodeToString
import kotlinx.serialization.ExperimentalSerializationApi
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import java.io.ByteArrayOutputStream
import java.net.URI
import java.nio.charset.StandardCharsets
import java.util.Locale
import java.util.UUID

enum class ProxyProtocol {
    VLESS,
    NAIVE,
    HYSTERIA2,
}

data class ProxyAuth(
    val username: String? = null,
    val password: String? = null,
    val uuid: String? = null,
)

data class RealityOptions(
    val publicKey: String,
    val shortId: String? = null,
)

data class TlsOptions(
    val enabled: Boolean = true,
    val serverName: String? = null,
    val alpn: List<String> = emptyList(),
    val insecure: Boolean = false,
    val fingerprint: String? = null,
    val reality: RealityOptions? = null,
)

data class TransportOptions(
    val type: String,
    val path: String? = null,
    val host: String? = null,
    val serviceName: String? = null,
    val mode: String? = null,
)

data class ProxyConfig(
    val protocol: ProxyProtocol,
    val host: String,
    val port: Int,
    val name: String,
    val auth: ProxyAuth,
    val tls: TlsOptions? = null,
    val transport: TransportOptions? = null,
    val query: Map<String, String> = emptyMap(),
) {
    fun toSingBoxJson(): String = ConfigParser.buildSingBoxConfig(this)
}

class ConfigParseException(message: String) : IllegalArgumentException(message)

@OptIn(ExperimentalSerializationApi::class)
object ConfigParser {
    private const val DEFAULT_TLS_PORT = 443
    private const val LOCAL_MIXED_PROXY_PORT = 20808
    private const val ANDROID_PACKAGE = "online.dnsai.ivanvpn"

    private val prettyJson = Json {
        prettyPrint = true
        explicitNulls = false
    }

    fun parse(input: String): ProxyConfig {
        val raw = input.trim()
        if (raw.isEmpty()) {
            throw ConfigParseException("Config link is empty.")
        }

        val uri = parseUri(raw)
        return when (uri.scheme?.lowercase(Locale.US)) {
            "vless" -> parseVless(uri)
            "naive+https", "naive" -> parseNaive(uri, raw)
            "https" -> parseNaive(uri, raw)
            "hy2", "hysteria2" -> parseHysteria2(uri)
            else -> throw ConfigParseException("Unsupported config scheme: ${uri.scheme ?: "none"}.")
        }
    }

    fun parseToSingBoxJson(input: String): String = parse(input).toSingBoxJson()

    fun buildSingBoxConfig(config: ProxyConfig): String {
        val outbound = outbound(config)
        val document = buildJsonObject {
            put("log", buildJsonObject {
                put("level", "warn")
                put("timestamp", true)
            })
            put("dns", dnsConfig(config.host))
            put("inbounds", buildJsonArray {
                add(buildJsonObject {
                    put("type", "tun")
                    put("tag", "tun-in")
                    put("address", arrayOf("172.19.0.1/30"))
                    put("mtu", 1380)
                    put("auto_route", true)
                    put("strict_route", true)
                    put("stack", "gvisor")
                    put("interface_name", "tun0")
                    put("exclude_package", arrayOf(ANDROID_PACKAGE))
                })
                add(buildJsonObject {
                    put("type", "mixed")
                    put("tag", "mixed-in")
                    put("listen", "127.0.0.1")
                    put("listen_port", LOCAL_MIXED_PROXY_PORT)
                })
            })
            put("outbounds", buildJsonArray {
                add(outbound)
                add(buildJsonObject {
                    put("type", "direct")
                    put("tag", "direct")
                })
            })
            put("route", buildJsonObject {
                put("rules", buildJsonArray {
                    add(buildJsonObject {
                        put("action", "sniff")
                    })
                    add(buildJsonObject {
                        put("type", "logical")
                        put("mode", "or")
                        put("rules", buildJsonArray {
                            add(buildJsonObject { put("protocol", "dns") })
                            add(buildJsonObject { put("port", 53) })
                        })
                        put("action", "hijack-dns")
                    })
                    add(rejectUnsafeUdp(config.protocol == ProxyProtocol.NAIVE))
                    add(buildJsonObject {
                        put("ip_is_private", true)
                        put("outbound", "direct")
                    })
                })
                put("default_domain_resolver", "local-dns")
                put("auto_detect_interface", true)
                put("final", "proxy")
            })
        }

        return prettyJson.encodeToString(JsonObject.serializer(), document)
    }

    private fun parseVless(uri: URI): ProxyConfig {
        val host = requireHost(uri, "VLESS")
        val uuid = percentDecode(uri.rawUserInfo.orEmpty())
        if (uuid.isEmpty()) {
            throw ConfigParseException("VLESS link requires UUID.")
        }
        runCatching { UUID.fromString(uuid) }
            .getOrElse { throw ConfigParseException("VLESS UUID is invalid.") }

        val query = queryParameters(uri)
        val security = query["security"]?.lowercase(Locale.US).orEmpty()
        val transportType = (query["type"] ?: query["transport"] ?: "tcp")
            .lowercase(Locale.US)
        val tls = when (security) {
            "reality" -> {
                val publicKey = query["pbk"] ?: query["publicKey"]
                if (publicKey.isNullOrBlank()) {
                    throw ConfigParseException("VLESS Reality link requires pbk/publicKey.")
                }
                TlsOptions(
                    serverName = query["sni"] ?: query["peer"] ?: query["host"] ?: host,
                    alpn = csv(query["alpn"]),
                    insecure = truthy(query["allowInsecure"]) || truthy(query["insecure"]),
                    fingerprint = query["fp"] ?: query["fingerprint"],
                    reality = RealityOptions(
                        publicKey = publicKey,
                        shortId = query["sid"]?.takeIf { it.isNotBlank() },
                    ),
                )
            }
            "tls" -> TlsOptions(
                serverName = query["sni"] ?: query["peer"] ?: query["host"] ?: host,
                alpn = csv(query["alpn"]),
                insecure = truthy(query["allowInsecure"]) || truthy(query["insecure"]),
                fingerprint = query["fp"] ?: query["fingerprint"],
            )
            else -> null
        }

        return ProxyConfig(
            protocol = ProxyProtocol.VLESS,
            host = host,
            port = portOrDefault(uri),
            name = displayName(uri, host),
            auth = ProxyAuth(uuid = uuid),
            tls = tls,
            transport = transportFromQuery(transportType, query),
            query = query,
        )
    }

    private fun parseNaive(uri: URI, original: String): ProxyConfig {
        val normalizedUri = if (original.startsWith("naive+", ignoreCase = true)) {
            parseUri(original.substringAfter("naive+"))
        } else {
            uri
        }
        val host = requireHost(normalizedUri, "NaiveProxy")
        val userInfo = percentDecode(normalizedUri.rawUserInfo.orEmpty())
        val username = userInfo.substringBefore(":", missingDelimiterValue = "")
            .takeIf { it.isNotEmpty() }
        val password = userInfo.substringAfter(":", missingDelimiterValue = "")
            .takeIf { it.isNotEmpty() }
        val query = queryParameters(normalizedUri)

        return ProxyConfig(
            protocol = ProxyProtocol.NAIVE,
            host = host,
            port = portOrDefault(normalizedUri),
            name = displayName(normalizedUri, host),
            auth = ProxyAuth(username = username, password = password),
            tls = TlsOptions(
                serverName = query["sni"] ?: host,
                insecure = truthy(query["allowInsecure"]) || truthy(query["insecure"]),
            ),
            query = query,
        )
    }

    private fun parseHysteria2(uri: URI): ProxyConfig {
        val host = requireHost(uri, "Hysteria2")
        val query = queryParameters(uri)
        val password = query["password"]
            ?: query["auth"]
            ?: query["auth_str"]
            ?: hysteriaAuthFromUserInfo(uri.rawUserInfo.orEmpty())
        if (password.isBlank()) {
            throw ConfigParseException("Hysteria2 link requires password.")
        }

        return ProxyConfig(
            protocol = ProxyProtocol.HYSTERIA2,
            host = host,
            port = portOrDefault(uri),
            name = displayName(uri, host),
            auth = ProxyAuth(password = password),
            tls = TlsOptions(
                serverName = query["sni"] ?: query["peer"] ?: query["host"] ?: host,
                alpn = csv(query["alpn"]),
                insecure = truthy(query["allowInsecure"]) || truthy(query["insecure"]),
            ),
            query = query,
        )
    }

    private fun outbound(config: ProxyConfig): JsonObject {
        val base = linkedMapOf<String, JsonElement>(
            "tag" to JsonPrimitive("proxy"),
            "server" to JsonPrimitive(config.host),
            "server_port" to JsonPrimitive(config.port),
            "connect_timeout" to JsonPrimitive("8s"),
            "tcp_keep_alive" to JsonPrimitive("3m"),
            "tcp_keep_alive_interval" to JsonPrimitive("30s"),
            "domain_resolver" to JsonPrimitive("local-dns"),
            "domain_strategy" to JsonPrimitive("ipv4_only"),
            "network_strategy" to JsonPrimitive("fallback"),
            "fallback_delay" to JsonPrimitive(if (config.protocol == ProxyProtocol.HYSTERIA2) "300ms" else "200ms"),
        )

        when (config.protocol) {
            ProxyProtocol.VLESS -> {
                base["type"] = JsonPrimitive("vless")
                base["uuid"] = JsonPrimitive(config.auth.uuid)
                base["packet_encoding"] = JsonPrimitive(
                    config.query["packetEncoding"]
                        ?: config.query["packet_encoding"]
                        ?: config.query["packet"]
                        ?: "xudp"
                )
                config.query["flow"]?.takeIf { it.isNotBlank() }?.let {
                    base["flow"] = JsonPrimitive(it)
                }
                config.tls?.let { base["tls"] = tlsObject(it) }
                config.transport?.let { base["transport"] = transportObject(it) }
            }

            ProxyProtocol.NAIVE -> {
                base["type"] = JsonPrimitive("naive")
                config.auth.username?.let { base["username"] = JsonPrimitive(it) }
                config.auth.password?.let { base["password"] = JsonPrimitive(it) }
                config.tls?.let { base["tls"] = tlsObject(it) }
                if (truthy(config.query["quic"])) {
                    base["quic"] = JsonPrimitive(true)
                }
                config.query["quic_congestion_control"]?.takeIf { it.isNotBlank() }?.let {
                    base["quic_congestion_control"] = JsonPrimitive(it)
                }
            }

            ProxyProtocol.HYSTERIA2 -> {
                base["type"] = JsonPrimitive("hysteria2")
                base["password"] = JsonPrimitive(config.auth.password)
                positiveInt(config.query, "upmbps", "up_mbps", "up")?.let {
                    base["up_mbps"] = JsonPrimitive(it)
                }
                positiveInt(config.query, "downmbps", "down_mbps", "down")?.let {
                    base["down_mbps"] = JsonPrimitive(it)
                }
                config.query["network"]?.takeIf { it.isNotBlank() }?.let {
                    base["network"] = JsonPrimitive(it)
                }
                val obfs = config.query["obfs"] ?: config.query["obfsType"] ?: config.query["obfs_type"]
                if (!obfs.isNullOrBlank()) {
                    val obfsPassword = config.query["obfs-password"]
                        ?: config.query["obfs_password"]
                        ?: config.query["obfsPassword"]
                    base["obfs"] = buildJsonObject {
                        put("type", obfs)
                        if (!obfsPassword.isNullOrBlank()) {
                            put("password", obfsPassword)
                        }
                    }
                }
                config.tls?.let { base["tls"] = tlsObject(it) }
            }
        }

        return JsonObject(base)
    }

    private fun tlsObject(tls: TlsOptions): JsonObject = buildJsonObject {
        put("enabled", tls.enabled)
        tls.serverName?.takeIf { it.isNotBlank() }?.let { put("server_name", it) }
        if (tls.alpn.isNotEmpty()) {
            put("alpn", arrayOf(tls.alpn))
        }
        if (tls.insecure) {
            put("insecure", true)
        }
        tls.fingerprint?.takeIf { it.isNotBlank() }?.let {
            put("utls", buildJsonObject {
                put("enabled", true)
                put("fingerprint", it)
            })
        }
        tls.reality?.let {
            put("reality", buildJsonObject {
                put("enabled", true)
                put("public_key", it.publicKey)
                it.shortId?.let { shortId -> put("short_id", shortId) }
            })
        }
    }

    private fun transportObject(transport: TransportOptions): JsonObject = buildJsonObject {
        put("type", transport.type)
        transport.path?.takeIf { it.isNotBlank() }?.let { put("path", it) }
        transport.host?.takeIf { it.isNotBlank() }?.let {
            put("headers", buildJsonObject { put("Host", it) })
        }
        transport.serviceName?.takeIf { it.isNotBlank() }?.let {
            put("service_name", it)
        }
        transport.mode?.takeIf { it.isNotBlank() }?.let {
            put("mode", it)
        }
    }

    private fun dnsConfig(proxyHost: String): JsonObject = buildJsonObject {
        put("servers", buildJsonArray {
            add(buildJsonObject {
                put("type", "local")
                put("tag", "local-dns")
            })
            add(buildJsonObject {
                put("type", "fakeip")
                put("tag", "fakeip")
                put("inet4_range", "198.18.0.0/15")
                put("inet6_range", "fc00::/18")
            })
        })
        put("rules", buildJsonArray {
            add(buildJsonObject {
                put("domain", arrayOf(proxyHost))
                put("action", "route")
                put("server", "local-dns")
            })
            add(buildJsonObject {
                put("inbound", arrayOf("tun-in"))
                put("query_type", arrayOf("A", "AAAA"))
                put("action", "route")
                put("server", "fakeip")
            })
        })
        put("strategy", "ipv4_only")
        put("cache_capacity", 8192)
        put("reverse_mapping", true)
        put("final", "local-dns")
    }

    private fun rejectUnsafeUdp(rejectAllUdp: Boolean): JsonObject = buildJsonObject {
        put("type", "logical")
        put("mode", "or")
        put("rules", buildJsonArray {
            add(buildJsonObject { put("port", 853) })
            add(buildJsonObject { put("protocol", "stun") })
            add(buildJsonObject { put("protocol", "icmp") })
            if (rejectAllUdp) {
                add(buildJsonObject {
                    put("network", "udp")
                    put("port", 443)
                })
                add(buildJsonObject { put("network", "udp") })
            }
        })
        put("action", "reject")
    }

    private fun parseUri(value: String): URI = runCatching { URI(value) }
        .getOrElse { throw ConfigParseException("Malformed config URI: ${it.message}") }

    private fun hysteriaAuthFromUserInfo(rawUserInfo: String): String {
        return percentDecode(rawUserInfo)
    }

    private fun requireHost(uri: URI, protocol: String): String =
        uri.host?.takeIf { it.isNotBlank() }
            ?: throw ConfigParseException("$protocol link requires host.")

    private fun portOrDefault(uri: URI): Int =
        if (uri.port > 0) uri.port else DEFAULT_TLS_PORT

    private fun displayName(uri: URI, fallback: String): String =
        percentDecode(uri.rawFragment.orEmpty()).trim().ifEmpty { fallback }

    private fun queryParameters(uri: URI): Map<String, String> {
        val query = uri.rawQuery ?: return emptyMap()
        return query.split("&")
            .asSequence()
            .filter { it.isNotBlank() }
            .map {
                val key = it.substringBefore("=", it)
                val value = it.substringAfter("=", "")
                percentDecode(key) to percentDecode(value)
            }
            .filter { (key, _) -> key.isNotBlank() }
            .toMap()
    }

    private fun transportFromQuery(type: String, query: Map<String, String>): TransportOptions? =
        when (type) {
            "", "tcp" -> null
            "ws" -> TransportOptions(
                type = "ws",
                path = query["path"],
                host = query["host"],
            )
            "grpc" -> TransportOptions(
                type = "grpc",
                serviceName = query["serviceName"] ?: query["service_name"],
            )
            "xhttp", "splithttp" -> TransportOptions(
                type = "xhttp",
                path = query["path"],
                host = query["host"],
                mode = query["mode"] ?: query["xhttpMode"],
            )
            "http", "h2" -> TransportOptions(
                type = "http",
                path = query["path"],
                host = query["host"],
            )
            "httpupgrade" -> TransportOptions(
                type = "httpupgrade",
                path = query["path"],
                host = query["host"],
            )
            "quic" -> TransportOptions(type = "quic")
            else -> throw ConfigParseException("Unsupported VLESS transport: $type.")
        }

    private fun percentDecode(value: String): String {
        if (!value.contains("%")) return value

        val bytes = ByteArrayOutputStream(value.length)
        var index = 0
        while (index < value.length) {
            val char = value[index]
            if (char == '%' && index + 2 < value.length) {
                val hex = value.substring(index + 1, index + 3).toIntOrNull(16)
                if (hex != null) {
                    bytes.write(hex)
                    index += 3
                    continue
                }
            }
            bytes.write(char.code)
            index += 1
        }
        return bytes.toByteArray().toString(StandardCharsets.UTF_8)
    }

    private fun csv(value: String?): List<String> =
        value.orEmpty()
            .split(",")
            .map { it.trim() }
            .filter { it.isNotEmpty() }

    private fun truthy(value: String?): Boolean =
        value?.lowercase(Locale.US) in setOf("1", "true", "yes", "on")

    private fun positiveInt(query: Map<String, String>, vararg keys: String): Int? =
        keys.firstNotNullOfOrNull { key ->
            query[key]?.toIntOrNull()?.takeIf { it > 0 }
        }

    private fun JsonObjectBuilderCompat.put(key: String, values: Array<String>) {
        put(key, buildJsonArray {
            values.forEach { add(JsonPrimitive(it)) }
        })
    }

    private fun JsonObjectBuilderCompat.put(key: String, values: Array<List<String>>) {
        put(key, buildJsonArray {
            values.flatMap { it }.forEach { add(JsonPrimitive(it)) }
        })
    }
}

private typealias JsonObjectBuilderCompat = kotlinx.serialization.json.JsonObjectBuilder
