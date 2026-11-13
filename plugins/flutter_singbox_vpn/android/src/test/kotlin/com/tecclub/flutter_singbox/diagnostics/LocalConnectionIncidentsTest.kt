package com.tecclub.flutter_singbox.diagnostics

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.io.IOException
import java.time.Instant
import java.util.UUID
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

class LocalConnectionIncidentsTest {
    private class MemoryStorage : LocalIncidentStorage {
        var contents: String? = null
        var writable = true

        override fun read(): String? = contents

        override fun write(value: String) {
            if (!writable) throw IOException()
            contents = value
        }

        fun json() = Json.parseToJsonElement(requireNotNull(contents)).jsonObject

        fun events() = (json().getValue("events") as JsonArray).map { it.jsonObject }
    }

    private val storage = MemoryStorage()
    private val minute = Instant.parse("2026-11-12T10:31:00Z").toEpochMilli()
    private var now = minute + 48_376
    private fun queue() = LocalConnectionIncidentQueue { now }

    private fun LocalConnectionIncidentQueue.enable(): String = setEnabled(storage, true).getValue("epoch") as String

    private fun LocalConnectionIncidentQueue.record(
        epoch: String,
        version: String = "1.0.132-test.20261112.7",
        code: String = "timeout",
    ) = record(storage, epoch, version, "reality", "wifi", "transport", code)

    @Test
    fun `off is default and enabled offline state and events survive a fresh instance`() {
        val original = queue()
        val off = mapOf("enabled" to false, "queued" to 0)
        assertEquals(off, original.state(storage))
        assertEquals(off, original.record(UUID.randomUUID().toString()))
        assertNull(storage.contents)

        val epoch = original.enable()
        assertEquals(1, original.record(epoch)["queued"])
        assertEquals(mapOf("enabled" to true, "queued" to 1, "epoch" to epoch), queue().state(storage))
        assertEquals(epoch, queue().enable())
    }

    @Test
    fun `events have only the fixed schema and invalid version does not persist`() {
        val queue = queue()
        val epoch = queue.enable()
        assertEquals(0, queue.record(epoch, version = "1.2.3-unrecognized")["queued"])
        assertEquals(0, queue.record(epoch, version = "9".repeat(500))["queued"])
        assertEquals(1, queue.record(epoch, code = "unexpected-value")["queued"])

        val event = storage.events().single()
        val id = UUID.fromString(event.getValue("report_id").jsonPrimitive.content)
        assertEquals(4, id.version())
        assertEquals(2, id.variant())
        assertEquals(
            JsonObject(
                mapOf(
                    "schema_version" to JsonPrimitive(1),
                    "report_id" to JsonPrimitive(id.toString()),
                    "occurred_at" to JsonPrimitive("2026-11-12T10:31:00Z"),
                    "app_version" to JsonPrimitive("1.0.132-test.20261112.7"),
                    "location" to JsonPrimitive("unknown"),
                    "ingress" to JsonPrimitive("unknown"),
                    "protocol" to JsonPrimitive("reality"),
                    "network" to JsonPrimitive("wifi"),
                    "stage" to JsonPrimitive("transport"),
                    "code" to JsonPrimitive("unknown"),
                ),
            ),
            event,
        )
        assertFalse(requireNotNull(storage.contents).contains("unexpected-value"))

        // Invalid records read from the local store are removed, not passed through.
        val malformed = JsonObject(event + ("extra" to JsonPrimitive("unrecognized")))
        storage.contents = JsonObject(storage.json() + ("events" to JsonArray(listOf(malformed)))).toString()
        assertEquals(0, queue.state(storage)["queued"])
        assertTrue(storage.events().isEmpty())
    }

    @Test
    fun `queue retains only the newest fifty reports`() {
        val queue = queue()
        val epoch = queue.enable()
        queue.record(epoch)
        val first = storage.events().single().getValue("report_id")
        repeat(50) { queue.record(epoch, code = "no_traffic") }
        val events = storage.events()
        val ids = events.map { it.getValue("report_id") }.toSet()
        assertEquals(50, ids.size)
        assertFalse(first in ids)
        assertTrue(events.all { it.getValue("code") == JsonPrimitive("no_traffic") })
    }

    @Test
    fun `opening the queue expires events at seventy two hours`() {
        val original = queue()
        val epoch = original.enable()
        original.record(epoch)
        now += 60_000
        original.record(epoch, code = "no_network")
        now = minute + 72L * 60 * 60 * 1000
        assertEquals(1, queue().state(storage)["queued"])
        assertEquals(JsonPrimitive("no_network"), storage.events().single().getValue("code"))
    }

    @Test
    fun `revocation atomically discards old reports and delayed consent is rejected`() {
        val original = queue()
        val oldEpoch = original.enable()
        original.record(oldEpoch)
        assertEquals(mapOf("enabled" to false, "queued" to 0), original.setEnabled(storage, false))
        assertEquals(JsonNull, storage.json()["epoch"])
        assertTrue(storage.events().isEmpty())

        val restarted = queue()
        assertEquals(false, restarted.record(oldEpoch)["enabled"])
        val epoch = restarted.enable()
        assertNotEquals(oldEpoch, epoch)
        assertEquals(0, restarted.record(oldEpoch)["queued"])
        assertEquals(1, restarted.record(epoch)["queued"])
    }

    @Test
    fun `failed revocation blocks writes until the old consent is erased`() {
        val queue = queue()
        val epoch = queue.enable()
        queue.record(epoch)
        storage.writable = false
        assertFailsWith<IOException> { queue.setEnabled(storage, false) }
        assertFailsWith<IOException> { queue.record(epoch) }
        storage.writable = true
        assertEquals(false, queue.record(epoch)["enabled"])
        assertTrue(storage.events().isEmpty())
    }
}
