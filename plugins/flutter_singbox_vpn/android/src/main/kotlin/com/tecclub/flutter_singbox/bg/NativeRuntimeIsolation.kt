package com.tecclub.flutter_singbox.bg

import java.io.File

internal data class NativeRuntimeSnapshot(
    val libboxLoaded: Boolean,
    val libgojniLoaded: Boolean,
) {
    fun hasUnexpectedRuntime(expected: VpnRuntimeCore): Boolean = when (expected) {
        VpnRuntimeCore.SingBox -> libgojniLoaded
        VpnRuntimeCore.Xray -> libboxLoaded
    }
}

internal object NativeRuntimeIsolation {
    fun inspect(lines: Sequence<String>): NativeRuntimeSnapshot {
        var libboxLoaded = false
        var libgojniLoaded = false
        for (line in lines) {
            libboxLoaded = libboxLoaded || line.contains("/libbox.so")
            libgojniLoaded = libgojniLoaded || line.contains("/libgojni.so")
            if (libboxLoaded && libgojniLoaded) {
                break
            }
        }
        return NativeRuntimeSnapshot(
            libboxLoaded = libboxLoaded,
            libgojniLoaded = libgojniLoaded,
        )
    }

    fun inspectCurrentProcess(): NativeRuntimeSnapshot? = runCatching {
        File("/proc/self/maps").useLines { lines -> inspect(lines) }
    }.getOrNull()

    fun requireIsolated(expected: VpnRuntimeCore): NativeRuntimeSnapshot? {
        val snapshot = inspectCurrentProcess() ?: return null
        check(!snapshot.hasUnexpectedRuntime(expected)) {
            "Unexpected Go runtime loaded for ${expected.name}"
        }
        return snapshot
    }
}
