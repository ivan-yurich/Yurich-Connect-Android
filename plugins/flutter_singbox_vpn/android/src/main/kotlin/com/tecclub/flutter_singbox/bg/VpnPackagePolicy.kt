package com.tecclub.flutter_singbox.bg

internal object VpnPackagePolicy {
    fun allowedPackages(configured: Iterable<String>, ownPackage: String): List<String> =
        configured.asSequence()
            .map(String::trim)
            .filter { it.isNotEmpty() && it != ownPackage }
            .distinct()
            .toList()

    fun disallowedPackages(configured: Iterable<String>, ownPackage: String): List<String> =
        buildList {
            add(ownPackage)
            configured.asSequence()
                .map(String::trim)
                .filter { it.isNotEmpty() && it != ownPackage }
                .distinct()
                .forEach(::add)
        }
}
