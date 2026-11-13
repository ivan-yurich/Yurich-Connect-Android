package com.tecclub.flutter_singbox.xray

import android.content.Context
import android.net.ConnectivityManager
import android.net.DnsResolver
import android.net.Network
import android.net.NetworkCapabilities
import android.os.Build
import android.os.CancellationSignal
import com.tecclub.flutter_singbox.bg.DefaultNetworkMonitor
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.asExecutor
import kotlinx.coroutines.runInterruptible
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withTimeoutOrNull
import java.net.Inet4Address
import java.net.InetAddress
import java.util.concurrent.atomic.AtomicBoolean

/** Bootstrap on a physical Network, before TUN. No process-wide DNS changes. */
internal object XrayBootstrapResolver {
    suspend fun resolve(context: Context, config: String): String {
        val plan = XrayBootstrapPlan.parse(config)
        val host = plan.hostname ?: return config
        val manager = context.getSystemService(ConnectivityManager::class.java)
        fun physical(network: Network?): Boolean {
            val caps = network?.let { manager.getNetworkCapabilities(it) } ?: return false
            return caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) &&
                !caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN)
        }
        val candidates = listOfNotNull(DefaultNetworkMonitor.defaultNetwork, manager.activeNetwork) + manager.allNetworks
        val networks = candidates.distinct().filter(::physical)
        val network = networks.firstOrNull { manager.getNetworkCapabilities(it)?.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED) == true }
            ?: networks.firstOrNull() ?: error("Xray upstream DNS bootstrap: physical network unavailable")
        val answers = try { withTimeoutOrNull(6_000L) {
            if (Build.VERSION.SDK_INT >= 29) {
                suspendCancellableCoroutine<List<InetAddress>> { continuation ->
                    val signal = CancellationSignal()
                    val finished = AtomicBoolean()
                    continuation.invokeOnCancellation { finished.set(true); signal.cancel() }
                    val callback = object : DnsResolver.Callback<Collection<InetAddress>> {
                        override fun onAnswer(answer: Collection<InetAddress>, rcode: Int) {
                            if (!finished.compareAndSet(false, true)) return
                            if (rcode == 0 && answer.isNotEmpty()) continuation.resumeWith(Result.success(answer.toList()))
                            else continuation.resumeWith(Result.failure(IllegalStateException("Xray upstream DNS bootstrap failed")))
                        }
                        override fun onError(error: DnsResolver.DnsException) {
                            if (finished.compareAndSet(false, true)) continuation.resumeWith(Result.failure(IllegalStateException("Xray upstream DNS bootstrap failed")))
                        }
                    }
                    try { DnsResolver.getInstance().query(network, host, DnsResolver.FLAG_NO_RETRY, Dispatchers.IO.asExecutor(), signal, callback) }
                    catch (_: Exception) {
                        if (finished.compareAndSet(false, true)) continuation.resumeWith(Result.failure(IllegalStateException("Xray upstream DNS bootstrap failed")))
                    }
                }
            } else {
                runInterruptible(Dispatchers.IO) { network.getAllByName(host).toList() }
            }
        } ?: error("Xray upstream DNS bootstrap timed out") }
        catch (cancelled: CancellationException) { throw cancelled }
        catch (_: Exception) { error("Xray upstream DNS bootstrap failed") }
        val answer = answers.firstOrNull { it is Inet4Address } ?: answers.firstOrNull()
            ?: error("Xray upstream DNS bootstrap: empty answer")
        return plan.withAddress(requireNotNull(answer.hostAddress))
    }
}
