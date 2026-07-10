/*******************************************************************************
 *                                                                             *
 *  Copyright (C) 2019 by Max Lv <max.c.lv@gmail.com>                          *
 *  Copyright (C) 2019 by Mygod Studio <contact-shadowsocks-android@mygod.be>  *
 *                                                                             *
 *  This program is free software: you can redistribute it and/or modify       *
 *  it under the terms of the GNU General Public License as published by       *
 *  the Free Software Foundation, either version 3 of the License, or          *
 *  (at your option) any later version.                                        *
 *                                                                             *
 *  This program is distributed in the hope that it will be useful,            *
 *  but WITHOUT ANY WARRANTY; without even the implied warranty of             *
 *  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the              *
 *  GNU General Public License for more details.                               *
 *                                                                             *
 *  You should have received a copy of the GNU General Public License          *
 *  along with this program. If not, see <http://www.gnu.org/licenses/>.       *
 *                                                                             *
 *******************************************************************************/

package com.tecclub.flutter_singbox.bg

import android.annotation.TargetApi
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import com.tecclub.flutter_singbox.Application
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.launch

object DefaultNetworkListener {
    private sealed class NetworkMessage {
        class Start(val key: Any, val listener: (Network?) -> Unit) : NetworkMessage() {
            val response = CompletableDeferred<Unit>()
        }

        class Get : NetworkMessage() {
            val response = CompletableDeferred<Network>()
        }

        class Stop(val key: Any) : NetworkMessage() {
            val response = CompletableDeferred<Unit>()
        }

        class Put(val network: Network) : NetworkMessage()
        class Update(val network: Network) : NetworkMessage()
        class Lost(val network: Network) : NetworkMessage()
    }

    private const val TAG = "DefaultNetworkListener"
    private val listenerScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val networkMessages = Channel<NetworkMessage>(Channel.UNLIMITED)

    init {
        listenerScope.launch {
            consumeNetworkMessages()
        }
    }

    private suspend fun consumeNetworkMessages() {
        val listeners = mutableMapOf<Any, (Network?) -> Unit>()
        var network: Network? = null
        val pendingRequests = arrayListOf<NetworkMessage.Get>()
        for (message in networkMessages) {
            try {
                when (message) {
                    is NetworkMessage.Start -> {
                        if (listeners.isEmpty()) {
                            register()
                            if (fallback && Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                                network = Application.connectivity.activeNetwork
                            }
                        }
                        listeners[message.key] = message.listener
                        network?.let { notifyListener(message.listener, it) }
                        message.response.complete(Unit)
                    }

                    is NetworkMessage.Get -> {
                        check(listeners.isNotEmpty()) {
                            "Getting network without any listeners is not supported"
                        }
                        if (network == null) {
                            pendingRequests += message
                        } else {
                            message.response.complete(network)
                        }
                    }

                    is NetworkMessage.Stop -> {
                        if (listeners.remove(message.key) != null && listeners.isEmpty()) {
                            network = null
                            unregister()
                            val error = IllegalStateException("Default network listener stopped")
                            pendingRequests.forEach { it.response.completeExceptionally(error) }
                            pendingRequests.clear()
                        }
                        message.response.complete(Unit)
                    }

                    is NetworkMessage.Put -> {
                        network = message.network
                        pendingRequests.forEach { it.response.complete(message.network) }
                        pendingRequests.clear()
                        listeners.values.forEach { notifyListener(it, network) }
                    }

                    is NetworkMessage.Update -> if (network == message.network) {
                        listeners.values.forEach { notifyListener(it, network) }
                    }

                    is NetworkMessage.Lost -> if (network == message.network) {
                        network = null
                        listeners.values.forEach { notifyListener(it, null) }
                    }
                }
            } catch (error: Exception) {
                when (message) {
                    is NetworkMessage.Start -> message.response.completeExceptionally(error)
                    is NetworkMessage.Get -> message.response.completeExceptionally(error)
                    is NetworkMessage.Stop -> message.response.completeExceptionally(error)
                    else -> Log.e(TAG, "Network event processing failed", error)
                }
            }
        }
    }

    private fun notifyListener(listener: (Network?) -> Unit, network: Network?) {
        runCatching { listener(network) }
            .onFailure { Log.e(TAG, "Default network listener callback failed", it) }
    }

    suspend fun start(key: Any, listener: (Network?) -> Unit) {
        val message = NetworkMessage.Start(key, listener)
        networkMessages.send(message)
        message.response.await()
    }

    suspend fun get() = if (fallback) @TargetApi(23) {
        Application.connectivity.activeNetwork
            ?: error("missing default network") // failed to listen, return current if available
    } else NetworkMessage.Get().run {
        networkMessages.send(this)
        response.await()
    }

    suspend fun stop(key: Any) {
        val message = NetworkMessage.Stop(key)
        networkMessages.send(message)
        message.response.await()
    }

    // NB: this runs in ConnectivityThread, and this behavior cannot be changed until API 26
    private object Callback : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) {
            enqueueCallback(NetworkMessage.Put(network))
        }

        override fun onCapabilitiesChanged(
            network: Network,
            networkCapabilities: NetworkCapabilities
        ) {
            // it's a good idea to refresh capabilities
            enqueueCallback(NetworkMessage.Update(network))
        }

        override fun onLost(network: Network) {
            enqueueCallback(NetworkMessage.Lost(network))
        }
    }

    private fun enqueueCallback(message: NetworkMessage) {
        if (networkMessages.trySend(message).isFailure) {
            Log.w(TAG, "Dropping network callback because dispatcher is unavailable")
        }
    }

    @Volatile
    private var fallback = false
    private val request = NetworkRequest.Builder().apply {
        addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
        addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_RESTRICTED)
        if (Build.VERSION.SDK_INT == 23) {  // workarounds for OEM bugs
            removeCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)
            removeCapability(NetworkCapabilities.NET_CAPABILITY_CAPTIVE_PORTAL)
        }
    }.build()
    private val mainHandler = Handler(Looper.getMainLooper())

    /**
     * Unfortunately registerDefaultNetworkCallback is going to return VPN interface since Android P DP1:
     * https://android.googlesource.com/platform/frameworks/base/+/dda156ab0c5d66ad82bdcf76cda07cbc0a9c8a2e
     *
     * This makes doing a requestNetwork with REQUEST necessary so that we don't get ALL possible networks that
     * satisfies default network capabilities but only THE default network. Unfortunately, we need to have
     * android.permission.CHANGE_NETWORK_STATE to be able to call requestNetwork.
     *
     * Source: https://android.googlesource.com/platform/frameworks/base/+/2df4c7d/services/core/java/com/android/server/ConnectivityService.java#887
     */
    private fun register() {
        when (Build.VERSION.SDK_INT) {
            in 31..Int.MAX_VALUE -> @TargetApi(31) {
                Application.connectivity.registerBestMatchingNetworkCallback(
                    request,
                    Callback,
                    mainHandler
                )
            }

            in 28 until 31 -> @TargetApi(28) {  // we want REQUEST here instead of LISTEN
                Application.connectivity.requestNetwork(request, Callback, mainHandler)
            }

            in 26 until 28 -> @TargetApi(26) {
                Application.connectivity.registerDefaultNetworkCallback(Callback, mainHandler)
            }

            in 24 until 26 -> @TargetApi(24) {
                Application.connectivity.registerDefaultNetworkCallback(Callback)
            }

            else -> try {
                fallback = false
                Application.connectivity.requestNetwork(request, Callback)
            } catch (e: RuntimeException) {
                fallback =
                    true     // known bug on API 23: https://stackoverflow.com/a/33509180/2245107
            }
        }
    }

    private fun unregister() {
        runCatching {
            Application.connectivity.unregisterNetworkCallback(Callback)
        }
    }
}
