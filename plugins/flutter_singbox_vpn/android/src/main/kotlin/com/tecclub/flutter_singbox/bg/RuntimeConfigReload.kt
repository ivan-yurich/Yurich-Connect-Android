package com.tecclub.flutter_singbox.bg

import android.content.Intent
import com.tecclub.flutter_singbox.config.RuntimeTlsPolicy

internal object RuntimeConfigReload {
    fun attach(intent: Intent, config: String): Intent {
        require(config.isNotBlank() && config != "{}")
        require(RuntimeTlsPolicy.validationError(config) == null) { RuntimeTlsPolicy.UNSUPPORTED_PIN }
        intent.putExtra(BoxService.EXTRA_CONFIG_CONTENT, config)
        intent.putExtra(RuntimeTlsPolicy.INTENT_REVISION_EXTRA, RuntimeTlsPolicy.CURRENT_REVISION)
        return intent
    }

    fun cacheReceived(intent: Intent, cache: (String) -> Boolean): Boolean {
        val config = intent.getStringExtra(BoxService.EXTRA_CONFIG_CONTENT)
            ?.takeIf { it.isNotBlank() && it != "{}" } ?: return false
        val revision = intent.getIntExtra(RuntimeTlsPolicy.INTENT_REVISION_EXTRA, 0)
        if (RuntimeTlsPolicy.validationError(config, revision) != null) return false
        return cache(config)
    }
}
