package com.tecclub.flutter_singbox.config

import android.content.Context
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.os.Build
import android.util.AtomicFile
import com.tecclub.flutter_singbox.bg.KillSwitchStatus
import com.tecclub.flutter_singbox.bg.NativeConfigBinding
import com.tecclub.flutter_singbox.bg.NativeProtectionQuery
import com.tecclub.flutter_singbox.database.Settings
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.*
import java.io.File
import java.io.FileNotFoundException
import java.io.RandomAccessFile

internal object SmartRouteApps {
    private const val MAX_RECORD_BYTES = 48 * 1024
    private const val CATALOG = "smart_route_android_candidates.json"
    private val mutex = Any()
    private val catalogMutex = Any()
    @Volatile private var cachedCatalog: List<Candidate>? = null

    private data class Candidate(val packageId: String, val name: String)

    private fun catalog(context: Context): List<Candidate> =
        cachedCatalog ?: synchronized(catalogMutex) {
            cachedCatalog ?: runCatching {
                val json = context.assets.open(CATALOG).bufferedReader().use { it.readText() }
                val rows = Json.parseToJsonElement(json).jsonArray
                require(rows.size in 1..SmartRouteAppPolicy.MAX_CANDIDATES)
                rows.map { value ->
                    val item = value.jsonObject
                    val id = item.getValue("packageId").jsonPrimitive.content
                    val name = item.getValue("name").jsonPrimitive.content
                    require(SmartRouteAppPolicy.validPackage(id) && name.length in 1..120)
                    Candidate(id, name)
                }.also { entries ->
                    require(entries.map { it.packageId }.distinct().size == entries.size)
                }.filter { SmartRouteAppPolicy.eligibleCatalogPackage(it.packageId) }
            }.getOrDefault(emptyList()).also { cachedCatalog = it }
        }

    private fun verified(context: Context): Set<String> =
        catalog(context).mapTo(linkedSetOf()) { it.packageId }

    @Suppress("DEPRECATION")
    private fun availability(pm: PackageManager, id: String): String = try {
        // A targeted lookup of a packaged catalog ID, not an app inventory.
        val info = pm.getPackageInfo(id, 0)
        val app = info.applicationInfo
        when {
            info.packageName != id || app == null ||
                app.flags and ApplicationInfo.FLAG_INSTALLED == 0 -> "missing"
            !info.sharedUserId.isNullOrEmpty() -> "shared_uid"
            !app.enabled -> "disabled"
            else -> "installed"
        }
    } catch (_: PackageManager.NameNotFoundException) {
        "missing"
    } catch (_: Exception) {
        "unknown"
    }

    suspend fun snapshot(context: Context): Map<String, Any?> {
        val supported = Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q
        val local = withContext(Dispatchers.IO) {
            val settings = read(context)
            mapOf(
                "candidates" to catalog(context).map { candidate ->
                    mapOf(
                        "packageId" to candidate.packageId,
                        "name" to candidate.name,
                        "availability" to availability(context.packageManager, candidate.packageId),
                    )
                },
                "selected" to SmartRouteAppPolicy.effectiveSelection(settings, verified(context)),
                "protectionRequested" to KillSwitchIntentStore.requested(context),
                "legacyAppMode" to Settings.perAppProxyEnabled,
            )
        }
        val system = if (supported) KillSwitchStatus.systemState(context) else null
        val live = if (supported) NativeProtectionQuery.readAppRouting(context) else null
        return local + mapOf(
            "supported" to supported,
            "protectionKnown" to (system != null),
            "protected" to (local["protectionRequested"] == true ||
                system?.values?.any { it } == true || live?.strict == true),
            "applied" to live?.excludedPackages,
        )
    }

    fun saveSelection(context: Context, packages: List<*>) {
        require(packages.size <= SmartRouteAppPolicy.MAX_CANDIDATES)
        update(context) {
            it.copy(
                selected = SmartRouteAppPolicy.selection(packages, verified(context)),
                followCatalogDefaults = false,
            )
        }
    }

    // Called only after Flutter checks install/update times and verifies that
    // there are no older preferences or profiles. A device transfer can still
    // restore native state, so only an absent native record can be seeded.
    fun initializeInstallDefault(context: Context): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return false
        val verified = verified(context)
        if (verified.isEmpty()) return false
        return locked(context) { file ->
            if (SimpleConfigManager.hasStoredRuntimeConfig(context) ||
                KillSwitchIntentStore.hasStoredIntent(context) ||
                Settings.perAppProxyEnabled ||
                file.baseFile.parentFile?.list()?.all { it == "apps.lock" } != true
            ) {
                return@locked false
            }
            val initial = SmartRouteAppPolicy.installDefaults(verified)
            writeLocked(file, initial)
            // AtomicFile may log some commit failures without throwing.
            readLocked(context, file) == initial
        }
    }

    fun bindManagedConfig(context: Context, fingerprint: String?) {
        require(fingerprint == null || NativeConfigBinding.isFingerprint(fingerprint))
        // The default/legacy path needs neither new files nor a write.
        if (fingerprint == null && !directory(context).exists()) return
        update(context) { it.copy(managedFingerprint = fingerprint) }
    }

    fun exclusions(context: Context, fingerprint: String?, strict: Boolean): List<String> {
        if (strict || fingerprint == null || Build.VERSION.SDK_INT < Build.VERSION_CODES.Q ||
            Settings.perAppProxyEnabled
        ) return emptyList()
        val settings = read(context)
        return SmartRouteAppPolicy.applicable(
            settings, fingerprint, strictOrLockdown = strict,
            protectionSupported = true, legacyAppModeEnabled = false,
            verified = verified(context),
        ) { id -> availability(context.packageManager, id) == "installed" }
    }

    private fun directory(context: Context): File =
        File(context.createDeviceProtectedStorageContext().filesDir, "smart-route")

    private fun read(context: Context): SmartRouteAppSettings = try {
        locked(context) { readLocked(context, it) }
    } catch (_: Exception) {
        SmartRouteAppSettings()
    }

    private fun readLocked(context: Context, file: AtomicFile): SmartRouteAppSettings =
        try {
            file.openRead().use { input ->
                require(input.channel.size() in 1..MAX_RECORD_BYTES.toLong())
                SmartRouteAppPolicy.decode(input.readBytes().toString(Charsets.UTF_8), verified(context))
            }
        } catch (error: FileNotFoundException) {
            // Missing on an upgrade is not a request for new direct routes.
            // Only the explicit fresh-install path may seed the catalog.
            val base = file.baseFile
            if (base.exists() || File(base.path + ".bak").exists() || File(base.path + ".new").exists() ||
                base.parentFile?.canRead() != true
            ) throw error
            SmartRouteAppSettings()
        }

    private fun update(context: Context, change: (SmartRouteAppSettings) -> SmartRouteAppSettings) =
        locked(context) { file ->
            val previous = readLocked(context, file)
            val next = change(previous)
            if (next != previous) writeLocked(file, next)
        }

    private fun writeLocked(file: AtomicFile, settings: SmartRouteAppSettings) {
        val output = file.startWrite()
        try {
            output.write(SmartRouteAppPolicy.encode(settings).toByteArray(Charsets.UTF_8))
            file.finishWrite(output)
        } catch (error: Exception) {
            file.failWrite(output)
            throw error
        }
    }

    private fun <T> locked(context: Context, action: (AtomicFile) -> T): T = synchronized(mutex) {
        val dir = directory(context)
        check(dir.isDirectory || dir.mkdirs() || dir.isDirectory)
        RandomAccessFile(File(dir, "apps.lock"), "rw").use { lock ->
            lock.channel.lock().use { action(AtomicFile(File(dir, "apps-v1.json"))) }
        }
    }
}
