package com.tecclub.flutter_singbox.bg

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import org.mockito.Mockito.atLeastOnce
import org.mockito.Mockito.doAnswer
import org.mockito.Mockito.mock
import org.mockito.Mockito.verify
import java.net.Socket
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class CancellableSocketProbeTest {
    @Test
    fun `successful probe closes its socket`() = runBlocking {
        val socket = mock(Socket::class.java)
        assertEquals(true, withCancellableSocket(socket) { true })
        verify(socket, atLeastOnce()).close()
    }

    @Test
    fun `failed probe closes its socket`() = runBlocking {
        val socket = mock(Socket::class.java)
        val failed = runCatching {
            withCancellableSocket(socket) { throw java.io.IOException("test") }
        }
        assertTrue(failed.isFailure)
        verify(socket, atLeastOnce()).close()
    }

    @Test
    fun `cancellation closes socket before waiting for blocking worker`() = runBlocking {
        val socket = mock(Socket::class.java)
        val entered = CountDownLatch(1)
        val closed = CountDownLatch(1)
        doAnswer { closed.countDown(); null }.`when`(socket).close()
        val probe = launch(Dispatchers.Default) {
            withCancellableSocket(socket) {
                entered.countDown()
                assertTrue(closed.await(3, TimeUnit.SECONDS))
                true
            }
        }
        assertTrue(withContext(Dispatchers.IO) { entered.await(2, TimeUnit.SECONDS) })
        probe.cancel()
        withTimeout(2_000L) { probe.join() }
        assertTrue(closed.count == 0L)
        verify(socket, atLeastOnce()).close()
    }
}
