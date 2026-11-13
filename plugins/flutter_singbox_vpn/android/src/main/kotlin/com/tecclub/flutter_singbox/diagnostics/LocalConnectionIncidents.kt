package com.tecclub.flutter_singbox.diagnostics

import android.content.Context
import android.util.AtomicFile
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import java.io.DataInputStream
import java.io.File
import java.io.FileNotFoundException
import java.io.RandomAccessFile
import java.text.ParsePosition
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import java.util.UUID

/** Single event queue. Call on an I/O thread; the bridge never receives event bodies. */
object LocalConnectionIncidents {
    private val mutex = Any()
    private val queue = LocalConnectionIncidentQueue()
    private val retryPolicyTime = java.util.concurrent.atomic.AtomicLong(0)

    private fun deliveryTime(): Long {
        // Within the process, an abrupt wall-clock rollback must not open a
        // second pacing window. After restart the persisted deadline still wins.
        val now = System.currentTimeMillis().coerceAtLeast(0)
        return retryPolicyTime.updateAndGet { maxOf(it, now) }
    }

    fun state(context: Context): Map<String, Any> = access(context) {
        runCatching { resumeDeliveryClear(context, it) }
        queue.state(it)
    }

    fun setEnabled(context: Context, enabled: Boolean): Map<String, Any> = try {
        access(context, revoking = !enabled) {
            val state = queue.setEnabled(it, enabled)
            if (!enabled && HermesPilotGate.enabled(context)) {
                val journal = deliveryFile(context)
                val old = runCatching { HermesLedger.decode(journal.read()) }.getOrDefault(HermesLedger())
                journal.write(HermesLedger(pacing = old.pacing).encode())
            }
            state
        }
    } finally {
        if (!enabled) HermesPilotGate.signalAccessChange(context)
    }

    /** A synthetic sample only. No queue access or upload route is exposed to Flutter. */
    fun hermesPreview(appVersion: String): String? = queue.hermesPreview(appVersion)

    fun record(
        context: Context,
        epoch: String,
        appVersion: String,
        protocol: String,
        network: String,
        stage: String,
        code: String,
    ): Map<String, Any> = access(context) {
        runCatching { resumeDeliveryClear(context, it) }
        queue.record(it, epoch, appVersion, protocol, network, stage, code)
    }.also { HermesPilotGate.signalQueueChange(context) }

    /** This bridge only returns booleans. The Bearer is never returned to the UI. */
    fun hermesDeliveryState(context: Context): Map<String, Any> = access(context) { storage ->
        require(HermesPilotGate.enabled(context))
        val ledger = resumeDeliveryClear(context, storage) ?: return@access deliveryState(null)
        val epoch = queue.state(storage)["epoch"]
        deliveryState(ledger.grant?.takeIf { it.epoch == epoch })
    }

    @android.annotation.TargetApi(29)
    fun configureHermesDelivery(context: Context, enabled: Boolean, bearer: String?): Map<String, Any> = try {
        access(context) { storage ->
            require(HermesPilotGate.enabled(context))
            val file = deliveryFile(context)
            val old = if (enabled) resumeDeliveryClear(context, storage) ?: HermesLedger()
                else runCatching { resumeDeliveryClear(context, storage) }.getOrNull() ?: HermesLedger()
            val epoch = queue.state(storage)["epoch"] as? String
            if (enabled) {
                requireNotNull(epoch)
                require(bearer != null && HermesPilotGate.validBearer(bearer))
                val revision = UUID.randomUUID().toString()
                val grant = HermesGrant(epoch, revision, HermesBearerCipher.seal(bearer, epoch, revision))
                file.write(HermesLedger(grant = grant, pacing = old.pacing).encode())
                deliveryState(grant)
            } else {
                // Write the revocation barrier first. If the process dies
                // before clearing the queue, the next access completes it.
                try {
                    file.write(HermesLedger(pendingClearEpoch = epoch, pacing = old.pacing).encode())
                } catch (error: Exception) {
                    if (epoch != null) queue.clearForRemoteRevocation(storage, epoch)
                    throw error
                }
                resumeDeliveryClear(context, storage)
                deliveryState(null)
            }
        }
    } finally {
        HermesPilotGate.signalAccessChange(context)
    }

    @android.annotation.TargetApi(29)
    internal fun claimDelivery(context: Context): HermesDeliveryTicket? = access(context) { storage ->
        val ledger = resumeDeliveryClear(context, storage) ?: return@access null
        val grant = ledger.grant?.takeUnless { it.blocked } ?: return@access null
        val report = queue.hermesHead(storage, grant.epoch) ?: return@access null
        val at = deliveryTime()
        val pacing = ledger.pacing.reserve(report, at) ?: return@access null
        deliveryFile(context).write(HermesLedger(grant = grant, pacing = pacing).encode())
        HermesDeliveryTicket(report.reportId, report.occurredAtMillis, grant.epoch, grant.revision, pacing.attempts)
    }

    @android.annotation.TargetApi(29)
    internal fun openDeliveryBody(context: Context, ticket: HermesDeliveryTicket): HermesWireRequest? =
        access(context) { storage ->
            val ledger = resumeDeliveryClear(context, storage) ?: return@access null
            val grant = validGrant(ledger, ticket) ?: return@access null
            val report = queue.hermesHead(storage, ticket.epoch)?.takeIf { it.reportId == ticket.reportId }
                ?: return@access null
            val token = HermesBearerCipher.open(grant.ciphertext, grant.epoch, grant.revision)
            HermesWireRequest(report.body(), token)
        }

    internal fun deliveryIsCurrent(context: Context, ticket: HermesDeliveryTicket): Boolean = access(context) { storage ->
        val ledger = resumeDeliveryClear(context, storage) ?: return@access false
        validGrant(ledger, ticket) != null && queue.hermesHead(storage, ticket.epoch)?.reportId == ticket.reportId
    }

    internal fun completeDelivery(
        context: Context,
        ticket: HermesDeliveryTicket,
        response: HermesWireResponse?,
        routeCurrent: () -> Boolean,
    ) =
        access(context) { storage ->
            val ledger = resumeDeliveryClear(context, storage) ?: return@access
            val grant = validGrant(ledger, ticket) ?: return@access
            if (queue.state(storage)["epoch"] != ticket.epoch) return@access
            if (!routeCurrent()) return@access
            val (pacing, result) = ledger.pacing.complete(
                deliveryTime(), HermesIncidentRetryPolicy.expiresAt(ticket.occurredAtMillis),
                response?.status, response?.retryAfter,
            )
            val nextGrant = if (result == HermesIncidentDisposition.Pause) {
                HermesGrant(grant.epoch, grant.revision, grant.ciphertext, blocked = true)
            } else grant
            // Persist a whole-lane throttle BEFORE dropping an expiring FIFO
            // row; a crash must not let a later row bypass Retry-After.
            if (response?.status == 429 && result == HermesIncidentDisposition.Drop) {
                deliveryFile(context).write(HermesLedger(grant = grant,
                    pacing = ledger.pacing.copy(limitedUntil = pacing.limitedUntil)).encode())
            }
            if (result == HermesIncidentDisposition.Accepted || result == HermesIncidentDisposition.Drop) {
                queue.removeHermesCandidate(storage, ticket.epoch, ticket.reportId)
            }
            deliveryFile(context).write(HermesLedger(grant = nextGrant, pacing = pacing).encode())
        }

    private fun validGrant(ledger: HermesLedger, ticket: HermesDeliveryTicket): HermesGrant? =
        ledger.grant?.takeIf {
            !it.blocked && it.epoch == ticket.epoch && it.revision == ticket.revision &&
                ledger.pacing.reportId == ticket.reportId && ledger.pacing.attempts == ticket.attempt
        }

    private fun deliveryState(grant: HermesGrant?) = mapOf(
        "enabled" to (grant != null),
        "tokenConfigured" to (grant != null),
        "authorizationBlocked" to (grant?.blocked == true),
    )

    private fun resumeDeliveryClear(context: Context, storage: LocalIncidentStorage): HermesLedger? {
        if (!HermesPilotGate.enabled(context)) return null
        val file = deliveryFile(context)
        val ledger = HermesLedger.decode(file.read())
        val pending = ledger.pendingClearEpoch ?: return ledger
        queue.clearForRemoteRevocation(storage, pending)
        return HermesLedger(pacing = ledger.pacing).also { file.write(it.encode()) }
    }

    private fun deliveryFile(context: Context) =
        AtomicIncidentStorage(AtomicFile(File(context.noBackupFilesDir, "hermes-delivery-v1.json")))

    private fun <T> access(
        context: Context,
        revoking: Boolean = false,
        action: (LocalIncidentStorage) -> T,
    ): T = synchronized(mutex) {
        if (revoking) queue.blockForRevocation()
        try {
            val directory = context.noBackupFilesDir
            RandomAccessFile(File(directory, "connection-incidents-v1.lock"), "rw").use { lock ->
                lock.channel.lock().use {
                    action(AtomicIncidentStorage(AtomicFile(File(directory, "connection-incidents-v1.json"))))
                }
            }
        } catch (_: Exception) {
            // Do not return platform paths, raw data, or exception messages to the bridge.
            throw IllegalStateException("Local incident storage unavailable")
        }
    }
}

internal interface LocalIncidentStorage {
    fun read(): String?
    fun write(value: String)
}

private class AtomicIncidentStorage(private val file: AtomicFile) : LocalIncidentStorage {
    override fun read(): String? = try {
        file.openRead().use { input ->
            val size = input.channel.size()
            if (size > MAX_BYTES) {
                "" // Invalid, not a newly created store.
            } else {
                val data = ByteArray(size.toInt())
                DataInputStream(input).readFully(data)
                data.toString(Charsets.UTF_8)
            }
        }
    } catch (error: FileNotFoundException) {
        if (file.baseFile.exists() || File(file.baseFile.path + ".bak").exists() ||
            File(file.baseFile.path + ".new").exists()
        ) throw error
        null
    }

    override fun write(value: String) {
        val bytes = value.toByteArray(Charsets.UTF_8)
        check(bytes.size <= MAX_BYTES)
        val output = file.startWrite()
        try {
            output.write(bytes)
            output.fd.sync()
            file.finishWrite(output)
        } catch (error: Exception) {
            file.failWrite(output)
            throw error
        }
        check(read() == value)
    }

    private companion object {
        const val MAX_BYTES = 32 * 1024
    }
}

/** The caller serializes operations, including across app processes. */
internal class LocalConnectionIncidentQueue(private val now: () -> Long = System::currentTimeMillis) {
    private var revocationPending = false

    fun blockForRevocation() {
        revocationPending = true
    }

    fun state(storage: LocalIncidentStorage): Map<String, Any> = load(storage, now()).response()

    fun setEnabled(storage: LocalIncidentStorage, enabled: Boolean): Map<String, Any> {
        if (!enabled) {
            blockForRevocation()
            return clear(storage).response()
        }
        val current = load(storage, now())
        if (current.epoch != null) return current.response()
        return Snapshot(UUID.randomUUID().toString()).also { storage.write(it.json().toString()) }.response()
    }

    fun record(
        storage: LocalIncidentStorage,
        epoch: String,
        appVersion: String,
        protocol: String,
        network: String,
        stage: String,
        code: String,
    ): Map<String, Any> {
        val at = now()
        val current = load(storage, at)
        if (current.epoch == null || current.epoch != epoch || !validVersion(appVersion)) {
            return current.response()
        }
        val report = newEvent(UUID.randomUUID().toString(), at, appVersion, protocol, network, stage, code)
        val next = current.copy(events = (current.events + report).takeLast(LIMIT))
        storage.write(next.json().toString())
        return next.response()
    }

    fun hermesPreview(appVersion: String): String? = HermesIncidentContract.projectLocal(
        newEvent(
            "00000000-0000-4000-8000-000000000001", 1_767_225_600_000L, appVersion,
            "xhttp", "cellular", "vpn_start", "timeout",
        ),
    )?.body()?.toString(Charsets.UTF_8)

    /** For the delivery controller. Use the existing queue, never a second event store. */
    fun hermesCandidates(storage: LocalIncidentStorage, epoch: String): List<HermesIncidentReport> {
        val current = load(storage, now())
        if (current.epoch != epoch) return emptyList()
        return current.events.mapNotNull(HermesIncidentContract::projectLocal)
            .distinctBy(HermesIncidentReport::reportId)
    }

    fun hermesHead(storage: LocalIncidentStorage, epoch: String): HermesIncidentReport? {
        val current = load(storage, now())
        if (current.epoch != epoch) return null
        return current.events.firstNotNullOfOrNull(HermesIncidentContract::projectLocal)
    }

    fun clearForRemoteRevocation(storage: LocalIncidentStorage, epoch: String) {
        if (load(storage, now()).epoch == epoch) {
            // Keep the independent local consent on, but old queue tickets and
            // in-flight failure reporters cannot cross the revoke boundary.
            storage.write(Snapshot(UUID.randomUUID().toString()).json().toString())
        }
    }

    fun removeHermesCandidate(storage: LocalIncidentStorage, epoch: String, reportId: String): Boolean {
        val current = load(storage, now())
        if (current.epoch != epoch) return false
        val remaining = current.events.filterNot { it.string("report_id") == reportId }
        if (remaining.size == current.events.size) return false
        storage.write(current.copy(events = remaining).json().toString())
        return true
    }

    private fun clear(storage: LocalIncidentStorage): Snapshot {
        // One atomic replacement removes both the reports and the previous consent epoch.
        storage.write(OFF.json().toString())
        revocationPending = false
        return OFF
    }

    private fun load(storage: LocalIncidentStorage, at: Long): Snapshot {
        if (revocationPending) return clear(storage)
        val raw = storage.read() ?: return OFF
        val json = try {
            Json.parseToJsonElement(raw) as? JsonObject
        } catch (_: IllegalArgumentException) {
            null
        }
        val epoch = json?.string("epoch")
        val events = json?.get("events") as? JsonArray
        val snapshot = if (json?.keys == envelopeKeys && epoch != null && uuidV4.matches(epoch) && events != null) {
            val utc = utcMinute()
            val live = events.mapNotNull { it as? JsonObject }
                .filter { validEvent(it, at, utc) }
                .takeLast(LIMIT)
            Snapshot(epoch, live)
        } else {
            OFF
        }
        if (json != snapshot.json()) storage.write(snapshot.json().toString())
        return snapshot
    }

    private fun validEvent(event: JsonObject, at: Long, utc: SimpleDateFormat): Boolean {
        if (event.keys != eventKeys || event["schema_version"] != JsonPrimitive(1) ||
            event.string("report_id")?.let(uuidV4::matches) != true ||
            event.string("app_version")?.let(::validVersion) != true ||
            event.string("location") != UNKNOWN || event.string("ingress") != UNKNOWN ||
            event.string("protocol") !in protocols || event.string("network") !in networks ||
            event.string("stage") !in stages || event.string("code") !in codes
        ) return false
        val occurred = event.string("occurred_at") ?: return false
        if (!minutePattern.matches(occurred)) return false
        val position = ParsePosition(0)
        val date = utc.parse(occurred, position) ?: return false
        return position.index == occurred.length && date.time > at - TTL_MS && date.time <= at
    }

    private data class Snapshot(val epoch: String?, val events: List<JsonObject> = emptyList()) {
        fun response(): Map<String, Any> = buildMap {
            put("enabled", epoch != null)
            put("queued", events.size)
            if (epoch != null) put("epoch", epoch)
        }

        fun json(): JsonObject = buildJsonObject {
            put("epoch", epoch?.let { JsonPrimitive(it) } ?: JsonNull)
            put("events", JsonArray(events))
        }
    }

    private companion object {
        const val LIMIT = 50
        const val TTL_MS = 72L * 60 * 60 * 1000
        const val UNKNOWN = "unknown"
        val OFF = Snapshot(null)
        val envelopeKeys = setOf("epoch", "events")
        val eventKeys = setOf("schema_version", "report_id", "occurred_at", "app_version", "location", "ingress",
            "protocol", "network", "stage", "code")
        val protocols = setOf("naive", "hysteria2", "reality", "xhttp", UNKNOWN)
        val networks = setOf("wifi", "cellular", "other", UNKNOWN)
        val stages = setOf("network", "permission", "vpn_start", "dns", "transport", "tls", "auth", "traffic", UNKNOWN)
        val codes = setOf("no_network", "permission_denied", "start_failed", "stop_timeout", "timeout", "dns_failure",
            "tls_error", "auth_failed", "no_traffic", UNKNOWN)
        val uuidV4 = Regex("[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}")
        val minutePattern = Regex("[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:00Z")
        val version = Regex(
            """[0-9]{1,5}\.[0-9]{1,5}\.[0-9]{1,5}(?:-(?:alpha|beta|rc|test)(?:[.-]?[0-9]{1,10})?(?:\.[0-9]{1,10})?)?(?:\+[0-9]{1,10})?""",
        )

        fun validVersion(value: String): Boolean = value.length <= 32 && version.matches(value)

        fun newEvent(
            id: String,
            at: Long,
            appVersion: String,
            protocol: String,
            network: String,
            stage: String,
            code: String,
        ): JsonObject = buildJsonObject {
            put("schema_version", 1)
            put("report_id", id)
            put("occurred_at", utcMinute().format(Date(at)))
            put("app_version", appVersion)
            put("location", UNKNOWN)
            put("ingress", UNKNOWN)
            put("protocol", protocol.takeIf(protocols::contains) ?: UNKNOWN)
            put("network", network.takeIf(networks::contains) ?: UNKNOWN)
            put("stage", stage.takeIf(stages::contains) ?: UNKNOWN)
            put("code", code.takeIf(codes::contains) ?: UNKNOWN)
        }

        fun utcMinute() = SimpleDateFormat("yyyy-MM-dd'T'HH:mm':00Z'", Locale.ROOT).apply {
            timeZone = TimeZone.getTimeZone("UTC")
            isLenient = false
        }

        fun JsonObject.string(key: String): String? =
            (this[key] as? JsonPrimitive)?.takeIf { it.isString }?.content
    }
}
