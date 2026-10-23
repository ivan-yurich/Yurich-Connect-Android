package com.tecclub.flutter_singbox

import android.content.Context
import android.content.SharedPreferences
import android.os.SystemClock
import android.util.Log

/**
 * Owns session traffic outside a FlutterPlugin instance.
 *
 * Android can recreate the Flutter engine while the VPN process keeps running.
 * Keeping the accumulator process-wide prevents a UI recreation from resetting
 * counters; the small persisted snapshot also covers a low-memory main-process
 * restart. No endpoint or profile data is stored here.
 */
internal object SessionTrafficRepository {
    private const val TAG = "SessionTrafficRepo"
    private const val PREFS_NAME = "yurich_session_traffic"
    private const val SNAPSHOT_VERSION = 2
    private const val KEY_VERSION = "version"
    private const val KEY_LAST_UPLINK = "last_uplink"
    private const val KEY_LAST_DOWNLINK = "last_downlink"
    private const val KEY_UPLINK = "uplink"
    private const val KEY_DOWNLINK = "downlink"
    private const val KEY_SOURCE = "source"
    private const val MIN_PERSIST_INTERVAL_MS = 15_000L
    private const val PERSIST_INTERVAL_MS = 30_000L
    private const val PERSIST_BYTE_DELTA = 16L shl 20

    private val tracker = SessionTrafficTracker()
    private var preferences: SharedPreferences? = null
    private var initialized = false
    private var lastPersistedAt = 0L
    private var lastPersistedUplink = 0L
    private var lastPersistedDownlink = 0L

    @Synchronized
    fun initialize(context: Context, restoreActiveSession: Boolean): SessionTrafficTotals {
        if (preferences == null) {
            preferences = context.applicationContext.getSharedPreferences(
                PREFS_NAME,
                Context.MODE_PRIVATE,
            )
        }
        if (initialized) {
            if (!restoreActiveSession) {
                resetInternal(commit = true)
                lastPersistedAt = SystemClock.elapsedRealtime()
            }
            return tracker.totals()
        }
        initialized = true
        if (restoreActiveSession) {
            restoreFromDisk()
        } else {
            resetInternal(commit = true)
        }
        lastPersistedAt = SystemClock.elapsedRealtime()
        return tracker.totals()
    }

    @Synchronized
    fun observe(
        source: SessionTrafficSource,
        rawUplink: Long,
        rawDownlink: Long,
    ): SessionTrafficTotals {
        val totals = tracker.observe(source, rawUplink, rawDownlink)
        persistIfNeeded(SystemClock.elapsedRealtime())
        return totals
    }

    @Synchronized
    fun currentSource(): SessionTrafficSource? = tracker.currentSource()

    @Synchronized
    fun reset(context: Context): SessionTrafficTotals {
        if (preferences == null) {
            preferences = context.applicationContext.getSharedPreferences(
                PREFS_NAME,
                Context.MODE_PRIVATE,
            )
        }
        initialized = true
        resetInternal(commit = true)
        lastPersistedAt = SystemClock.elapsedRealtime()
        return tracker.totals()
    }

    @Synchronized
    fun totals(): SessionTrafficTotals = tracker.totals()

    @Synchronized
    fun flush() {
        if (!initialized) return
        persist(tracker.snapshot(), commit = true)
        lastPersistedAt = SystemClock.elapsedRealtime()
    }

    private fun restoreFromDisk() {
        val prefs = preferences ?: return
        val snapshot = if (prefs.getInt(KEY_VERSION, 0) == SNAPSHOT_VERSION) {
            SessionTrafficStateSnapshot(
                counters = SessionTrafficSnapshot(
                    lastUplink = prefs.getLong(KEY_LAST_UPLINK, -1L),
                    lastDownlink = prefs.getLong(KEY_LAST_DOWNLINK, -1L),
                    uplink = prefs.getLong(KEY_UPLINK, -1L),
                    downlink = prefs.getLong(KEY_DOWNLINK, -1L),
                ),
                source = prefs.getString(KEY_SOURCE, null)?.let { storedSource ->
                    SessionTrafficSource.entries.firstOrNull { it.name == storedSource }
                },
            )
        } else {
            SessionTrafficStateSnapshot(
                counters = SessionTrafficSnapshot(-1L, -1L, -1L, -1L),
                source = null,
            )
        }
        val totals = tracker.restore(snapshot)
        lastPersistedUplink = totals.uplink
        lastPersistedDownlink = totals.downlink
        if (!snapshot.counters.isValid || snapshot.source == null) {
            persist(tracker.snapshot(), commit = true)
        }
    }

    private fun resetInternal(commit: Boolean) {
        tracker.reset()
        lastPersistedUplink = 0L
        lastPersistedDownlink = 0L
        persist(tracker.snapshot(), commit)
    }

    private fun persistIfNeeded(now: Long) {
        val snapshot = tracker.snapshot()
        val elapsed = (now - lastPersistedAt).coerceAtLeast(0L)
        val enoughBytes = advancedBy(snapshot.counters.uplink, lastPersistedUplink) ||
            advancedBy(snapshot.counters.downlink, lastPersistedDownlink)
        if (elapsed < MIN_PERSIST_INTERVAL_MS ||
            (elapsed < PERSIST_INTERVAL_MS && !enoughBytes)
        ) {
            return
        }
        persist(snapshot, commit = false)
        lastPersistedAt = now
    }

    private fun persist(snapshot: SessionTrafficStateSnapshot, commit: Boolean) {
        val prefs = preferences ?: return
        val counters = snapshot.counters
        val editor = prefs.edit()
            .putInt(KEY_VERSION, SNAPSHOT_VERSION)
            .putLong(KEY_LAST_UPLINK, counters.lastUplink)
            .putLong(KEY_LAST_DOWNLINK, counters.lastDownlink)
            .putLong(KEY_UPLINK, counters.uplink)
            .putLong(KEY_DOWNLINK, counters.downlink)
        if (snapshot.source == null) {
            editor.remove(KEY_SOURCE)
        } else {
            editor.putString(KEY_SOURCE, snapshot.source.name)
        }
        if (commit) {
            if (!editor.commit()) {
                Log.w(TAG, "Session traffic snapshot commit returned false")
            }
        } else {
            editor.apply()
        }
        lastPersistedUplink = counters.uplink
        lastPersistedDownlink = counters.downlink
    }

    private fun advancedBy(current: Long, previous: Long): Boolean =
        current >= previous && current - previous >= PERSIST_BYTE_DELTA
}
