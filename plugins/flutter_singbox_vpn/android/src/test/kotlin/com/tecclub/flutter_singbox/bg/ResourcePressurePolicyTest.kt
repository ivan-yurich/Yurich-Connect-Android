package com.tecclub.flutter_singbox.bg

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class ResourcePressurePolicyTest {
    @Test
    fun `single critical sample does not restart a healthy process`() {
        val state = ResourcePressurePolicy.observed(ResourcePressureState(), 1_024)
        assertEquals(1, state.consecutiveCriticalSamples)
        assertFalse(ResourcePressurePolicy.shouldRestart(state, 1_024))
    }

    @Test
    fun `two critical samples request containment restart`() {
        var state = ResourcePressurePolicy.observed(ResourcePressureState(), 1_024)
        state = ResourcePressurePolicy.observed(state, 1_100)
        assertTrue(ResourcePressurePolicy.shouldRestart(state, 1_100))
    }

    @Test
    fun `recovery below threshold resets confirmation and emergency is immediate`() {
        var state = ResourcePressurePolicy.observed(ResourcePressureState(), 2_000)
        state = ResourcePressurePolicy.observed(state, 200)
        assertEquals(ResourcePressureState(), state)
        assertTrue(ResourcePressurePolicy.shouldRestart(state, 8_192))
    }
}
