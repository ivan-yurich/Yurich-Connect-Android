package com.tecclub.flutter_singbox.bg

import android.content.Intent
import org.mockito.Mockito.mock
import org.mockito.Mockito.verify
import org.mockito.Mockito.`when`
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertSame
import kotlin.test.assertTrue

class RuntimeConfigReloadTest {
    private val intent = mock(Intent::class.java)

    @Test
    fun `reload intent carries the exact newly saved config`() {
        val config = "{\"profile\":\"new\"}"
        assertSame(intent, RuntimeConfigReload.attach(intent, config))
        verify(intent).putExtra(BoxService.EXTRA_CONFIG_CONTENT, config)
    }

    @Test
    fun `reload replaces the service process cache without reading stale storage`() {
        var serviceCache = "{\"profile\":\"old\"}"
        val newConfig = "{\"profile\":\"new\"}"
        `when`(intent.getStringExtra(BoxService.EXTRA_CONFIG_CONTENT)).thenReturn(newConfig)
        assertTrue(RuntimeConfigReload.cacheReceived(intent) { serviceCache = it; true })
        assertEquals(newConfig, serviceCache)
    }

    @Test
    fun `missing or empty payload cannot silently reuse previous config`() {
        for (config in listOf(null, "", " ", "{}")) {
            `when`(intent.getStringExtra(BoxService.EXTRA_CONFIG_CONTENT)).thenReturn(config)
            var cacheCalled = false
            assertFalse(RuntimeConfigReload.cacheReceived(intent) { cacheCalled = true; true })
            assertFalse(cacheCalled)
            if (config != null) {
                assertFailsWith<IllegalArgumentException> { RuntimeConfigReload.attach(intent, config) }
            }
        }
    }

    @Test
    fun `cache rejection is not reported as a successful update`() {
        `when`(intent.getStringExtra(BoxService.EXTRA_CONFIG_CONTENT)).thenReturn("{\"profile\":1}")
        assertFalse(RuntimeConfigReload.cacheReceived(intent) { false })
    }
}
