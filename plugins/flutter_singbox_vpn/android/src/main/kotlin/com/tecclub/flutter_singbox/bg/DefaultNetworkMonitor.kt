package com.tecclub.flutter_singbox.bg

import android.net.Network
import android.os.Build
import android.util.Log
import com.tecclub.flutter_singbox.Application
import io.nekohasekai.libbox.InterfaceUpdateListener
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.net.NetworkInterface
import java.util.concurrent.atomic.AtomicLong

object DefaultNetworkMonitor {
    private const val TAG = "DefaultNetworkMonitor"
    private const val INTERFACE_RESOLVE_ATTEMPTS = 10
    private const val INTERFACE_RETRY_DELAY_MS = 60L
    private val monitorScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val updateGeneration = AtomicLong(0)

    @Volatile
    var defaultNetwork: Network? = null

    @Volatile
    private var listener: InterfaceUpdateListener? = null

    @Volatile
    private var networkChangeObserver: ((Network?) -> Unit)? = null

    suspend fun start() {
        Log.d(TAG, "Starting network monitor")
        defaultNetwork = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            Application.connectivity.activeNetwork.also {
                Log.d(TAG, "Pre-start active network: $it")
            }
        } else {
            null
        }

        DefaultNetworkListener.start(this) {
            Log.d(TAG, "Network changed callback: $it")
            defaultNetwork = it
            scheduleDefaultInterfaceUpdate(it)
            runCatching { networkChangeObserver?.invoke(it) }
                .onFailure { error -> Log.e(TAG, "Network change observer failed", error) }
        }

        if (defaultNetwork == null && Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
            defaultNetwork = DefaultNetworkListener.get().also {
                Log.d(TAG, "Got network from listener: $it")
            }
        }
        if (listener != null) {
            scheduleDefaultInterfaceUpdate(defaultNetwork)
        }
        Log.d(TAG, "Network monitor started, defaultNetwork=$defaultNetwork")
    }

    suspend fun stop() {
        Log.d(TAG, "Stopping network monitor")
        resetState()
        DefaultNetworkListener.stop(this)
    }

    fun stopAsync() {
        Log.d(TAG, "Scheduling network monitor stop")
        resetState()
        monitorScope.launch {
            runCatching { DefaultNetworkListener.stop(DefaultNetworkMonitor) }
                .onFailure { Log.w(TAG, "Asynchronous network monitor stop failed", it) }
        }
    }

    suspend fun require(): Network {
        val network = defaultNetwork
        if (network != null) {
            return network
        }
        return DefaultNetworkListener.get()
    }

    fun setListener(listener: InterfaceUpdateListener?) {
        Log.d(TAG, "setListener called, listener=${listener != null}, defaultNetwork=$defaultNetwork")
        this.listener = listener
        if (listener == null) {
            updateGeneration.incrementAndGet()
            return
        }
        scheduleDefaultInterfaceUpdate(defaultNetwork)
    }

    fun setNetworkChangeObserver(observer: ((Network?) -> Unit)?) {
        networkChangeObserver = observer
    }

    private fun scheduleDefaultInterfaceUpdate(newNetwork: Network?) {
        val expectedListener = listener ?: return
        val generation = updateGeneration.incrementAndGet()
        monitorScope.launch {
            val (interfaceName, interfaceIndex) = resolveInterface(newNetwork, generation)
            if (generation != updateGeneration.get() || listener !== expectedListener) {
                return@launch
            }
            runCatching {
                expectedListener.updateDefaultInterface(
                    interfaceName,
                    interfaceIndex,
                    false,
                    false,
                )
            }.onSuccess {
                Log.d(TAG, "Default interface updated: $interfaceName/$interfaceIndex")
            }.onFailure {
                Log.e(TAG, "Default interface update failed", it)
            }
        }
    }

    private suspend fun resolveInterface(
        network: Network?,
        generation: Long,
    ): Pair<String, Int> {
        if (network == null) {
            return "" to -1
        }

        repeat(INTERFACE_RESOLVE_ATTEMPTS) { attempt ->
            if (generation != updateGeneration.get()) {
                return "" to -1
            }
            val interfaceName = runCatching {
                Application.connectivity.getLinkProperties(network)?.interfaceName
            }.onFailure {
                Log.w(TAG, "Unable to read link properties on attempt ${attempt + 1}", it)
            }.getOrNull()
            if (!interfaceName.isNullOrBlank()) {
                val networkInterface = runCatching {
                    NetworkInterface.getByName(interfaceName)
                }.onFailure {
                    Log.w(TAG, "Unable to resolve $interfaceName on attempt ${attempt + 1}", it)
                }.getOrNull()
                if (networkInterface != null) {
                    return interfaceName to networkInterface.index
                }
            }
            delay(INTERFACE_RETRY_DELAY_MS)
        }
        Log.e(TAG, "Failed to resolve default interface after $INTERFACE_RESOLVE_ATTEMPTS attempts")
        return "" to -1
    }

    private fun resetState() {
        listener = null
        networkChangeObserver = null
        defaultNetwork = null
        updateGeneration.incrementAndGet()
    }
}
