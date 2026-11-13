package com.tecclub.flutter_singbox.xray

import kotlinx.serialization.json.*
import kotlin.test.*

class XrayBootstrapPlanTest {
    private fun config(host: String = "upstream.example", tls: String = "\"serverName\":\"identity.example\",\"allowInsecure\":false", transportHost: String = "\"host\":\"http.example\",") = """{
      "log":{"loglevel":"warning"},"inbounds":[{"protocol":"tun"}],
      "outbounds":[{"tag":"proxy","protocol":"vless","settings":{"vnext":[{"address":"$host","port":443,"users":[{"id":"private-credential"}]}]},
        "streamSettings":{"network":"xhttp","security":"tls","tlsSettings":{$tls},"xhttpSettings":{$transportHost"path":"/transport","extra":{"scMaxEachPostBytes":1000000}}}},
        {"tag":"dns-out","protocol":"dns"}],"routing":{"domainStrategy":"AsIs"}}
    """

    @Test fun resolvesOnlyEncryptedSingleUpstreamAndPreservesIdentityAndRouting() {
        val original = Json.parseToJsonElement(config()).jsonObject
        val plan = XrayBootstrapPlan.parse(config())
        assertEquals("upstream.example", plan.hostname)
        val resolved = Json.parseToJsonElement(plan.withAddress("192.0.2.1")).jsonObject
        val expected = original["outbounds"]!!.jsonArray.first().jsonObject
        val proxy = resolved["outbounds"]!!.jsonArray.first().jsonObject
        assertEquals(expected["streamSettings"], proxy["streamSettings"])
        assertEquals(original["routing"], resolved["routing"])
        assertEquals(original["inbounds"], resolved["inbounds"])
        assertEquals("192.0.2.1", proxy["settings"]!!.jsonObject["vnext"]!!.jsonArray.single().jsonObject["address"]!!.jsonPrimitive.content)
        assertFalse(plan.toString().contains("example"))
    }
    @Test fun implicitTlsAndHttpIdentitiesUseOriginalHostnameNotResolvedAddress() {
        val root = Json.parseToJsonElement(XrayBootstrapPlan.parse(config(tls = "\"allowInsecure\":false", transportHost = "")).withAddress("2001:db8::1")).jsonObject
        val stream = root["outbounds"]!!.jsonArray.first().jsonObject["streamSettings"]!!.jsonObject
        assertEquals("upstream.example", stream["tlsSettings"]!!.jsonObject["serverName"]!!.jsonPrimitive.content)
        assertFalse(stream["tlsSettings"]!!.jsonObject["allowInsecure"]!!.jsonPrimitive.boolean)
        assertEquals("upstream.example", stream["xhttpSettings"]!!.jsonObject["host"]!!.jsonPrimitive.content)
    }
    @Test fun literalAddressesDoNotRequireBootstrap() {
        assertNull(XrayBootstrapPlan.parse(config("192.0.2.5")).hostname)
        assertNull(XrayBootstrapPlan.parse(config("2001:db8::5")).hostname)
    }
    @Test fun rejectsHostnameAsResolvedAnswerAndUnsupportedTransports() {
        assertFailsWith<IllegalArgumentException> { XrayBootstrapPlan.parse(config()).withAddress("other.example") }
        assertFailsWith<IllegalArgumentException> { XrayBootstrapPlan.parse(config().replace("\"security\":\"tls\"", "\"security\":\"none\"")) }
    }
    @Test fun serializedRequestedConfigIsNotMutatedByResolvedPlan() {
        val input = config(); val plan = XrayBootstrapPlan.parse(input)
        plan.withAddress("192.0.2.8")
        assertEquals("upstream.example", XrayBootstrapPlan.parse(input).hostname)
    }
}
