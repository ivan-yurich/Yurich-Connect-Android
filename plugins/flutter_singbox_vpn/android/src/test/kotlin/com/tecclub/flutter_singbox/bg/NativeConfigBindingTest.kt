package com.tecclub.flutter_singbox.bg

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class NativeConfigBindingTest {
    @Test
    fun `cancelled startup cannot bind a newer generation`() {
        val fingerprint = "a".repeat(64)
        val binding = NativeConfigBinding(7, fingerprint)
        assertEquals(fingerprint, binding.forGeneration(7))
        assertNull(binding.forGeneration(8))
        assertNull(binding.forGeneration(6))
    }

    @Test
    fun `only full lowercase SHA256 fingerprints are exposed`() {
        for (value in listOf("", "unknown", "a".repeat(63), "A".repeat(64), "config=secret")) {
            assertNull(NativeConfigBinding(1, value).forGeneration(1))
        }
    }
}
