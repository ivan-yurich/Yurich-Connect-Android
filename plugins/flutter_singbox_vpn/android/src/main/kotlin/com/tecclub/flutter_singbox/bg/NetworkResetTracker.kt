package com.tecclub.flutter_singbox.bg

internal data class RuntimeNetworkTransition(val changed: Boolean, val resetRuntime: Boolean)

internal class NetworkResetTracker<T> {
    private var currentNetwork: T? = null
    private var pendingRecovery = false

    @Synchronized
    fun isDifferentNetwork(network: T?): Boolean = currentNetwork != network

    @Synchronized
    fun markCurrent(network: T?) {
        currentNetwork = network
        pendingRecovery = false
    }

    @Synchronized
    fun observeNetwork(network: T?): RuntimeNetworkTransition {
        val changed = currentNetwork != network
        if (network == null) {
            currentNetwork = null
            return RuntimeNetworkTransition(changed, false)
        }
        if (!changed) {
            return RuntimeNetworkTransition(false, false)
        }
        currentNetwork = network
        pendingRecovery = true
        return RuntimeNetworkTransition(true, true)
    }

    fun onNetworkEvent(network: T?): Boolean = observeNetwork(network).resetRuntime

    @Synchronized
    fun consumeRecoveryAllowance(): Boolean {
        if (!pendingRecovery) {
            return false
        }
        pendingRecovery = false
        return true
    }

    @Synchronized
    fun hasRecoveryAllowance(): Boolean = pendingRecovery

    @Synchronized
    fun clear() {
        currentNetwork = null
        pendingRecovery = false
    }
}
