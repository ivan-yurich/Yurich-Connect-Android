package com.tecclub.flutter_singbox.bg

import android.content.Context
import android.content.SharedPreferences
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import org.mockito.ArgumentMatchers.anyInt
import org.mockito.ArgumentMatchers.anyLong
import org.mockito.ArgumentMatchers.anyString
import org.mockito.ArgumentMatchers.isNull
import org.mockito.Mockito.`when`
import org.mockito.Mockito.mock

class WatchdogRecoveryStoreTest {
    private val values = mutableMapOf<String, Any>()
    private val staged = mutableMapOf<String, Any>()
    private var commitSucceeds = true
    private val context = mock(Context::class.java)
    private val prefs = mock(SharedPreferences::class.java)
    private val editor = mock(SharedPreferences.Editor::class.java)

    init {
        `when`(context.getSharedPreferences(anyString(), anyInt())).thenAnswer {
            assertEquals("watchdog_recovery", it.arguments[0])
            prefs
        }
        `when`(prefs.getLong(anyString(), anyLong())).thenAnswer { values[it.arguments[0]] ?: it.arguments[1] }
        `when`(prefs.getInt(anyString(), anyInt())).thenAnswer { values[it.arguments[0]] ?: it.arguments[1] }
        `when`(prefs.getString(anyString(), isNull())).thenAnswer { values[it.arguments[0]] }
        `when`(prefs.edit()).thenAnswer { staged.clear(); editor }
        `when`(editor.putString(anyString(), anyString())).thenAnswer {
            staged[it.arguments[0] as String] = it.arguments[1] as String; editor
        }
        `when`(editor.putLong(anyString(), anyLong())).thenAnswer {
            staged[it.arguments[0] as String] = it.arguments[1] as Long; editor
        }
        `when`(editor.putInt(anyString(), anyInt())).thenAnswer {
            staged[it.arguments[0] as String] = it.arguments[1] as Int; editor
        }
        `when`(editor.commit()).thenAnswer {
            if (commitSucceeds) values.putAll(staged)
            commitSucceeds
        }
    }

    @Test fun `persisted budget restores all counters after process recreation`() {
        val state = WatchdogRecoveryState(100_000, 4, 110_000, 120_000)
        WatchdogRecoveryStore.write(context, "a".repeat(64), state)
        assertEquals(state, WatchdogRecoveryStore.read(context, "a".repeat(64), 130_000))
    }

    @Test fun `different config or reboot does not inherit stale backoff`() {
        WatchdogRecoveryStore.write(context, "a".repeat(64), WatchdogRecoveryState(100_000, 5))
        assertEquals(WatchdogRecoveryState(), WatchdogRecoveryStore.read(context, "b".repeat(64), 130_000))
        assertEquals(WatchdogRecoveryState(), WatchdogRecoveryStore.read(context, "a".repeat(64), 1000))
        values["boot"] = 42
        assertEquals(WatchdogRecoveryState(), WatchdogRecoveryStore.read(context, "a".repeat(64), 130_000))
    }

    @Test fun `failed commit does not replace the previous restart budget`() {
        val state = WatchdogRecoveryState(100_000, 2)
        WatchdogRecoveryStore.write(context, "a".repeat(64), state)
        commitSucceeds = false
        assertFalse(WatchdogRecoveryStore.write(context, "a".repeat(64), WatchdogRecoveryState(200_000, 3)))
        assertEquals(state, WatchdogRecoveryStore.read(context, "a".repeat(64), 210_000))
    }
}
