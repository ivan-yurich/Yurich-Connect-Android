package com.tecclub.flutter_singbox.bg

import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import androidx.annotation.RequiresApi

internal data class NativeNetworkSnapshot(
    val activeFlags: Int = -1,
    val trackedFlags: Int = -1,
    val sameNetwork: Int = -1,
) {
    fun physicalTransport(): String = transport(trackedFlags)

    companion object {
        const val PRESENT = 1
        const val CAPABILITIES_OBSERVED = 2
        const val VPN = 4
        const val WIFI = 8
        const val CELLULAR = 16
        const val INTERNET = 32
        const val VALIDATED = 64

        internal fun transport(flags: Int): String {
            if (flags < 0 || flags and PRESENT == 0) {
                return if (flags == 0) "none" else "unknown"
            }
            if (flags and CAPABILITIES_OBSERVED == 0) return "unknown"
            val wifi = flags and WIFI != 0
            val cellular = flags and CELLULAR != 0
            return when {
                wifi && cellular -> "multiple"
                wifi -> "wifi"
                cellular -> "cellular"
                else -> "other"
            }
        }

        @RequiresApi(23)
        fun capture(connectivity: ConnectivityManager, tracked: Network?): NativeNetworkSnapshot {
            val active = runCatching { connectivity.activeNetwork }
            return NativeNetworkSnapshot(
                activeFlags = active.fold({ flags(connectivity, it) }, { -1 }),
                trackedFlags = flags(connectivity, tracked),
                sameNetwork = if (active.isFailure) -1 else if (active.getOrNull() == tracked) 1 else 0,
            )
        }

        @RequiresApi(23)
        private fun flags(connectivity: ConnectivityManager, network: Network?): Int {
            if (network == null) return 0
            return runCatching {
                val caps = connectivity.getNetworkCapabilities(network) ?: return@runCatching PRESENT
                var bits = PRESENT or CAPABILITIES_OBSERVED
                if (caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN)) bits = bits or VPN
                if (caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)) bits = bits or WIFI
                if (caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR)) bits = bits or CELLULAR
                if (caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)) bits = bits or INTERNET
                if (caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)) bits = bits or VALIDATED
                bits
            }.getOrDefault(-1)
        }
    }
}
