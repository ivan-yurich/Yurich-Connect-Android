package com.tecclub.flutter_singbox.utils

import io.nekohasekai.libbox.CommandClientHandler
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class CommandClientTest {
    @Test
    fun `late callbacks from generation A cannot clear or update generation B`() {
        val factory = FakeClientFactory()
        val events = RecordingHandler()
        val client = newClient(factory, events)

        client.connect()
        val generationA = factory.clients.single()
        assertTrue(client.isConnected())

        client.disconnect()
        client.connect()
        val generationB = factory.clients.last()
        assertTrue(client.isConnected())
        assertEquals(1, events.disconnected)

        generationA.handler.connected()
        generationA.handler.clearLogs()
        generationA.handler.updateClashMode("stale")
        generationA.handler.disconnected("late callback")

        assertTrue(client.isConnected())
        assertEquals(0, events.connected)
        assertEquals(0, events.clearLogs)
        assertEquals(emptyList(), events.clashModes)
        assertEquals(1, events.disconnected)

        generationB.handler.connected()
        generationB.handler.clearLogs()
        generationB.handler.updateClashMode("current")

        assertEquals(1, events.connected)
        assertEquals(1, events.clearLogs)
        assertEquals(listOf("current"), events.clashModes)

        generationB.handler.disconnected("current callback")

        assertFalse(client.isConnected())
        assertEquals(2, events.disconnected)
        assertEquals(listOf(1, 1), factory.clients.map { it.disconnectCalls })
        assertEquals(setOf(generationA.refnum, generationB.refnum), factory.destroyedRefs)
        assertEquals(0, factory.liveRefs)
    }

    @Test
    fun `repeated failures release every native ref exactly once`() {
        val factory = FakeClientFactory(failConnect = true)
        val client = newClient(factory, RecordingHandler())

        repeat(25) {
            client.connect()
            assertFalse(client.isConnected())
            client.disconnect()
        }

        assertEquals(25, factory.clients.size)
        assertTrue(factory.clients.all { it.connectCalls == 10 })
        assertTrue(factory.clients.all { it.disconnectCalls == 1 })
        assertEquals(factory.clients.map { it.refnum }.toSet(), factory.destroyedRefs)
        assertEquals(25, factory.destroyedRefs.size)
        assertEquals(0, factory.liveRefs)
    }

    private fun newClient(
        factory: FakeClientFactory,
        handler: CommandClient.Handler
    ): CommandClient = CommandClient(
        scope = CoroutineScope(SupervisorJob()),
        connectionType = CommandClient.ConnectionType.Status,
        handler = handler,
        clientFactory = factory,
        referenceDestroyer = NativeReferenceDestroyer(factory::destroy),
        ioDispatcher = Dispatchers.Unconfined,
        retryDelay = {}
    )

    private class FakeClientFactory(
        private val failConnect: Boolean = false
    ) : NativeCommandClientFactory {
        val clients = mutableListOf<FakeNativeClient>()
        val destroyedRefs = mutableSetOf<Int>()
        var liveRefs = 0
            private set

        override fun create(
            handler: CommandClientHandler,
            connectionType: CommandClient.ConnectionType
        ): NativeCommandClient {
            val client = FakeNativeClient(
                refnum = clients.size + 1,
                handler = handler,
                failConnect = failConnect
            )
            clients += client
            liveRefs++
            return client
        }

        fun destroy(refnum: Int) {
            check(destroyedRefs.add(refnum)) { "native ref $refnum destroyed twice" }
            liveRefs--
        }
    }

    private class FakeNativeClient(
        override val refnum: Int,
        val handler: CommandClientHandler,
        private val failConnect: Boolean
    ) : NativeCommandClient {
        var connectCalls = 0
            private set
        var disconnectCalls = 0
            private set

        override fun connect() {
            connectCalls++
            if (failConnect) {
                throw IllegalStateException("expected fake connection failure")
            }
        }

        override fun disconnect() {
            disconnectCalls++
        }
    }

    private class RecordingHandler : CommandClient.Handler {
        var connected = 0
        var disconnected = 0
        var clearLogs = 0
        val clashModes = mutableListOf<String>()

        override fun onConnected() {
            connected++
        }

        override fun onDisconnected() {
            disconnected++
        }

        override fun clearLog() {
            clearLogs++
        }

        override fun updateClashMode(newMode: String) {
            clashModes += newMode
        }
    }
}
