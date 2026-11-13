package com.tecclub.flutter_singbox.bg

import android.content.Context
import android.net.ConnectivityManager
import android.net.DnsResolver
import android.net.NetworkCapabilities
import android.os.Build
import android.os.CancellationSignal
import androidx.annotation.RequiresApi
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withTimeoutOrNull
import java.net.InetAddress
import kotlin.coroutines.resume

/** Observation only: no bindSocket, protect, network request or route changes. */
internal object DirectProbeNetworkGate {
    private val domain = Regex(
        "^(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\\.)+[a-z](?:[a-z0-9-]{0,61}[a-z0-9])?$",
        RegexOption.IGNORE_CASE,
    )
    private val localSuffixes = setOf("local", "localhost", "lan", "home", "internal", "test", "invalid", "onion")

    fun isProbeDomain(host: String): Boolean = host.length <= 253 && domain.matches(host) &&
        localSuffixes.none { it.equals(host.substringAfterLast('.'), ignoreCase = true) }

    fun allows(protection: Map<String, Any?>, physicalReady: Boolean, vpnPresent: Boolean): Boolean =
        physicalReady && !vpnPresent &&
            protection["supported"] == true && protection["known"] == true &&
            listOf("requested", "alwaysOn", "lockdown", "strictRuntime", "vpnActive")
                .all { protection[it] == false }

    @Suppress("DEPRECATION")
    suspend fun read(context: Context): String? {
        val protection = try {
            KillSwitchStatus.query(context)
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Exception) {
            return null
        }
        return runCatching {
            val manager = context.getSystemService(ConnectivityManager::class.java)
                ?: return null
            val network = manager.activeNetwork ?: return null
            val caps = manager.getNetworkCapabilities(network) ?: return null
            val physicalReady = caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN) &&
                caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) &&
                caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED) &&
                (caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) ||
                    caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) ||
                    caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET))
            val vpnPresent = manager.allNetworks.any {
                val visible = manager.getNetworkCapabilities(it) ?: return null
                visible.hasTransport(NetworkCapabilities.TRANSPORT_VPN)
            }
            if (!allows(protection, physicalReady, vpnPresent) || manager.activeNetwork != network) null
            else network.networkHandle.toString()
        }.getOrNull()
    }

    suspend fun resolve(context: Context, host: String, network: String): List<String>? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q || !isProbeDomain(host)) return null
        return withTimeoutOrNull(1_200L) {
            if (read(context) != network) return@withTimeoutOrNull null
            resolveOnDefaultNetwork(context, host)
        }
    }

    @RequiresApi(Build.VERSION_CODES.Q)
    private suspend fun resolveOnDefaultNetwork(context: Context, host: String): List<String>? =
        suspendCancellableCoroutine { continuation ->
            val signal = CancellationSignal()
            continuation.invokeOnCancellation { signal.cancel() }
            if (!continuation.isActive) return@suspendCancellableCoroutine
            fun finish(result: List<String>?) {
                if (continuation.isActive) continuation.resume(result)
            }
            try {
                // Null means Android's default DNS route, not a forced physical Network.
                DnsResolver.getInstance().query(null, host, DnsResolver.FLAG_NO_RETRY,
                    context.mainExecutor, signal, object : DnsResolver.Callback<List<InetAddress>> {
                        override fun onAnswer(answer: List<InetAddress>, rcode: Int) =
                            finish(if (rcode == 0) answer.mapNotNull { it.hostAddress } else null)

                        override fun onError(error: DnsResolver.DnsException) = finish(null)
                    })
            } catch (_: Exception) {
                finish(null)
            }
        }
}
