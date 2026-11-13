package com.tecclub.flutter_singbox.xray

import com.tecclub.flutter_singbox.diagnostics.HermesIncidentContract
import kotlinx.serialization.json.*

/**
 * Structural proof for the final, bootstrapped managed XHTTP/TLS runtime only.
 * This is NOT source/ownership evidence: the caller must also attest the selected
 * managed fingerprint, disabled process-global browser dialer, core instance,
 * private filesystem socket + SO_PEERCRED, and current session/network lease.
 * No parsing error or unsupported shape may enable a fallback transport.
 */
internal class HermesXrayRoutePolicy(private val incidentHost: String) {
    private companion object {
        const val TAG = "yurich-incident-private-in"
        const val MAX_CONFIG_CHARS = 262_144
    }
    private val safeLog = buildJsonObject {
        put("loglevel", "warning"); put("access", "none")
        put("error", "none"); put("dnsLog", false)
    }

    /** Pre-bootstrap admission only; never grants permission to send or resolves DNS. */
    fun canBootstrap(runtimeJson: String): Boolean = runCatching {
        require(incidentHost.isNotEmpty())
        validateBase(parse(runtimeJson), patched = false, allowUpstreamHostname = true)
        true
    }.getOrDefault(false)

    fun prepare(runtimeJson: String, path: String): String? = runCatching {
        require(incidentHost.isNotEmpty())
        requirePath(path)
        val root = parse(runtimeJson)
        validateBase(root, patched = false)
        val routing = root.obj("routing")
        val result = JsonObject(root.toMutableMap().apply {
            put("log", safeLog)
            put("inbounds", JsonArray(root.array("inbounds") + inbound(path)))
            put("routing", JsonObject(routing.toMutableMap().apply {
                put("rules", JsonArray(listOf(rule()) + routing.array("rules")))
            }))
        }).toString()
        require(verifies(result, path))
        result
    }.getOrNull()

    fun verifies(runtimeJson: String, path: String): Boolean = runCatching {
        require(incidentHost.isNotEmpty())
        requirePath(path)
        val root = parse(runtimeJson)
        validateBase(root, patched = true)
        require(root["log"] == safeLog)
        require(root.array("inbounds").last() == inbound(path))
        require(root.obj("routing").array("rules").firstOrNull() == rule())
        true
    }.getOrDefault(false)

    private fun inbound(path: String) = buildJsonObject {
        put("tag", TAG); put("listen", path); put("protocol", "tunnel")
        put("settings", buildJsonObject {
            put("network", "tcp"); put("address", incidentHost)
            put("port", 443); put("followRedirect", false)
        })
    }

    private fun rule() = buildJsonObject {
        put("type", "field"); put("inboundTag", JsonArray(listOf(JsonPrimitive(TAG))))
        put("outboundTag", "proxy")
    }

    private fun validateBase(root: JsonObject, patched: Boolean, allowUpstreamHostname: Boolean = false) {
        root.only("log", "dns", "inbounds", "outbounds", "routing")
        val inbounds = root.array("inbounds").map { it.jsonObject }
        require(inbounds.size == if (patched) 3 else 2)
        require(inbounds.map { it.string("tag") }.toSet().size == inbounds.size)
        val tun = inbounds[0]
        tun.only("tag", "protocol", "settings", "sniffing")
        require(tun.string("tag") == "tun-in" && tun.string("protocol") == "tun")
        val health = inbounds[1]
        health.only("tag", "listen", "port", "protocol", "settings")
        require(health.string("tag") == "health-http-in")
        require(health.string("protocol") == "http" && health.string("listen") == "127.0.0.1")
        require(health.number("port") == 20808)
        if (!patched) require(inbounds.none { it.string("tag") == TAG })

        val outbounds = root.array("outbounds").map { it.jsonObject }
        require(outbounds.size in 2..4)
        require(outbounds.map { it.string("tag") }.toSet().size == outbounds.size)
        require(outbounds.first().string("tag") == "proxy")
        val proxy = outbounds.single { it.string("tag") == "proxy" }
        proxy.only("tag", "protocol", "settings", "streamSettings", "targetStrategy")
        require(proxy.string("protocol") == "vless")
        require(proxy.optionalString("targetStrategy") in setOf(null, "AsIs"))
        outbounds.filter { it !== proxy }.forEach {
            it.only("tag", "protocol", "settings")
            require((it.string("tag") to it.string("protocol")) in setOf(
                "direct" to "freedom", "dns-out" to "dns", "block" to "blackhole",
            ))
        }
        val settings = proxy.obj("settings")
        settings.only("vnext")
        val upstream = settings.array("vnext").single().jsonObject
        upstream.only("address", "port", "users")
        val address = upstream.string("address")
        if (allowUpstreamHostname && address.any { it !in "0123456789." }) {
            requireDnsUpstream(address)
        } else {
            requireNumericAddress(address)
        }
        require(upstream.number("port") in 1..65535)
        val user = upstream.array("users").single().jsonObject
        user.only("id", "encryption", "level", "flow")
        require(user.string("id").isNotBlank())
        require(user.string("encryption") == "none")
        require(user.optionalString("flow") in setOf(null, ""))
        if ("level" in user) require(user.number("level") == 0)

        val stream = proxy.obj("streamSettings")
        stream.only("network", "security", "tlsSettings", "xhttpSettings")
        require(stream.string("network") == "xhttp" && stream.string("security") == "tls")
        val tls = stream.obj("tlsSettings")
        // Reject all trust/verification overrides, custom certificates and pins:
        // do not remove or reinterpret security settings to make them acceptable.
        tls.only("serverName", "fingerprint", "alpn")
        requireHost(tls.string("serverName"))
        tls.optionalString("fingerprint")?.let { require(it.isNotBlank() && it.length <= 64) }
        if ("alpn" in tls) {
            val alpn = tls.array("alpn")
            require(alpn.isNotEmpty() && alpn.size <= 2)
            require(alpn.all { it is JsonPrimitive && it.isString && it.content in setOf("h2", "http/1.1") })
        }
        if ("xhttpSettings" in stream) {
            val xhttp = stream.obj("xhttpSettings")
            xhttp.only("host", "path", "mode")
            xhttp.optionalString("host")?.let(::requireHost)
            xhttp.optionalString("path")?.let {
                require(it.startsWith("/") && it.length <= 4096 && it.none { c -> c.code < 32 || c.code == 127 })
            }
            require(xhttp.optionalString("mode") in setOf(null, "auto", "packet-up", "stream-up", "stream-one"))
        }
        val routing = root.obj("routing")
        routing.only("domainStrategy", "rules")
        require(routing.optionalString("domainStrategy") in setOf(null, "AsIs", "IPIfNonMatch"))
        val rules = routing.array("rules")
        require(rules.isNotEmpty())
        rules.drop(if (patched) 1 else 0).forEach {
            val r = it.jsonObject
            // No balancers, webhooks, or mutable/dynamic routing controls.
            r.only("type", "protocol", "port", "inboundTag", "outboundTag", "domain", "ip", "network")
            require(r.string("type") == "field")
            require(r.string("outboundTag") in outbounds.map { o -> o.string("tag") })
            if ("inboundTag" in r) require(r.array("inboundTag").none { tag -> tag.jsonPrimitive.content == TAG })
        }
    }

    private fun requireHost(host: String) {
        require(host.isNotBlank() && host.length <= 253)
        require(host.all { it.isLetterOrDigit() && it.code < 128 || it in ".-" })
        require(!host.trimEnd('.').equals(incidentHost, ignoreCase = true))
    }

    private fun requireDnsUpstream(host: String) {
        requireHost(host)
        val canonical = host.trimEnd('.').lowercase()
        val labels = canonical.split('.')
        require(labels.size >= 2)
        require(labels.all { label ->
            label.length in 1..63 && label.first() != '-' && label.last() != '-' &&
                label.all { it in 'a'..'z' || it in '0'..'9' || it == '-' }
        })
        require(labels.last().any { it in 'a'..'z' })
        require(labels.last() !in setOf("localhost", "local", "internal", "invalid"))
    }

    private fun requireNumericAddress(address: String) {
        // IPv4 only in this pilot: never call InetAddress / trigger resolution.
        val parts = address.split('.')
        require(parts.size == 4 && parts.all {
            it.isNotEmpty() && it.length <= 3 && it.all { c -> c in '0'..'9' } &&
                (it.length == 1 || it[0] != '0') && it.toInt() in 0..255
        })
        require(parts[0].toInt() !in setOf(0, 127) && parts[0].toInt() < 224)
    }

    private fun requirePath(path: String) {
        // Caller additionally attests this lies in its own private files directory.
        require(path.startsWith("/data/") && path.toByteArray(Charsets.UTF_8).size <= 100)
        require(!path.endsWith('/') && path.all { it in 'a'..'z' || it in 'A'..'Z' || it in '0'..'9' || it in "/_.-" })
        require(path.split('/').none { it == "." || it == ".." })
        require(path.none { it.code < 33 || it.code == 127 || it == '\\' })
    }

    private fun parse(text: String): JsonObject {
        require(text.length in 2..MAX_CONFIG_CHARS)
        rejectDuplicateKeys(text)
        return Json.parseToJsonElement(text).jsonObject
    }

    private data class Frame(val objectKeys: MutableSet<String>?, var nextKey: Boolean = true)

    /** Reject duplicate keys including escaped spellings before JSON's last-wins parse. */
    private fun rejectDuplicateKeys(text: String) {
        val frames = mutableListOf<Frame>()
        val tokens = Regex("\"(?:\\\\.|[^\"\\\\])*\"|[{}\\[\\],]")
        for (match in tokens.findAll(text)) {
            val token = match.value
            when (token) {
                "{" -> frames.add(Frame(mutableSetOf()))
                "[" -> frames.add(Frame(null))
                "}", "]" -> { require(frames.isNotEmpty()); frames.removeAt(frames.lastIndex) }
                "," -> frames.lastOrNull()?.let { it.nextKey = true }
                else -> frames.lastOrNull()?.let {
                    if (it.objectKeys != null && it.nextKey) {
                        require(it.objectKeys.add(Json.parseToJsonElement(token).jsonPrimitive.content))
                        it.nextKey = false
                    }
                }
            }
            require(frames.size <= 64)
        }
        require(frames.isEmpty())
    }

    private fun JsonObject.only(vararg allowed: String) = require(keys.all { it in allowed })
    private fun JsonObject.obj(key: String) = getValue(key) as JsonObject
    private fun JsonObject.array(key: String) = getValue(key) as JsonArray
    private fun JsonObject.string(key: String): String = (getValue(key) as JsonPrimitive).let {
        require(it.isString); it.content
    }
    private fun JsonObject.optionalString(key: String): String? = if (key in this) string(key) else null
    private fun JsonObject.number(key: String): Int = (getValue(key) as JsonPrimitive).let {
        require(!it.isString); requireNotNull(it.intOrNull)
    }
}

internal val hermesXrayRoute = HermesXrayRoutePolicy(HermesIncidentContract.HOST)
