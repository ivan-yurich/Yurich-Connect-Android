package com.tecclub.flutter_singbox.bg

import com.tecclub.flutter_singbox.session.VpnSessionPhase
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class NativeSoakSnapshotTest {
    private val snapshot = NativeSoakSnapshot(
        42, 100, 120, 3, VpnSessionPhase.Connected, true,
        VpnRuntimeCore.Xray, true, 1024, 2048,
    )

    @Test
    fun `response is bounded and contains only observation fields`() {
        assertEquals(
            "v=1 request=q_1 pid=42 instance=100 elapsed=120 generation=3 " +
                "phase=Connected desired=true runtime=xray tun=true tx=1024 rx=2048 source=uid",
            snapshot.encode("q_1"),
        )
    }

    @Test
    fun `version two adds only explicit network flags and preserves version one`() {
        val extended = snapshot.copy(network = NativeNetworkSnapshot(107, 1, 0))
        assertTrue(extended.encode("q2", 2).endsWith("activeNet=107 trackedNet=1 sameNet=0"))
        assertEquals(snapshot.encode("q1"), extended.encode("q1"))
        assertFailsWith<IllegalArgumentException> { snapshot.encode("q1", 4) }
    }

    @Test
    fun `version three exposes only a validated fingerprint and preserves older formats`() {
        val extended = snapshot.copy(configFingerprint = "a".repeat(64))
        assertEquals(snapshot.encode("q1", 1), extended.encode("q1", 1))
        assertEquals(snapshot.encode("q2", 2), extended.encode("q2", 2))
        assertTrue(extended.encode("q3", 3).endsWith(" config=${"a".repeat(64)}"))
        assertTrue(snapshot.encode("q3", 3).endsWith(" config=unknown"))
        assertFailsWith<IllegalArgumentException> {
            snapshot.copy(configFingerprint = "secret config=value").encode("q3", 3)
        }
    }

    @Test
    fun `unsupported counters and stopped state stay explicit`() {
        val encoded = snapshot.copy(
            phase = VpnSessionPhase.Stopped, desiredRunning = false,
            runtime = null, tunOpen = false, uidTxBytes = -1, uidRxBytes = -1,
        ).encode("q2")
        assertTrue(encoded.contains("phase=Stopped desired=false runtime=unknown tun=false tx=-1 rx=-1"))
    }

    @Test
    fun `request cannot inject fields or unbounded text`() {
        for (value in listOf(null, "", "q phase=Connected", "q\nfoo", "q\"", "x".repeat(65))) {
            assertFalse(NativeSoakSnapshot.validRequest(value))
        }
        assertTrue(NativeSoakSnapshot.validRequest("x".repeat(64)))
        assertFailsWith<IllegalArgumentException> { snapshot.encode("q injection") }
    }
}
