package com.tecclub.flutter_singbox.bg

import kotlin.test.*

class NativeProtectionQueryTest {
    private val flags = mapOf("alwaysOn" to true, "lockdown" to true,
        "strictRuntime" to true, "vpnActive" to true, "tunOpen" to true)

    @Test fun absentOrIncompleteRuntimeRemainsUnknown() {
        assertNull(NativeProtectionQuery.decode(0, flags))
        assertNull(NativeProtectionQuery.decode(1, null))
        for (key in flags.keys) assertNull(NativeProtectionQuery.decode(1, flags - key))
    }

    @Test fun completeLiveReplyPreservesBothStrictAndNonStrictStates() {
        assertEquals(flags, NativeProtectionQuery.decode(1, flags))
        val nonStrict = flags + ("strictRuntime" to false)
        assertEquals(nonStrict, NativeProtectionQuery.decode(1, nonStrict))
    }

    @Test fun onlyWhitelistedBooleanFieldsLeaveTheRuntime() {
        assertEquals(flags, NativeProtectionQuery.decode(1, flags + ("unexpected" to true)))
    }
}
