package com.tecclub.flutter_singbox.bg

import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class NativeRuntimeIsolationTest {
    @Test
    fun `sing-box process rejects an Xray Go runtime`() {
        val snapshot = NativeRuntimeIsolation.inspect(
            sequenceOf(
                "7aa000-7ab000 r-xp /data/app/lib/arm64/libbox.so",
                "7ac000-7ad000 r-xp /data/app/lib/arm64/libgojni.so",
            ),
        )

        assertTrue(snapshot.libboxLoaded)
        assertTrue(snapshot.libgojniLoaded)
        assertTrue(snapshot.hasUnexpectedRuntime(VpnRuntimeCore.SingBox))
    }

    @Test
    fun `Xray process accepts only libgojni`() {
        val snapshot = NativeRuntimeIsolation.inspect(
            sequenceOf("7ac000-7ad000 r-xp /data/app/lib/arm64/libgojni.so"),
        )

        assertFalse(snapshot.libboxLoaded)
        assertTrue(snapshot.libgojniLoaded)
        assertFalse(snapshot.hasUnexpectedRuntime(VpnRuntimeCore.Xray))
    }

    @Test
    fun `sing-box process accepts only libbox`() {
        val snapshot = NativeRuntimeIsolation.inspect(
            sequenceOf("7aa000-7ab000 r-xp /data/app/lib/arm64/libbox.so"),
        )

        assertTrue(snapshot.libboxLoaded)
        assertFalse(snapshot.libgojniLoaded)
        assertFalse(snapshot.hasUnexpectedRuntime(VpnRuntimeCore.SingBox))
    }
}
