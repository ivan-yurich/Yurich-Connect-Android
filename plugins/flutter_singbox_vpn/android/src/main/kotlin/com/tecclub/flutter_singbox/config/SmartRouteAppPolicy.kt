package com.tecclub.flutter_singbox.config

import com.tecclub.flutter_singbox.bg.NativeConfigBinding
import kotlinx.serialization.json.*

/** The binding is to the managed config actually saved. */
internal data class SmartRouteAppSettings(
    val selected: List<String> = emptyList(),
    val managedFingerprint: String? = null,
    val followCatalogDefaults: Boolean = false,
)

internal object SmartRouteAppPolicy {
    const val MAX_CANDIDATES = 128
    private val packagePattern = Regex("""[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+""")
    private val generalPurposeBrowsers = setOf(
        "com.android.chrome", "com.microsoft.emmx", "org.mozilla.firefox", "com.opera.browser",
        "ru.yandex.browser", "com.yandex.browser", "com.yandex.browser.beta",
        "com.yandex.browser.alpha", "com.yandex.browser.lite", "com.yandex.searchapp",
        "ru.yandex.searchplugin",
    )

    fun validPackage(packageId: String): Boolean =
        packageId.length <= 255 && packagePattern.matches(packageId)

    fun eligibleCatalogPackage(packageId: String): Boolean =
        validPackage(packageId) && packageId !in generalPurposeBrowsers

    fun selection(requested: Iterable<*>, verified: Set<String>): List<String> =
        requested.filterIsInstance<String>()
            .filter { it in verified && eligibleCatalogPackage(it) }
            .distinct().sorted().take(MAX_CANDIDATES)

    // Snapshot the current catalog: an update must not select new apps for an
    // existing user, even when the initial selection was not edited by hand.
    fun installDefaults(verified: Set<String>) =
        SmartRouteAppSettings(selected = selection(verified, verified))

    fun effectiveSelection(settings: SmartRouteAppSettings, verified: Set<String>): List<String> =
        selection(if (settings.followCatalogDefaults) verified else settings.selected, verified)

    fun applicable(
        settings: SmartRouteAppSettings,
        runtimeFingerprint: String?,
        strictOrLockdown: Boolean,
        protectionSupported: Boolean,
        legacyAppModeEnabled: Boolean,
        verified: Set<String>,
        isEligible: (String) -> Boolean,
    ): List<String> {
        if (strictOrLockdown || !protectionSupported || legacyAppModeEnabled ||
            runtimeFingerprint == null || !NativeConfigBinding.isFingerprint(runtimeFingerprint) ||
            runtimeFingerprint != settings.managedFingerprint
        ) return emptyList()
        return effectiveSelection(settings, verified).filter(isEligible)
    }

    fun decode(record: String, verified: Set<String>): SmartRouteAppSettings = try {
        val root = Json.parseToJsonElement(record).jsonObject
        val version = root["version"]?.jsonPrimitive?.intOrNull
        require(version == 1 || version == 2)
        require(root["version"] == JsonPrimitive(version))
        if (version == 2) require(
            root.keys.all { it in setOf("version", "selectionMode", "selected", "managedFingerprint") },
        )
        val mode = if (version == 1) "custom" else {
            val value = root.getValue("selectionMode").jsonPrimitive
            require(value.isString && value.content in setOf("catalog", "custom"))
            value.content
        }
        val values = root.getValue("selected").jsonArray
        require(values.size <= MAX_CANDIDATES)
        require(mode != "catalog" || values.isEmpty())
        val selected = values.map {
            require(it is JsonPrimitive && it.isString)
            it.content
        }
        val fingerprint = root["managedFingerprint"]?.jsonPrimitive?.contentOrNull
        require(fingerprint == null || NativeConfigBinding.isFingerprint(fingerprint))
        // A v1 empty list could mean that the user deliberately chose none.
        // Treat it as a saved choice instead of silently routing more apps directly.
        SmartRouteAppSettings(selection(selected, verified), fingerprint, mode == "catalog")
    } catch (_: Exception) {
        SmartRouteAppSettings()
    }

    fun encode(settings: SmartRouteAppSettings): String = buildJsonObject {
        put("version", 2)
        put("selectionMode", if (settings.followCatalogDefaults) "catalog" else "custom")
        put("selected", JsonArray(settings.selected.map(::JsonPrimitive)))
        settings.managedFingerprint?.let { put("managedFingerprint", it) }
    }.toString()
}
