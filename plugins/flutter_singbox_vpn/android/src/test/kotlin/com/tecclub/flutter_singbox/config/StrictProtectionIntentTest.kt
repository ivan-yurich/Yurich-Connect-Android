package com.tecclub.flutter_singbox.config

import kotlin.test.*

class StrictProtectionIntentTest {
    @Test fun neverConfiguredStoreCanRemainOrdinary() {
        assertFalse(StrictProtectionIntent.missingRead(false, false, false))
    }

    @Test fun interruptedFirstCommitKeepsStrictIntent() {
        assertTrue(StrictProtectionIntent.missingRead(false, true, false))
    }

    @Test fun survivingBackupKeepsStrictIntent() {
        assertTrue(StrictProtectionIntent.missingRead(false, false, true))
    }

    @Test fun unreadableExistingBaseKeepsStrictIntent() {
        assertTrue(StrictProtectionIntent.missingRead(true, false, false))
    }

    @Test fun explicitStoredValuesRoundTrip() {
        assertTrue(StrictProtectionIntent.decode("1"))
        assertFalse(StrictProtectionIntent.decode("0"))
    }

    @Test fun malformedIntentDoesNotDecodeAsDisabled() {
        for (value in listOf("", "true", "false", "2", "01", "1\u0000")) {
            assertFailsWith<IllegalStateException> { StrictProtectionIntent.decode(value) }
        }
    }

    @Test fun missingTunObservationCannotDowngradePersistedStrictIntent() {
        assertTrue(StrictProtectionIntent.required(true, false, false))
    }

    @Test fun systemStartProtectsEvenBeforeFirstTunExists() {
        assertTrue(StrictProtectionIntent.required(false, true, false))
    }

    @Test fun liveSystemProtectionUpgradesAnOrdinaryStart() {
        assertTrue(StrictProtectionIntent.required(false, false, true))
    }

    @Test fun explicitNormalIntentCanResumeOnceSystemProtectionIsOff() {
        assertFalse(StrictProtectionIntent.required(false, false, false))
    }
}
