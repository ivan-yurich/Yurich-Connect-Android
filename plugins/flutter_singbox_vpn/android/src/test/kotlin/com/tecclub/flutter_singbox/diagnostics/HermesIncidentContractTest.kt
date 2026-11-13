package com.tecclub.flutter_singbox.diagnostics

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.put
import java.time.Instant
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull

class HermesIncidentContractTest {
    private val at = Instant.parse("2026-11-12T10:31:00Z").toEpochMilli()
    private val id = "92da10ea-2dce-481e-a5c4-54b770b64c12"
    private val event = buildJsonObject {
        put("schema_version", 1)
        put("report_id", id)
        put("occurred_at", "2026-11-12T10:31:00Z")
        put("app_version", "1.0.132-test.20261112.14")
        put("location", "unknown")
        put("ingress", "unknown")
        put("protocol", "xhttp")
        put("network", "cellular")
        put("stage", "vpn_start")
        put("code", "timeout")
    }

    @Test
    fun `canonical projection keeps the exact ten fields and original identity`() {
        val report = assertNotNull(HermesIncidentContract.projectLocal(event))
        assertEquals(id, report.reportId)
        assertEquals(at, report.occurredAtMillis)
        assertEquals(event.toString(), report.body().decodeToString())
        val first = report.body()
        val restored = assertNotNull(HermesIncidentContract.decode(first))
        assertContentEquals(first, restored.body())
        assertEquals(report.reportId, restored.reportId)
        first.fill(0)
        assertEquals(event.toString(), report.body().decodeToString())
    }

    @Test
    fun `synthetic local failure keeps the persisted UUID and UTC minute`() {
        val storage = object : LocalIncidentStorage {
            var value: String? = null
            override fun read(): String? = value
            override fun write(value: String) { this.value = value }
        }
        val queue = LocalConnectionIncidentQueue { at + 59_000L }
        val epoch = queue.setEnabled(storage, true).getValue("epoch") as String
        queue.record(storage, epoch, "1.0.132-test.20261112.14", "xhttp", "cellular", "vpn_start", "timeout")
        val reports = Json.parseToJsonElement(requireNotNull(storage.value)).jsonObject.getValue("events") as JsonArray
        val local = reports.single().jsonObject
        val report = assertNotNull(HermesIncidentContract.projectLocal(local))
        assertEquals(local, Json.parseToJsonElement(report.body().decodeToString()))
        assertEquals(at, report.occurredAtMillis)
    }

    @Test
    fun `rejects extra fields missing fields and every wrong JSON type`() {
        for (extra in listOf("platform", "endpoint", "device_id", "epoch", "raw_log")) {
            assertNull(HermesIncidentContract.projectLocal(changed(extra, JsonPrimitive("test-only"))))
        }
        for (missing in event.keys) {
            assertNull(HermesIncidentContract.projectLocal(JsonObject(event - missing)))
        }
        for (schema in listOf(JsonPrimitive("1"), JsonPrimitive(1.0), JsonPrimitive(true), JsonPrimitive(2), JsonNull)) {
            assertNull(HermesIncidentContract.projectLocal(changed("schema_version", schema)))
        }
        for (key in event.keys - "schema_version") {
            for (nonString in listOf(JsonPrimitive(1), JsonNull, JsonArray(emptyList()))) {
                assertNull(HermesIncidentContract.projectLocal(changed(key, nonString)))
            }
        }
    }

    @Test
    fun `validates UUID version variant case and a real UTC minute`() {
        for (badId in listOf(id.uppercase(), id.replace("481e", "381e"), id.replace("a5c4", "25c4"), id + " ")) {
            assertNull(HermesIncidentContract.projectLocal(changed("report_id", JsonPrimitive(badId))))
        }
        for (time in listOf(
            "2026-02-29T10:31:00Z", "2026-11-12T24:31:00Z", "2026-11-12T10:31:01Z",
            "2026-11-12T10:31:00+00:00", "2026-11-12T10:31:00.000Z",
        )) {
            assertNull(HermesIncidentContract.projectLocal(changed("occurred_at", JsonPrimitive(time))))
        }
        assertNotNull(HermesIncidentContract.projectLocal(changed("occurred_at", JsonPrimitive("2024-02-29T10:31:00Z"))))
    }

    @Test
    fun `version accepts release and pilot shapes only`() {
        for (version in listOf("0.0.0", "1.0.132", "1.0.132-test.20240229.14")) {
            assertNotNull(HermesIncidentContract.projectLocal(changed("app_version", JsonPrimitive(version))))
        }
        for (version in listOf(
            "1.2", "1.2.3-beta", "1.2.3+7", "1.2.3-test.14", "1.2.3-test.2026111.14",
            "1.2.3-test.20260229.14", "1.2.3-test.20261312.14", "1.2.3-test.20261112.a", "01.2.3",
        )) {
            assertNull(HermesIncidentContract.projectLocal(changed("app_version", JsonPrimitive(version))))
        }
    }

    @Test
    fun `local projection does not infer location ingress or accept arbitrary enum strings`() {
        for (pair in listOf("location" to "warsaw", "ingress" to "moscow")) {
            val variant = changed(pair.first, JsonPrimitive(pair.second))
            assertNull(HermesIncidentContract.projectLocal(variant))
            assertNotNull(HermesIncidentContract.decode(variant.toString().encodeToByteArray()))
        }
        for (key in listOf("location", "ingress", "protocol", "network", "stage", "code")) {
            val variant = changed(key, JsonPrimitive("example.invalid"))
            assertNull(HermesIncidentContract.projectLocal(variant))
            assertNull(HermesIncidentContract.decode(variant.toString().encodeToByteArray()))
        }
    }

    @Test
    fun `stored decoder rejects duplicate keys malformed UTF8 and noncanonical bodies`() {
        val text = event.toString()
        assertNull(HermesIncidentContract.decode(text.replace("{", "{\"schema_version\":1,").encodeToByteArray()))
        assertNull(HermesIncidentContract.decode((" " + text).encodeToByteArray()))
        assertNull(HermesIncidentContract.decode(text.replace("xhttp", "\\u0078http").encodeToByteArray()))
        assertNull(HermesIncidentContract.decode(text.encodeToByteArray().apply { this[4] = 0xff.toByte() }))
        assertNull(HermesIncidentContract.decode("{}".encodeToByteArray()))
        assertNull(HermesIncidentContract.decode("{bad}".encodeToByteArray()))
    }

    @Test
    fun `the payload cannot exceed 1024 bytes`() {
        val overhead = changed("app_version", JsonPrimitive("")).toString().encodeToByteArray().size
        val allowedVersion = "9".repeat(HermesIncidentContract.MAX_BODY_BYTES - overhead - 4) + ".0.0"
        val allowed = assertNotNull(HermesIncidentContract.projectLocal(changed("app_version", JsonPrimitive(allowedVersion))))
        assertEquals(1024, allowed.body().size)
        assertNotNull(HermesIncidentContract.decode(allowed.body()))
        val oversized = changed("app_version", JsonPrimitive("9$allowedVersion"))
        assertNull(HermesIncidentContract.projectLocal(oversized))
        assertNull(HermesIncidentContract.decode(oversized.toString().encodeToByteArray()))
    }

    private fun changed(key: String, value: JsonElement): JsonObject = JsonObject(event + (key to value))
}
