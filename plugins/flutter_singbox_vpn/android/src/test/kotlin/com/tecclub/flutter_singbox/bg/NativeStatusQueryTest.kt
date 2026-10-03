package com.tecclub.flutter_singbox.bg

import com.tecclub.flutter_singbox.constant.Status
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class NativeStatusQueryTest {
    private val fingerprint = "a".repeat(64)

    @Test
    fun readyRequiresTheExpectedRuntimeConfig() {
        val code = NativeStatusQuery.encode(Status.Started)
        assertEquals(Status.Started, NativeStatusQuery.decode(code, fingerprint, fingerprint))
        for (actual in listOf(null, "", "invalid", "b".repeat(64))) {
            assertEquals(Status.Starting, NativeStatusQuery.decode(code, actual, fingerprint))
        }
        assertEquals(Status.Starting, NativeStatusQuery.decode(code, fingerprint, null))
    }

    @Test
    fun lifecycleStatesDoNotRequireAnAlreadyLoadedConfig() {
        for (status in listOf(Status.Stopped, Status.Starting, Status.Stopping)) {
            assertEquals(status, NativeStatusQuery.decode(NativeStatusQuery.encode(status), null, null))
        }
    }

    @Test
    fun missingAndInvalidResponsesAreUnknown() {
        for (code in listOf(0, -1, 99, Int.MIN_VALUE, Int.MAX_VALUE)) {
            assertNull(NativeStatusQuery.decode(code, fingerprint, fingerprint))
        }
    }

    @Test
    fun invalidMatchingValuesCannotQualifyABroadcast() {
        assertFalse(NativeStatusQuery.matchesConfig("invalid", "invalid"))
        assertFalse(NativeStatusQuery.matchesConfig(null, null))
        assertTrue(NativeStatusQuery.matchesConfig(fingerprint, fingerprint))
    }

    @Test
    fun configHashUsesStableUtf8Bytes() {
        assertEquals("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
            NativeConfigBinding.fingerprint("abc"))
        assertEquals("b35cf54b7bb9a7ead8d1daa6efe32ae12628257caaf78fd795f5a8cce3439a0e",
            NativeConfigBinding.fingerprint("{\"label\":\"\u0420\"}"))
        assertFalse(NativeConfigBinding.fingerprint("{}") == NativeConfigBinding.fingerprint("{ }"))
    }
}
