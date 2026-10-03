package com.tecclub.flutter_singbox.diagnostics

import android.app.ActivityManager
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper
import android.os.BatteryManager
import android.os.Build
import android.os.Debug
import android.os.PowerManager
import android.os.SystemClock
import android.provider.Settings
import org.json.JSONObject
import java.io.File
import java.io.OutputStream
import java.security.MessageDigest
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicLong
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream

internal fun configureDiagnosticDatabase(db: SQLiteDatabase) {
    for (pragma in listOf("PRAGMA busy_timeout=1000", "PRAGMA journal_size_limit=1048576",
            "PRAGMA wal_autocheckpoint=128")) {
        db.rawQuery(pragma, null).use { it.moveToFirst() }
    }
    val pageSize = db.rawQuery("PRAGMA page_size", null).use { it.moveToFirst(); it.getLong(0) }
    db.rawQuery("PRAGMA max_page_count=${32L * 1024 * 1024 / pageSize}", null).use { it.moveToFirst() }
}

object OnDeviceDiagnostics {
    private val dropped = AtomicLong()
    private val writeFailures = AtomicLong()
    private val executor = ThreadPoolExecutor(1, 1, 0L, TimeUnit.SECONDS,
        ArrayBlockingQueue(256), { task -> Thread(task, "YurichDiagnostics").apply { isDaemon = true } },
        { _, _ -> dropped.incrementAndGet() })
    @Volatile private var helper: Journal? = null
    private var lastSampleElapsed = -DiagnosticPolicy.SAMPLE_INTERVAL_MS

    @Synchronized private fun journal(context: Context): Journal = helper ?: Journal(context.applicationContext)
        .also { helper = it }

    private class Journal(val context: Context) : SQLiteOpenHelper(context,
        File(context.noBackupFilesDir, "seven-day-diagnostics.db").absolutePath, null, 1) {
        init { setWriteAheadLoggingEnabled(true) }
        override fun onConfigure(db: SQLiteDatabase) {
            configureDiagnosticDatabase(db)
        }
        override fun onCreate(db: SQLiteDatabase) {
            db.execSQL("CREATE TABLE run (id INTEGER PRIMARY KEY CHECK(id=1), started INTEGER NOT NULL, elapsed INTEGER NOT NULL, boot INTEGER NOT NULL, ended INTEGER NOT NULL DEFAULT 0, rotated INTEGER NOT NULL DEFAULT 0)")
            db.execSQL("CREATE TABLE events (id INTEGER PRIMARY KEY AUTOINCREMENT, run INTEGER NOT NULL, wall INTEGER NOT NULL, elapsed INTEGER NOT NULL, code TEXT NOT NULL, data TEXT NOT NULL, exitKey TEXT)")
            db.execSQL("CREATE UNIQUE INDEX exit_identity ON events(run,exitKey)")
        }
        override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) = Unit
    }

    private fun boot(context: Context): Int = runCatching {
        Settings.Global.getInt(context.contentResolver, Settings.Global.BOOT_COUNT)
    }.getOrDefault(-1)

    private fun activeRun(db: SQLiteDatabase, context: Context): Long? {
        db.rawQuery("SELECT started,elapsed,boot,ended FROM run WHERE id=1", null).use { row ->
            if (!row.moveToFirst() || row.getLong(3) != 0L) return null
            val start = row.getLong(0)
            if (DiagnosticPolicy.expired(start, row.getLong(1), row.getInt(2),
                    System.currentTimeMillis(), SystemClock.elapsedRealtime(), boot(context))) {
                db.execSQL("UPDATE run SET ended=? WHERE id=1 AND ended=0",
                    arrayOf(start + DiagnosticPolicy.DURATION_MS))
                return null
            }
            return start
        }
    }

    fun start(context: Context): Map<String, Any> {
        val db = journal(context).writableDatabase
        db.beginTransaction()
        try {
            if (activeRun(db, context) == null) {
                val now = System.currentTimeMillis()
                db.execSQL("INSERT OR REPLACE INTO run(id,started,elapsed,boot) VALUES(1,?,?,?)",
                    arrayOf<Any>(now, SystemClock.elapsedRealtime(), boot(context)))
            }
            db.setTransactionSuccessful()
        } finally { db.endTransaction() }
        record(context, "ui", labels = mapOf("state" to "resumed"))
        sample(context, force = true)
        return status(context)
    }

    fun stop(context: Context): Map<String, Any> {
        journal(context).writableDatabase.execSQL("UPDATE run SET ended=? WHERE id=1 AND ended=0",
            arrayOf(System.currentTimeMillis()))
        return status(context)
    }

    fun status(context: Context): Map<String, Any> {
        val db = journal(context).writableDatabase
        val active = activeRun(db, context) != null
        db.rawQuery("SELECT started,ended,rotated FROM run WHERE id=1", null).use { row ->
            if (!row.moveToFirst()) return mapOf("active" to false, "available" to false)
            val start = row.getLong(0)
            val count = db.rawQuery("SELECT COUNT(*) FROM events WHERE run=?", arrayOf(start.toString()))
                .use { it.moveToFirst(); it.getLong(0) }
            return mapOf("active" to active, "available" to true, "startedAtMs" to start,
                "endsAtMs" to start + DiagnosticPolicy.DURATION_MS, "endedAtMs" to row.getLong(1),
                "events" to count, "rotatedEvents" to row.getLong(2), "durationDays" to 7)
        }
    }

    fun record(context: Context, code: String, numbers: Map<String, Long> = emptyMap(),
               labels: Map<String, String> = emptyMap(), fingerprint: String? = null) {
        if (!DiagnosticPolicy.validate(code, numbers, labels)) return
        val wall = System.currentTimeMillis()
        val elapsed = SystemClock.elapsedRealtime()
        executor.execute {
            runCatching { append(context, code, numbers, labels, wall, elapsed, fingerprint = fingerprint) }
                .onFailure {
                    writeFailures.incrementAndGet()
                    android.util.Log.w("YurichDiagnostics", "Local observation unavailable: ${it.javaClass.simpleName}")
                }
        }
    }

    private fun append(context: Context, code: String, numbers: Map<String, Long>,
                       labels: Map<String, String>, wall: Long, elapsed: Long,
                       historicalRun: Long? = null, fingerprint: String? = null) {
        if (!DiagnosticPolicy.validate(code, numbers, labels)) return
        val db = journal(context).writableDatabase
        db.beginTransaction()
        try {
            val run = historicalRun ?: activeRun(db, context) ?: run {
                db.setTransactionSuccessful()
                return
            }
            if (wall < run) return
            val data = JSONObject().apply {
                numbers.forEach { (key, value) -> put(key, value) }
                labels.forEach { (key, value) -> put(key, value) }
                val missing = dropped.get()
                if (missing > 0) put("droppedQueue", missing)
                val failedWrites = writeFailures.get()
                if (failedWrites > 0) put("writeFailures", failedWrites)
                if (fingerprint != null && Regex("[0-9a-f]{64}").matches(fingerprint)) {
                    val token = MessageDigest.getInstance("SHA-256")
                        .digest("$run:$fingerprint".toByteArray())
                        .take(8).joinToString("") { "%02x".format(it) }
                    put("profile", token)
                }
            }.toString()
            val values = ContentValues().apply {
                put("run", run); put("wall", wall); put("elapsed", elapsed)
                put("code", code); put("data", data)
                if (code == "exit") put("exitKey", "${numbers["pid"]}:${numbers["exitAtMs"]}:${numbers["reason"]}")
            }
            val pageCount = db.rawQuery("PRAGMA page_count", null).use { it.moveToFirst(); it.getLong(0) }
            val freePages = db.rawQuery("PRAGMA freelist_count", null).use { it.moveToFirst(); it.getLong(0) }
            val maxPages = db.rawQuery("PRAGMA max_page_count", null).use { it.moveToFirst(); it.getLong(0) }
            if (pageCount - freePages >= maxPages - 128) {
                val removed = db.delete("events", "id IN (SELECT id FROM events ORDER BY id LIMIT 2000)", null)
                db.execSQL("UPDATE run SET rotated=rotated+? WHERE id=1", arrayOf(removed))
            }
            if (code == "exit") db.insertWithOnConflict("events", null, values, SQLiteDatabase.CONFLICT_IGNORE)
            else db.insertOrThrow("events", null, values)
            // Keep bounded history across runs. Rotation is explicit in the exported metadata.
            val removed = db.delete("events", "id <= (SELECT id FROM events ORDER BY id DESC LIMIT 1 OFFSET ?)",
                arrayOf(DiagnosticPolicy.MAX_EVENTS.toString()))
            if (removed > 0) db.execSQL("UPDATE run SET rotated=rotated+? WHERE id=1", arrayOf(removed))
            db.setTransactionSuccessful()
        } finally { db.endTransaction() }
    }

    fun sample(context: Context, force: Boolean = false) {
        val now = SystemClock.elapsedRealtime()
        synchronized(this) {
            if (!force && now - lastSampleElapsed < DiagnosticPolicy.SAMPLE_INTERVAL_MS) return
            lastSampleElapsed = now
        }
        executor.execute {
            runCatching {
                if (activeRun(journal(context).writableDatabase, context) == null) return@runCatching
                val memory = Debug.MemoryInfo().also(Debug::getMemoryInfo)
                val power = context.getSystemService(Context.POWER_SERVICE) as PowerManager
                val battery = context.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
                append(context, "sample", mapOf(
                    "pid" to android.os.Process.myPid().toLong(), "pssKb" to memory.totalPss.toLong(),
                    "heapKb" to memory.nativePss.toLong(), "screen" to if (power.isInteractive) 1 else 0,
                    "idle" to if (power.isDeviceIdleMode) 1 else 0,
                    "battery" to (battery?.getIntExtra(BatteryManager.EXTRA_LEVEL, -1) ?: -1).toLong(),
                    "tempTenthsC" to (battery?.getIntExtra(BatteryManager.EXTRA_TEMPERATURE, -1) ?: -1).toLong(),
                    "charging" to (battery?.getIntExtra(BatteryManager.EXTRA_PLUGGED, -1) ?: -1).toLong(),
                    "txBytes" to android.net.TrafficStats.getUidTxBytes(android.os.Process.myUid()),
                    "rxBytes" to android.net.TrafficStats.getUidRxBytes(android.os.Process.myUid()),
                ), mapOf("role" to DiagnosticPolicy.role(currentProcessName(), context.packageName)),
                    System.currentTimeMillis(), now)
                collectExits(context)
            }.onFailure { android.util.Log.w("YurichDiagnostics", "Resource observation unavailable: ${it.javaClass.simpleName}") }
        }
    }

    private fun currentProcessName(): String = if (Build.VERSION.SDK_INT >= 28)
        android.app.Application.getProcessName() else ""

    private fun collectExits(context: Context, includeEnded: Boolean = false) {
        if (Build.VERSION.SDK_INT < 30) return
        val state = status(context)
        val start = state["startedAtMs"] as? Long ?: return
        val end = (state["endedAtMs"] as Long).takeIf { it > 0 }
            ?: (start + DiagnosticPolicy.DURATION_MS)
        val manager = context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        manager.getHistoricalProcessExitReasons(context.packageName, 0, 64)
            .filter { it.timestamp in start..end }.forEach { exit ->
                // Descriptions and traceInputStream may contain arbitrary sensitive log messages.
                append(context, "exit", mapOf("pid" to exit.pid.toLong(), "reason" to exit.reason.toLong(),
                    "status" to exit.status.toLong().coerceAtLeast(-1), "exitAtMs" to exit.timestamp,
                    "pssKb" to exit.pss, "rssKb" to exit.rss),
                    mapOf("role" to DiagnosticPolicy.role(exit.processName, context.packageName)),
                    System.currentTimeMillis(), SystemClock.elapsedRealtime(),
                    historicalRun = if (includeEnded) start else null)
            }
    }

    fun export(context: Context, output: OutputStream) {
        collectExits(context, includeEnded = true)
        val state = status(context)
        check(state["available"] == true) { "No diagnostic run" }
        // Export uses a read snapshot; recording may continue without stopping the VPN.
        val db = journal(context).readableDatabase
        ZipOutputStream(output.buffered()).use { zip ->
            val snapshotStarted = System.currentTimeMillis()
            var exportedEvents = 0
            zip.putNextEntry(ZipEntry("events.jsonl"))
            db.rawQuery("SELECT wall,elapsed,code,data FROM events WHERE run=? ORDER BY id",
                arrayOf(state["startedAtMs"].toString())).use { rows ->
                while (rows.moveToNext()) {
                    val event = JSONObject().put("wallMs", rows.getLong(0)).put("elapsedMs", rows.getLong(1))
                        .put("event", rows.getString(2)).put("data", JSONObject(rows.getString(3)))
                    zip.write((event.toString() + "\n").toByteArray())
                    exportedEvents++
                }
            }
            zip.closeEntry()
            zip.putNextEntry(ZipEntry("metadata.json"))
            val version = context.packageManager.getPackageInfo(context.packageName, 0).versionName.orEmpty()
            zip.write(JSONObject(state + mapOf("schema" to 1, "api" to Build.VERSION.SDK_INT,
                "appVersion" to version, "exportedEvents" to exportedEvents,
                "snapshotStartedAtMs" to snapshotStarted, "snapshotEndedAtMs" to System.currentTimeMillis(),
                "observation" to "opportunistic_native_watchdog", "exitInfoSupported" to (Build.VERSION.SDK_INT >= 30),
                "maxEvents" to DiagnosticPolicy.MAX_EVENTS, "queueDropsThisProcess" to dropped.get(),
                "writeFailuresThisProcess" to writeFailures.get(), "secretsIncluded" to false,
                "automaticUpload" to false)).toString(2).toByteArray())
            zip.closeEntry()
        }
    }
}
