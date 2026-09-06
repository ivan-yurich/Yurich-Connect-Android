package com.tecclub.flutter_singbox.bg

import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import org.mockito.Mockito.mock
import org.mockito.Mockito.`when`
import kotlin.test.Test
import kotlin.test.assertEquals

class NativeNetworkSnapshotTest {
    private val connectivity = mock(ConnectivityManager::class.java)
    private val network = mock(Network::class.java)

    @Test
    fun `absence differs from unknown capabilities`() {
        assertEquals(NativeNetworkSnapshot(0, 0, 1), NativeNetworkSnapshot.capture(connectivity, null))
        `when`(connectivity.activeNetwork).thenReturn(network)
        assertEquals(NativeNetworkSnapshot(1, 1, 1), NativeNetworkSnapshot.capture(connectivity, network))
    }

    @Test
    fun `wifi and vpn transports are separate bits`() {
        val caps = mock(NetworkCapabilities::class.java)
        `when`(connectivity.activeNetwork).thenReturn(network)
        `when`(connectivity.getNetworkCapabilities(network)).thenReturn(caps)
        `when`(caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)).thenReturn(true)
        `when`(caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)).thenReturn(true)
        `when`(caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)).thenReturn(true)
        assertEquals(NativeNetworkSnapshot(107, 107, 1), NativeNetworkSnapshot.capture(connectivity, network))
        `when`(caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN)).thenReturn(true)
        assertEquals(111, NativeNetworkSnapshot.capture(connectivity, network).activeFlags)
    }

    @Test
    fun `denied active query does not masquerade as no network`() {
        `when`(connectivity.activeNetwork).thenThrow(SecurityException("not exported"))
        assertEquals(NativeNetworkSnapshot(-1, 0, -1), NativeNetworkSnapshot.capture(connectivity, null))
    }

    @Test
    fun `stale tracked network is distinct from active wifi`() {
        `when`(connectivity.getNetworkCapabilities(network)).thenReturn(null)
        assertEquals(NativeNetworkSnapshot(0, 1, 0), NativeNetworkSnapshot.capture(connectivity, network))
    }
}
