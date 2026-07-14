package com.tecclub.flutter_singbox.config.parser

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.int
import kotlinx.serialization.json.boolean
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

internal class ConfigParserTest {
    @Test
    fun parsesVlessRealityLinkAndBuildsSingBoxJson() {
        val config = ConfigParser.parse(
            "vless://11111111-1111-4111-8111-111111111111@example.com:443" +
                "?security=reality&type=tcp&flow=xtls-rprx-vision" +
                "&sni=www.example.com&fp=chrome&pbk=abc123&sid=01#Reality"
        )

        assertEquals(ProxyProtocol.VLESS, config.protocol)
        assertEquals("example.com", config.host)
        assertEquals(443, config.port)
        assertEquals("Reality", config.name)
        assertEquals("11111111-1111-4111-8111-111111111111", config.auth.uuid)
        assertEquals("www.example.com", config.tls?.serverName)
        assertEquals("abc123", config.tls?.reality?.publicKey)
        assertEquals("01", config.tls?.reality?.shortId)
        assertNull(config.transport)

        val json = parseJson(config.toSingBoxJson())
        val proxy = json["outbounds"]!!.jsonArray.first().jsonObject
        assertEquals("vless", proxy["type"]!!.jsonPrimitive.content)
        assertEquals("example.com", proxy["server"]!!.jsonPrimitive.content)
        assertEquals("xtls-rprx-vision", proxy["flow"]!!.jsonPrimitive.content)
        assertEquals("xudp", proxy["packet_encoding"]!!.jsonPrimitive.content)
        assertEquals(
            "abc123",
            proxy["tls"]!!.jsonObject["reality"]!!.jsonObject["public_key"]!!.jsonPrimitive.content,
        )
    }

    @Test
    fun parsesVlessWebSocketTransport() {
        val config = ConfigParser.parse(
            "vless://11111111-1111-4111-8111-111111111111@example.com:8443" +
                "?security=tls&type=ws&sni=cdn.example.com&host=edge.example.com&path=%2Fws#WS"
        )

        assertEquals("ws", config.transport?.type)
        assertEquals("/ws", config.transport?.path)
        assertEquals("edge.example.com", config.transport?.host)

        val proxy = parseJson(config.toSingBoxJson())["outbounds"]!!.jsonArray.first().jsonObject
        val transport = proxy["transport"]!!.jsonObject
        assertEquals("ws", transport["type"]!!.jsonPrimitive.content)
        assertEquals("/ws", transport["path"]!!.jsonPrimitive.content)
        assertEquals(
            "edge.example.com",
            transport["headers"]!!.jsonObject["Host"]!!.jsonPrimitive.content,
        )
    }

    @Test
    fun parsesVlessGrpcTransport() {
        val config = ConfigParser.parse(
            "vless://11111111-1111-4111-8111-111111111111@example.com:443" +
                "?security=tls&type=grpc&sni=example.com&serviceName=vless-grpc#GRPC"
        )

        assertEquals("grpc", config.transport?.type)
        assertEquals("vless-grpc", config.transport?.serviceName)

        val proxy = parseJson(config.toSingBoxJson())["outbounds"]!!.jsonArray.first().jsonObject
        val transport = proxy["transport"]!!.jsonObject
        assertEquals("grpc", transport["type"]!!.jsonPrimitive.content)
        assertEquals("vless-grpc", transport["service_name"]!!.jsonPrimitive.content)
    }

    @Test
    fun parsesVlessXhttpTransport() {
        val config = ConfigParser.parse(
            "vless://11111111-1111-4111-8111-111111111111@example.com:443" +
                "?security=reality&type=xhttp&sni=www.example.com&host=cdn.example.com" +
                "&path=%2Fxhttp&mode=auto&pbk=abc123#XHTTP"
        )

        assertEquals("xhttp", config.transport?.type)
        assertEquals("/xhttp", config.transport?.path)
        assertEquals("cdn.example.com", config.transport?.host)
        assertEquals("auto", config.transport?.mode)

        val proxy = parseJson(config.toSingBoxJson())["outbounds"]!!.jsonArray.first().jsonObject
        val transport = proxy["transport"]!!.jsonObject
        assertEquals("xhttp", transport["type"]!!.jsonPrimitive.content)
        assertEquals("/xhttp", transport["path"]!!.jsonPrimitive.content)
        assertEquals("auto", transport["mode"]!!.jsonPrimitive.content)
        assertEquals(
            "cdn.example.com",
            transport["headers"]!!.jsonObject["Host"]!!.jsonPrimitive.content,
        )
    }

    @Test
    fun parsesNaiveProxyLinkAndBuildsSingBoxJson() {
        val config = ConfigParser.parse("naive+https://ivan:secret@example.com:443#Naive")

        assertEquals(ProxyProtocol.NAIVE, config.protocol)
        assertEquals("example.com", config.host)
        assertEquals(443, config.port)
        assertEquals("ivan", config.auth.username)
        assertEquals("secret", config.auth.password)
        assertEquals("Naive", config.name)

        val json = parseJson(config.toSingBoxJson())
        val proxy = json["outbounds"]!!.jsonArray.first().jsonObject
        assertEquals("naive", proxy["type"]!!.jsonPrimitive.content)
        assertEquals("ivan", proxy["username"]!!.jsonPrimitive.content)
        assertEquals("secret", proxy["password"]!!.jsonPrimitive.content)
        assertEquals(
            "example.com",
            proxy["tls"]!!.jsonObject["server_name"]!!.jsonPrimitive.content,
        )

        val rejectRule = json["route"]!!.jsonObject["rules"]!!.jsonArray
            .map { it.jsonObject }
            .first { it["action"]?.jsonPrimitive?.content == "reject" }
        assertTrue(
            rejectRule["rules"]!!.jsonArray
                .map { it.jsonObject }
                .any { it["network"]?.jsonPrimitive?.content == "udp" },
        )
    }

    @Test
    fun parsesHysteria2LinkAndBuildsSingBoxJson() {
        val config = ConfigParser.parse(
            "hy2://secret@example.com:8443?sni=cdn.example.com" +
                "&obfs=salamander&obfs-password=obfs-secret&upmbps=100&downmbps=200#Hy2"
        )

        assertEquals(ProxyProtocol.HYSTERIA2, config.protocol)
        assertEquals("example.com", config.host)
        assertEquals(8443, config.port)
        assertEquals("secret", config.auth.password)
        assertEquals("cdn.example.com", config.tls?.serverName)

        val json = parseJson(config.toSingBoxJson())
        val proxy = json["outbounds"]!!.jsonArray.first().jsonObject
        assertEquals("hysteria2", proxy["type"]!!.jsonPrimitive.content)
        assertEquals("secret", proxy["password"]!!.jsonPrimitive.content)
        assertEquals(100, proxy["up_mbps"]!!.jsonPrimitive.int)
        assertEquals(200, proxy["down_mbps"]!!.jsonPrimitive.int)
        assertEquals(
            "salamander",
            proxy["obfs"]!!.jsonObject["type"]!!.jsonPrimitive.content,
        )
        assertEquals(
            "obfs-secret",
            proxy["obfs"]!!.jsonObject["password"]!!.jsonPrimitive.content,
        )
    }

    @Test
    fun preservesCompleteHysteria2AuthWithEncodedColon() {
        val config = ConfigParser.parse(
            "hy2://client%3Asecret-for-test@example.com:8443" +
                "?sni=example.com&obfs=salamander&obfs-password=obfs-secret#Finland"
        )

        assertEquals(ProxyProtocol.HYSTERIA2, config.protocol)
        assertEquals("example.com", config.host)
        assertEquals(8443, config.port)
        assertEquals("client:secret-for-test", config.auth.password)

        val json = parseJson(config.toSingBoxJson())
        val proxy = json["outbounds"]!!.jsonArray.first().jsonObject
        assertEquals("hysteria2", proxy["type"]!!.jsonPrimitive.content)
        assertEquals(
            "client:secret-for-test",
            proxy["password"]!!.jsonPrimitive.content,
        )
    }

    @Test
    fun rejectsLinksWithoutRequiredFields() {
        assertFailsWith<ConfigParseException> {
            ConfigParser.parse("vless://11111111-1111-4111-8111-111111111111@:443")
        }
        assertFailsWith<ConfigParseException> {
            ConfigParser.parse("vless://11111111-1111-4111-8111-111111111111@example.com:443?security=reality")
        }
        assertFailsWith<ConfigParseException> {
            ConfigParser.parse("hy2://@example.com:443")
        }
        assertFailsWith<ConfigParseException> {
            ConfigParser.parse("socks5://user:pass@example.com:1080")
        }
    }

    @Test
    fun buildsRequiredTunAndDnsSections() {
        val config = ConfigParser.parse("naive+https://ivan:secret@example.com:443#Naive")
        val json = parseJson(config.toSingBoxJson())

        val tun = json["inbounds"]!!.jsonArray.first().jsonObject
        assertEquals("tun", tun["type"]!!.jsonPrimitive.content)
        assertEquals("gvisor", tun["stack"]!!.jsonPrimitive.content)
        assertTrue(tun["strict_route"]!!.jsonPrimitive.boolean)

        val dns = json["dns"]!!.jsonObject
        assertEquals("local-dns", dns["final"]!!.jsonPrimitive.content)
        assertEquals(8192, dns["cache_capacity"]!!.jsonPrimitive.int)
        assertNotNull(dns["rules"]!!.jsonArray.first().jsonObject["domain"])

        val cacheFile = json["experimental"]!!
            .jsonObject["cache_file"]!!
            .jsonObject
        assertTrue(cacheFile["enabled"]!!.jsonPrimitive.boolean)
        assertEquals("cache.db", cacheFile["path"]!!.jsonPrimitive.content)
        assertTrue(cacheFile["store_fakeip"]!!.jsonPrimitive.boolean)
    }

    private fun parseJson(value: String) = Json.parseToJsonElement(value).jsonObject
}
