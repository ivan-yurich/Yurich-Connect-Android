package com.tecclub.flutter_singbox.bg

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse

class VpnPackagePolicyTest {
    private val ownPackage = "online.dnsai.ivanvpn"

    @Test
    fun `own package is never routed through an allow list`() {
        val allowed = VpnPackagePolicy.allowedPackages(
            listOf("external.one", ownPackage, " external.two ", "external.one"),
            ownPackage,
        )

        assertEquals(listOf("external.one", "external.two"), allowed)
        assertFalse(ownPackage in allowed)
    }

    @Test
    fun `own package is always first in the deny list`() {
        assertEquals(
            listOf(ownPackage, "external.one"),
            VpnPackagePolicy.disallowedPackages(
                listOf("external.one", ownPackage, "external.one"),
                ownPackage,
            ),
        )
    }
}
