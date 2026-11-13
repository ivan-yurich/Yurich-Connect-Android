package com.tecclub.flutter_singbox.bg

internal enum class DefaultNetworkTransition { Changed, Validated }

/** Coalesce capability bursts but retain a newly validated path on the same handle. */
internal class DefaultNetworkTransitionTracker<T> {
    private var observed = false
    private var current: T? = null
    private var validated = false

    fun observe(network: T?, physicallyValidated: Boolean?): DefaultNetworkTransition? {
        val nextValidated = network != null && physicallyValidated == true
        if (!observed || network != current) {
            observed = true
            current = network
            validated = nextValidated
            return DefaultNetworkTransition.Changed
        }
        if (network == null || physicallyValidated == null) return null
        val becameValidated = nextValidated && !validated
        validated = nextValidated
        return if (becameValidated) DefaultNetworkTransition.Validated else null
    }
}
