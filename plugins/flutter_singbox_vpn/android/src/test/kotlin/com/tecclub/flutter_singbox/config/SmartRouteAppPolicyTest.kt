package com.tecclub.flutter_singbox.config

import com.tecclub.flutter_singbox.bg.NativeConfigBinding
import com.tecclub.flutter_singbox.bg.VpnPackagePolicy
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class SmartRouteAppPolicyTest {
    private val max = "ru.oneme.app"
    private val psb = "logo.com.mbanking"
    private val verified = setOf(max, psb)
    private val scope = NativeConfigBinding.fingerprint("generated config")
    private val settings = SmartRouteAppSettings(listOf(max, psb), scope)

    private fun apply(
        value: SmartRouteAppSettings = settings,
        fingerprint: String? = scope,
        strict: Boolean = false,
        supported: Boolean = true,
        override: Boolean = false,
        installed: Set<String> = verified,
    ): List<String> = SmartRouteAppPolicy.applicable(
        value, fingerprint, strict, supported, override, verified, installed::contains,
    )

    @Test fun onlyExactCaseSensitiveVerifiedPackageNamesAreAccepted() {
        assertEquals(listOf(max), SmartRouteAppPolicy.selection(
            listOf(max, max, "ru.oneme", "ru.oneme.app.beta", "RU.ONEME.APP",
                " ru.oneme.app", "ru.oneme.app ", "ru.oneme.*", "MAX", 1, null),
            verified,
        ))
        assertFalse(SmartRouteAppPolicy.validPackage("ru.oneme.*"))
        val mfc = "website.copyandpaste.MFCRO"
        assertEquals(listOf(mfc), SmartRouteAppPolicy.selection(listOf(mfc, mfc.lowercase()), setOf(mfc)))
    }

    @Test fun browserAndSearchShellsStayInVpnEvenIfAccidentallyCatalogued() {
        val browsers = setOf("com.yandex.browser", "com.yandex.searchapp", "ru.yandex.searchplugin",
            "com.android.chrome")
        val catalog = verified + browsers
        assertEquals(verified.sorted(), SmartRouteAppPolicy.effectiveSelection(
            SmartRouteAppPolicy.installDefaults(catalog), catalog,
        ))
        assertTrue(SmartRouteAppPolicy.selection(browsers, catalog).isEmpty())
    }

    @Test fun expandedSelectionRoundTripsWithoutTruncation() {
        val ids = (1..SmartRouteAppPolicy.MAX_CANDIDATES).map { index ->
            "test." + "a".repeat(247) + index.toString().padStart(3, '0')
        }
        val saved = SmartRouteAppSettings(ids, scope)
        val encoded = SmartRouteAppPolicy.encode(saved)
        assertTrue(encoded.length > 32 * 1024)
        assertEquals(saved, SmartRouteAppPolicy.decode(encoded, ids.toSet()))
        assertEquals(SmartRouteAppSettings(), SmartRouteAppPolicy.decode(
            SmartRouteAppPolicy.encode(saved.copy(selected = ids + "test.extra")), ids.toSet(),
        ))
    }

    @Test fun freshInstallAndDisabledBindingNeverEnableAnException() {
        assertTrue(apply(value = SmartRouteAppSettings()).isEmpty())
        assertTrue(apply(value = settings.copy(managedFingerprint = null)).isEmpty())
        assertTrue(apply(fingerprint = null).isEmpty())
        assertTrue(apply(fingerprint = NativeConfigBinding.fingerprint("raw config")).isEmpty())
        assertTrue(apply(value = SmartRouteAppSettings(emptyList(), scope)).isEmpty())
    }

    @Test fun freshDefaultsSelectAllVerifiedButRequireABoundManagedConfig() {
        val fresh = SmartRouteAppPolicy.installDefaults(verified)
        assertEquals(verified.sorted(), SmartRouteAppPolicy.effectiveSelection(fresh, verified))
        assertFalse(fresh.followCatalogDefaults)
        assertTrue(apply(value = fresh).isEmpty())
        val bound = fresh.copy(managedFingerprint = scope)
        val reloaded = SmartRouteAppPolicy.decode(SmartRouteAppPolicy.encode(bound), verified)
        assertEquals(bound, reloaded)
        assertEquals(verified.sorted(), apply(value = reloaded))
        assertEquals(listOf(max), apply(value = reloaded, installed = setOf(max)))
        assertTrue(apply(value = reloaded, strict = true).isEmpty())
        assertTrue(apply(value = reloaded, supported = false).isEmpty())
        assertTrue(apply(value = reloaded, override = true).isEmpty())
        assertTrue(apply(value = reloaded, fingerprint = NativeConfigBinding.fingerprint("different")).isEmpty())
    }

    @Test fun catalogGrowthNeverOverridesCustomChoicesOrAmbiguousLegacyEmpty() {
        val extra = "test.verified.app"
        val expanded = verified + extra
        val legacyEmpty = SmartRouteAppPolicy.decode(
            """{"version":1,"selected":[],"managedFingerprint":"$scope"}""", expanded,
        )
        val legacyPartial = SmartRouteAppPolicy.decode(
            """{"version":1,"selected":["$max"],"managedFingerprint":"$scope"}""", expanded,
        )
        assertEquals(emptyList(), SmartRouteAppPolicy.effectiveSelection(legacyEmpty, expanded))
        assertEquals(listOf(max), SmartRouteAppPolicy.effectiveSelection(legacyPartial, expanded))
        val explicitEmpty = SmartRouteAppPolicy.installDefaults(verified).copy(selected = emptyList())
        val decoded = SmartRouteAppPolicy.decode(SmartRouteAppPolicy.encode(explicitEmpty), expanded)
        assertFalse(decoded.followCatalogDefaults)
        assertTrue(SmartRouteAppPolicy.effectiveSelection(decoded, expanded).isEmpty())
        // A clean install that updates before its first VPN connection must
        // keep its original catalog snapshot; it still has no runtime binding.
        val seed = SmartRouteAppPolicy.installDefaults(verified)
        val upgraded = SmartRouteAppPolicy.decode(SmartRouteAppPolicy.encode(seed), expanded)
        assertEquals(verified.sorted(), SmartRouteAppPolicy.effectiveSelection(upgraded, expanded))
        assertTrue(apply(value = upgraded).isEmpty())

        // Preserve the meaning of the catalog mode written by earlier builds.
        val legacyCatalog = SmartRouteAppPolicy.decode(
            """{"version":2,"selectionMode":"catalog","selected":[]}""", expanded,
        )
        assertEquals(
            expanded.sorted(),
            SmartRouteAppPolicy.effectiveSelection(legacyCatalog, expanded),
        )
    }

    @Test fun upgradeWithoutSelectionDoesNotRouteMoreAppsWhenSmartRouteWasAlreadyOn() {
        val boundWithoutSelection = SmartRouteAppSettings(managedFingerprint = scope)
        assertTrue(SmartRouteAppPolicy.effectiveSelection(boundWithoutSelection, verified).isEmpty())
        assertTrue(apply(value = boundWithoutSelection).isEmpty())
    }

    @Test fun invalidDefaultRecordNeverBroadensDirectRouting() {
        for (record in listOf(
            """{"version":"2","selectionMode":"catalog","selected":[]}""",
            """{"version":2,"selectionMode":"unknown","selected":[]}""",
            """{"version":2,"selectionMode":"catalog","selected":["$max"]}""",
            """{"version":2,"selectionMode":"catalog","selected":[],"managedFingerprint":"invalid"}""",
            """{"version":3,"selectionMode":"catalog","selected":[]}""",
        )) {
            val decoded = SmartRouteAppPolicy.decode(record, verified)
            assertFalse(decoded.followCatalogDefaults)
            assertTrue(SmartRouteAppPolicy.effectiveSelection(decoded, verified).isEmpty())
            assertTrue(apply(value = decoded).isEmpty())
        }
    }

    @Test fun aSavedButMissingOrUnsuitableAppNeverReachesBuilder() {
        assertEquals(listOf(psb), apply(installed = setOf(psb, "ru.oneme.app.clone")))
        assertTrue(apply(installed = emptySet()).isEmpty())
        assertEquals(listOf(max, psb).sorted(), apply())
    }

    @Test fun protectionAndLegacyIncludeOrExcludeModeWinBeforePackageLookup() {
        for (flags in listOf(Triple(true, true, false), Triple(false, false, false), Triple(false, true, true))) {
            val selected = SmartRouteAppPolicy.applicable(
                settings, scope, flags.first, flags.second, flags.third, verified,
            ) { error("No package lookups should run while app routing is suppressed") }
            assertTrue(selected.isEmpty())
        }
        assertTrue(apply(strict = StrictProtectionIntent.required(false, false, true)).isEmpty())
        assertTrue(apply(strict = StrictProtectionIntent.required(true, false, false)).isEmpty())
    }

    @Test fun exactSameOptInsAreMergedWithExistingExclusionsForEitherCore() {
        // Both native TUN entry points use this exclude-only composition.
        val legacy = listOf("com.vkontakte.android", "ru.sberbankmobile")
        for (existing in listOf(legacy, listOf("online.dnsai.ivanvpn") + legacy)) {
            assertEquals(
                listOf("online.dnsai.ivanvpn") + legacy + listOf(psb, max),
                VpnPackagePolicy.disallowedPackages(existing + apply(), "online.dnsai.ivanvpn"),
            )
            assertEquals(
                listOf("online.dnsai.ivanvpn") + legacy,
                VpnPackagePolicy.disallowedPackages(existing + apply(override = true), "online.dnsai.ivanvpn"),
            )
        }
    }

    @Test fun cachedSelectionIsValidatedOnEveryReadAndMalformedRecordsFailClosed() {
        val sorted = settings.copy(selected = listOf(psb, max))
        assertEquals(sorted, SmartRouteAppPolicy.decode(SmartRouteAppPolicy.encode(sorted), verified))
        assertEquals(listOf(max), SmartRouteAppPolicy.decode(
            SmartRouteAppPolicy.encode(settings.copy(selected = listOf(max, "unverified.bank.app"))), verified,
        ).selected)
        for (record in listOf("", "[]", "{}", """{"version":1,"selected":[1]}""",
            """{"version":1,"selected":["ru.oneme.app"],"managedFingerprint":"bad"}""")) {
            assertEquals(SmartRouteAppSettings(), SmartRouteAppPolicy.decode(record, verified))
        }
    }
}
