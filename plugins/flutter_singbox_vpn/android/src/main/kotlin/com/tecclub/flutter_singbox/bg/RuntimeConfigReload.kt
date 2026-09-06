package com.tecclub.flutter_singbox.bg

import android.content.Intent

internal object RuntimeConfigReload {
    fun attach(intent: Intent, config: String): Intent {
        require(config.isNotBlank() && config != "{}")
        intent.putExtra(BoxService.EXTRA_CONFIG_CONTENT, config)
        return intent
    }

    fun cacheReceived(intent: Intent, cache: (String) -> Boolean): Boolean {
        val config = intent.getStringExtra(BoxService.EXTRA_CONFIG_CONTENT)
            ?.takeIf { it.isNotBlank() && it != "{}" } ?: return false
        return cache(config)
    }
}
