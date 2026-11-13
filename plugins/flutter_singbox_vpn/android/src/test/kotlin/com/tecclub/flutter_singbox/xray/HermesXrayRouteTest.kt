package com.tecclub.flutter_singbox.xray

import kotlinx.serialization.json.*
import kotlin.test.*

internal class HermesXrayRouteTest {
    private val route = HermesXrayRoutePolicy("incidents.go-it.tech")
    private val path = "/data/user/0/test.app/files/incident-a.sock"
    private val base = """{
      "log":{"loglevel":"warning"},
      "dns":{"servers":["localhost"]},
      "inbounds":[
        {"tag":"tun-in","protocol":"tun","settings":{"name":"yurich-xray0"}},
        {"tag":"health-http-in","listen":"127.0.0.1","port":20808,"protocol":"http","settings":{"allowTransparent":false}}
      ],
      "outbounds":[
        {"tag":"proxy","protocol":"vless","settings":{"vnext":[{"address":"192.0.2.10","port":443,"users":[{"id":"00000000-0000-4000-8000-000000000001","encryption":"none","level":0}]}]},
         "streamSettings":{"network":"xhttp","security":"tls","tlsSettings":{"serverName":"vpn.example.test","fingerprint":"firefox","alpn":["h2"]},"xhttpSettings":{"path":"/x","host":"vpn.example.test","mode":"auto"}}},
        {"tag":"dns-out","protocol":"dns"},
        {"tag":"direct","protocol":"freedom","settings":{"domainStrategy":"UseIPv4"}},
        {"tag":"block","protocol":"blackhole"}
      ],
      "routing":{"domainStrategy":"IPIfNonMatch","rules":[
        {"type":"field","domain":["domain:example.test"],"outboundTag":"direct"},
        {"type":"field","network":"tcp,udp","outboundTag":"proxy"}
      ]}
    }"""

    @Test fun patchesFirstRuleAndPreservesOrdinaryRoutesAndProxy() {
        val result = assertNotNull(route.prepare(base, path))
        assertTrue(route.verifies(result, path))
        val old = Json.parseToJsonElement(base).jsonObject
        val new = Json.parseToJsonElement(result).jsonObject
        assertEquals(old["outbounds"], new["outbounds"])
        assertEquals(old["dns"], new["dns"])
        assertEquals(old["routing"]!!.jsonObject["rules"], JsonArray(new["routing"]!!.jsonObject["rules"]!!.jsonArray.drop(1)))
        assertEquals(JsonPrimitive("none"), new["log"]!!.jsonObject["access"])
        assertFalse(route.verifies(base, path))
        assertNull(route.prepare(result, path))
    }

    @Test fun aBuildWithoutThePilotDestinationCannotAdmitAnyRoute() {
        val disabled = HermesXrayRoutePolicy("")
        val patched = assertNotNull(route.prepare(base, path))
        assertFalse(disabled.canBootstrap(base))
        assertNull(disabled.prepare(base, path))
        assertFalse(disabled.verifies(patched, path))
    }

    @Test fun acceptsEveryNarrowXhttpMode() {
        for (mode in listOf("auto", "packet-up", "stream-up", "stream-one")) {
            assertNotNull(route.prepare(base.replace("\"mode\":\"auto\"", "\"mode\":\"$mode\""), path))
        }
        assertNull(route.prepare(base.replace("\"auto\"", "\"guess\""), path))
    }

    @Test fun preBootstrapAllowsOnlyValidUpstreamNotIncidentTarget() {
        assertTrue(route.canBootstrap(base))
        val unresolved = base.replace("192.0.2.10", "upstream.example.test")
        assertTrue(route.canBootstrap(unresolved))
        assertNull(route.prepare(unresolved, path))
        for (host in listOf("incidents.go-it.tech", "INCIDENTS.GO-IT.TECH.", "localhost", "x.local", "a..example.com", "-bad.example.com", "1.2.3.999", "[::1]", "https://vpn.example.com")) {
            assertFalse(route.canBootstrap(base.replace("192.0.2.10", host)), host)
        }
        assertFalse(route.canBootstrap(base.replace("vpn.example.test", "incidents.go-it.tech")))
        assertFalse(route.canBootstrap(base.replace("\"network\":\"xhttp\"", "\"network\":\"tcp\"")))
    }

    @Test fun rejectsDirectRawAndUnknownRuntimeShapes() {
        assertNull(route.prepare("{}", path))
        assertNull(route.prepare("{\"xray\":$base}", path))
        assertNull(route.prepare(base.replace("\"protocol\":\"vless\"", "\"protocol\":\"freedom\""), path))
        assertNull(route.prepare(base.replace("\"log\":", "\"api\":{},\"log\":"), path))
        assertNull(route.prepare(base.replace("\"network\":\"xhttp\"", "\"network\":\"tcp\""), path))
    }

    @Test fun rejectsDomainAndAmbiguousUpstreams() {
        for (address in listOf("vpn.example.test", "incidents.go-it.tech", "127.0.0.1", "0.0.0.0", "224.1.2.3", "192.000.2.10", "::1")) {
            assertNull(route.prepare(base.replace("192.0.2.10", address), path), address)
        }
        assertNull(route.prepare(base.replace("vpn.example.test", "INCIDENTS.GO-IT.TECH."), path))
    }

    @Test fun rejectsTrustOverridesAndAlternateXhttpPaths() {
        for (field in listOf("\"allowInsecure\":true", "\"allowInsecure\":false", "\"pinnedPeerCertificateChainSha256\":[\"x\"]", "\"certificates\":[]")) {
            assertNull(route.prepare(base.replace("\"serverName\":", "$field,\"serverName\":"), path))
        }
        assertNull(route.prepare(base.replace("\"alpn\":[\"h2\"]", "\"alpn\":[\"h3\"]"), path))
        for (field in listOf("\"extra\":{}", "\"downloadSettings\":{}", "\"headers\":{}", "\"xmux\":{}")) {
            assertNull(route.prepare(base.replace("\"path\":\"/x\"", "$field,\"path\":\"/x\""), path))
        }
    }

    @Test fun rejectsDetoursTargetResolutionAndDuplicates() {
        for (field in listOf("\"proxySettings\":{\"tag\":\"direct\"}", "\"targetStrategy\":\"UseIP\"", "\"mux\":{\"enabled\":true}")) {
            assertNull(route.prepare(base.replace("\"tag\":\"proxy\",", "$field,\"tag\":\"proxy\","), path))
        }
        assertNull(route.prepare(base.replace("\"network\":\"xhttp\"", "\"sockopt\":{\"dialerProxy\":\"direct\"},\"network\":\"xhttp\""), path))
        assertNull(route.prepare(base.replace("\"tag\":\"direct\"", "\"tag\":\"proxy\""), path))
        assertNull(route.prepare(base.replace("\"protocol\":\"vless\"", "\"protocol\":\"freedom\",\"protocol\":\"vless\""), path))
        assertNull(route.prepare(base.replace("\"protocol\":\"vless\"", "\"proto\\u0063ol\":\"freedom\",\"protocol\":\"vless\""), path))
    }

    @Test fun rejectsShadowedChangedAndUnownedProofs() {
        val patched = assertNotNull(route.prepare(base, path))
        assertFalse(route.verifies(patched, path + "x"))
        assertFalse(route.verifies(patched.replace("incidents.go-it.tech", "other.example.test"), path))
        assertFalse(route.verifies(patched.replace("\"access\":\"none\"", "\"access\":\"/tmp/access.log\""), path))
        val root = Json.parseToJsonElement(patched).jsonObject
        val routing = root["routing"]!!.jsonObject
        val rules = routing["rules"]!!.jsonArray
        val shadowed = JsonObject(root.toMutableMap().apply {
            put("routing", JsonObject(routing.toMutableMap().apply {
                put("rules", JsonArray(listOf(rules[1], rules[0]) + rules.drop(2)))
            }))
        }).toString()
        assertFalse(route.verifies(shadowed, path))
    }

    @Test fun rejectsUnsafeSocketPathsAndMalformedJson() {
        for (bad in listOf("@abstract", "/tmp/report.sock", "/data/../tmp/a", "/data/a\u0000", "/data/" + "a".repeat(101))) {
            assertNull(route.prepare(base, bad))
        }
        assertNull(route.prepare("{\"x\":", path))
        assertFalse(route.verifies("{", path))
    }
}
