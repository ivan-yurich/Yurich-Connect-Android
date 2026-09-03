package com.tecclub.flutter_singbox.bg

internal class NetworkResetTracker<T> {
    private var currentNetwork: T? = null
    private var pendingRecovery = false

    @Synchronized
    fun markCurrent(network: T?) {
        currentNetwork = network
        pendingRecovery = false
    }

    @Synchronized
    fun onNetworkEvent(network: T?): Boolean {
        if (network == null) {
            currentNetwork = null
            return false
        }
        if (network == currentNetwork) {
            return false
        }
        currentNetwork = network
        pendingRecovery = true
        return true
    }

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
