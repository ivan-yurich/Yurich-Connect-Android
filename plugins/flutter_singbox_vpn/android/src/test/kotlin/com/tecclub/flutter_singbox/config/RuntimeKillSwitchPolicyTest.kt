package com.tecclub.flutter_singbox.config

import kotlinx.serialization.json.*
import kotlin.test.*

class RuntimeKillSwitchPolicyTest {
    private fun singbox(type: String = "vless") = """{
      "inbounds":[{"type":"tun","exclude_package":["example.bypass"],"route_exclude_address":["0.0.0.0/0"]},
        {"type":"mixed","listen":"127.0.0.1","listen_port":20808}],
      "outbounds":[{"type":"$type","tag":"proxy","server":"upstream.example","tls":{"enabled":true}},
        {"type":"direct","tag":"direct"}],
      "route":{"final":"direct","rules":[{"outbound":"direct"}]},
      "dns":{"final":"local-dns"}
    }"""

    private fun xray() = """{
      "_yurich":{"core":"xray","schema":1,"androidDisallowedPackages":["example.bypass"]},
      "xray":{
        "inbounds":[{"protocol":"tun"},{"protocol":"http","listen":"127.0.0.1","port":20808}],
        "outbounds":[{"tag":"proxy","protocol":"vless","settings":{"vnext":[{"address":"upstream.example"}]},
          "streamSettings":{"network":"xhttp","security":"tls"}},
          {"tag":"direct","protocol":"freedom"}],
        "routing":{"rules":[{"outboundTag":"direct"}]}
      }
    }"""

    @Test fun ordinaryModePreservesEveryByteIncludingRawConfig() {
        val original = " raw custom config "
        val plan = RuntimeKillSwitchPolicy.prepare(original, false)
        assertEquals(original, plan.content)
        assertFalse(plan.strict)
    }

    @Test fun singboxReplacesDirectRoutesAndCapturesBothFamilies() {
        val plan = RuntimeKillSwitchPolicy.prepare(singbox(), true)
        assertTrue(plan.strict)
        val root = Json.parseToJsonElement(plan.content).jsonObject
        val outbound = root["outbounds"]!!.jsonArray.single().jsonObject
        assertEquals("vless", outbound["type"]!!.jsonPrimitive.content)
        assertEquals("proxy", root["route"]!!.jsonObject["final"]!!.jsonPrimitive.content)
        val tun = root["inbounds"]!!.jsonArray.first().jsonObject
        assertFalse(tun.containsKey("exclude_package"))
        assertFalse(tun.containsKey("include_package"))
        assertFalse(tun.containsKey("route_exclude_address"))
        assertEquals(2, tun["address"]!!.jsonArray.size)
        assertFalse(plan.content.contains("example.bypass"))
        assertFalse(plan.content.contains("\"direct\""))
    }

    @Test fun userDnsAlwaysUsesProxyWithExactBootstrapOnly() {
        val root = Json.parseToJsonElement(RuntimeKillSwitchPolicy.prepare(singbox(), true).content).jsonObject
        val dns = root["dns"]!!.jsonObject
        assertEquals("remote-dns-primary", dns["final"]!!.jsonPrimitive.content)
        val bootstrap = dns["rules"]!!.jsonArray.single().jsonObject
        assertEquals("upstream.example", bootstrap["domain"]!!.jsonArray.single().jsonPrimitive.content)
        for (remote in dns["servers"]!!.jsonArray.drop(1)) {
            assertEquals("proxy", remote.jsonObject["detour"]!!.jsonPrimitive.content)
        }
    }

    @Test fun everySupportedSingboxProtocolIsStrictAndIdempotent() {
        for (type in listOf("vless", "naive", "http", "hysteria", "hysteria2")) {
            val once = RuntimeKillSwitchPolicy.prepare(singbox(type), true)
            val twice = RuntimeKillSwitchPolicy.prepare(once.content, true)
            assertEquals(once, twice)
        }
    }

    @Test fun naiveRejectsUnsupportedUdpInsteadOfDirectFallback() {
        val root = Json.parseToJsonElement(RuntimeKillSwitchPolicy.prepare(singbox("naive"), true).content).jsonObject
        assertTrue(root["route"]!!.jsonObject["rules"]!!.jsonArray.any {
            it.jsonObject["network"]?.jsonPrimitive?.content == "udp" &&
                it.jsonObject["action"]?.jsonPrimitive?.content == "reject"
        })
    }

    @Test fun rejectsDirectDisguisedAsProxySelectorsAndChains() {
        for (unsafe in listOf(singbox("direct"), singbox("selector"),
            singbox().replace("\"server\":", "\"detour\":\"direct\",\"server\":"),
            singbox().replace("\"enabled\":true", "\"enabled\":false"))) {
            assertFailsWith<IllegalStateException> { RuntimeKillSwitchPolicy.prepare(unsafe, true) }
        }
    }

    @Test fun malformedUnsupportedRawShapesFailClosedWithoutInputInError() {
        for (unsafe in listOf("not-json secret-marker", "[]", "{}", """{"outbounds":[{"type":"direct"}]}""",
            singbox().replace("\"route\":", "\"endpoints\":[],\"route\":"))) {
            val error = assertFailsWith<IllegalStateException> { RuntimeKillSwitchPolicy.prepare(unsafe, true) }
            assertFalse(error.message!!.contains("secret-marker"))
        }
    }

    @Test fun xrayDropsFreedomAndAppExceptionsWithoutChangingEncryptedTransport() {
        val plan = RuntimeKillSwitchPolicy.prepare(xray(), true)
        val root = Json.parseToJsonElement(plan.content).jsonObject
        assertFalse(root["_yurich"]!!.jsonObject.containsKey("androidDisallowedPackages"))
        assertFalse(plan.content.contains("freedom"))
        assertFalse(plan.content.contains("example.bypass"))
        val config = root["xray"]!!.jsonObject
        assertEquals("xhttp", config["outbounds"]!!.jsonArray.first().jsonObject["streamSettings"]!!.jsonObject["network"]!!.jsonPrimitive.content)
        assertEquals(2, config["outbounds"]!!.jsonArray.size)
        assertEquals(plan, RuntimeKillSwitchPolicy.prepare(plan.content, true))
    }

    @Test fun xrayRefusesDirectProxyAndUnsupportedWrapperSchema() {
        for (unsafe in listOf(xray().replace("\"protocol\":\"vless\"", "\"protocol\":\"freedom\""),
            xray().replace("\"schema\":1", "\"schema\":2"),
            xray().replace("\"streamSettings\":", "\"proxySettings\":{},\"streamSettings\":"))) {
            assertFailsWith<IllegalStateException> { RuntimeKillSwitchPolicy.prepare(unsafe, true) }
        }
    }

    @Test fun xrayUnmatchedDomainsUseEncryptedDnsNotBootstrapLocalhost() {
        val config = Json.parseToJsonElement(RuntimeKillSwitchPolicy.prepare(xray(), true).content)
            .jsonObject.getValue("xray").jsonObject
        val dns = config.getValue("dns").jsonObject
        assertFalse(dns.getValue("disableFallback").jsonPrimitive.boolean)
        assertTrue(dns.getValue("disableFallbackIfMatch").jsonPrimitive.boolean)
        val servers = dns.getValue("servers").jsonArray
        assertEquals(2, servers.size)
        assertTrue(servers.all { it.jsonObject.getValue("address").jsonPrimitive.content.startsWith("https://") })
        assertFalse(dns.toString().contains("localhost"))
        val generatedRule = config.getValue("routing").jsonObject.getValue("rules").jsonArray
            .map { it.jsonObject }.single { it["inboundTag"] != null }
        assertEquals("proxy", generatedRule.getValue("outboundTag").jsonPrimitive.content)
        assertFalse(config.getValue("outbounds").toString().contains("freedom"))
    }
}
