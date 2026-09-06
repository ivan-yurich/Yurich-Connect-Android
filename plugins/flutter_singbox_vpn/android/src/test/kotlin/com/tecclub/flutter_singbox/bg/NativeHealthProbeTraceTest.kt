package com.tecclub.flutter_singbox.bg

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class NativeHealthProbeTraceTest {
    @Test
    fun `stage durations are individual rather than cumulative`() {
        val trace = NativeHealthProbeTrace(NativeProbeEndpoint.Google, 3, 7, 100,
            NativeNetworkSnapshot(107, 107, 1))
        trace.enter(NativeProbeStage.ProxyResponse, 110)
        trace.enter(NativeProbeStage.Tls, 140)
        trace.enter(NativeProbeStage.Http, 200)
        assertEquals(
            "SOAK_HEALTH v=1 endpoint=google generation=3 revision=7 started=100 finished=250 " +
                "stage=http ok=true failure=none proxyConnectMs=10 proxyResponseMs=30 " +
                "tlsMs=60 httpMs=50 activeNet=107 trackedNet=107 sameNet=1",
            trace.finish(250, true, NativeProbeFailure.None),
        )
    }

    @Test
    fun `timeout leaves later stages unobserved`() {
        val trace = NativeHealthProbeTrace(NativeProbeEndpoint.Cloudflare, 1, 2, 100,
            NativeNetworkSnapshot())
        trace.enter(NativeProbeStage.ProxyResponse, 102)
        val result = trace.finish(3102, false, NativeProbeFailure.Timeout)
        assertTrue(result.contains("stage=proxy_response ok=false failure=timeout"))
        assertTrue(result.contains("proxyConnectMs=2 proxyResponseMs=3000 tlsMs=-1 httpMs=-1"))
        assertFalse(result.contains("www.cloudflare.com"))
    }

    @Test
    fun `unknown endpoints are never serialized`() {
        assertNull(NativeProbeEndpoint.fromHost("secret.example"))
        assertEquals(NativeProbeEndpoint.Gstatic, NativeProbeEndpoint.fromHost("connectivitycheck.gstatic.com"))
    }
}
