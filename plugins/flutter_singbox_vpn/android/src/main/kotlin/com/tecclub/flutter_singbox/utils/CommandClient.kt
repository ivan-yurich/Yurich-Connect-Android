package com.tecclub.flutter_singbox.utils

import go.Seq
import io.nekohasekai.libbox.CommandClient as LibboxCommandClient
import io.nekohasekai.libbox.CommandClientHandler
import io.nekohasekai.libbox.CommandClientOptions
import io.nekohasekai.libbox.ConnectionEvents
import io.nekohasekai.libbox.Libbox
import io.nekohasekai.libbox.LogIterator
import io.nekohasekai.libbox.OutboundGroup
import io.nekohasekai.libbox.OutboundGroupIterator
import io.nekohasekai.libbox.StatusMessage
import io.nekohasekai.libbox.StringIterator
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.coroutines.coroutineContext
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

internal interface NativeCommandClient {
    val refnum: Int

    fun connect()

    fun disconnect()
}

internal fun interface NativeCommandClientFactory {
    fun create(
        handler: CommandClientHandler,
        connectionType: CommandClient.ConnectionType
    ): NativeCommandClient
}

internal fun interface NativeReferenceDestroyer {
    fun destroy(refnum: Int)
}

private class LibboxNativeCommandClient(
    private val delegate: LibboxCommandClient
) : NativeCommandClient {
    override val refnum: Int
        get() = delegate.refnum

    override fun connect() {
        delegate.connect()
    }

    override fun disconnect() {
        delegate.disconnect()
    }
}

private object LibboxNativeCommandClientFactory : NativeCommandClientFactory {
    override fun create(
        handler: CommandClientHandler,
        connectionType: CommandClient.ConnectionType
    ): NativeCommandClient {
        val options = CommandClientOptions()
        try {
            val command = when (connectionType) {
                CommandClient.ConnectionType.Status -> Libbox.CommandStatus
                CommandClient.ConnectionType.Groups -> Libbox.CommandGroup
                CommandClient.ConnectionType.Log -> Libbox.CommandLog
                CommandClient.ConnectionType.ClashMode -> Libbox.CommandClashMode
                CommandClient.ConnectionType.GroupOnly -> Libbox.CommandGroup
            }
            options.addCommand(command)
            options.statusInterval = STATUS_INTERVAL_NANOS
            return LibboxNativeCommandClient(LibboxCommandClient(handler, options))
        } finally {
            runCatching { Seq.destroyRef(options.refnum) }
        }
    }

    private const val STATUS_INTERVAL_NANOS = 2_000_000_000L
}

private object SeqNativeReferenceDestroyer : NativeReferenceDestroyer {
    override fun destroy(refnum: Int) {
        Seq.destroyRef(refnum)
    }
}

open class CommandClient private constructor(
    private val scope: CoroutineScope,
    private val connectionType: ConnectionType,
    private val handler: Handler,
    private val clientFactory: NativeCommandClientFactory,
    private val referenceDestroyer: NativeReferenceDestroyer,
    private val ioDispatcher: CoroutineDispatcher,
    private val retryDelay: suspend (attempt: Int) -> Unit,
    @Suppress("UNUSED_PARAMETER") constructorMarker: Unit
) {

    constructor(
        scope: CoroutineScope,
        connectionType: ConnectionType,
        handler: Handler
    ) : this(
        scope = scope,
        connectionType = connectionType,
        handler = handler,
        clientFactory = LibboxNativeCommandClientFactory,
        referenceDestroyer = SeqNativeReferenceDestroyer,
        ioDispatcher = Dispatchers.IO,
        retryDelay = { attempt -> delay(100L + attempt * 50L) },
        constructorMarker = Unit
    )

    internal constructor(
        scope: CoroutineScope,
        connectionType: ConnectionType,
        handler: Handler,
        clientFactory: NativeCommandClientFactory,
        referenceDestroyer: NativeReferenceDestroyer,
        ioDispatcher: CoroutineDispatcher,
        retryDelay: suspend (attempt: Int) -> Unit
    ) : this(
        scope = scope,
        connectionType = connectionType,
        handler = handler,
        clientFactory = clientFactory,
        referenceDestroyer = referenceDestroyer,
        ioDispatcher = ioDispatcher,
        retryDelay = retryDelay,
        constructorMarker = Unit
    )

    enum class ConnectionType {
        Status, Groups, Log, ClashMode, GroupOnly
    }

    interface Handler {

        fun onConnected() {}
        fun onDisconnected() {}
        fun updateStatus(status: StatusMessage) {}
        fun updateGroups(groups: List<OutboundGroup>) {}
        fun clearLog() {}
        fun appendLog(message: String) {}
        fun initializeClashMode(modeList: List<String>, currentMode: String) {}
        fun updateClashMode(newMode: String) {}

    }


    private val lock = Object()
    private var commandClient: ClientLease? = null
    private var currentGeneration = 0L
    private var isConnecting = false

    private class ClientLease(
        val generation: Long,
        private val client: NativeCommandClient,
        private val referenceDestroyer: NativeReferenceDestroyer
    ) {
        private val closed = AtomicBoolean(false)

        fun connect() {
            client.connect()
        }

        fun close() {
            if (!closed.compareAndSet(false, true)) {
                return
            }
            runCatching { client.disconnect() }
            runCatching { referenceDestroyer.destroy(client.refnum) }
        }
    }
    
    fun connect() {
        val generation = synchronized(lock) {
            if (isConnecting || commandClient != null) {
                return
            }
            isConnecting = true
            ++currentGeneration
        }

        val job = scope.launch(ioDispatcher) {
            var connected = false
            try {
                if (!isGenerationConnecting(generation)) {
                    return@launch
                }

                val newCommandClient = ClientLease(
                    generation = generation,
                    client = clientFactory.create(ClientHandler(generation), connectionType),
                    referenceDestroyer = referenceDestroyer
                )
                if (!installClient(generation, newCommandClient)) {
                    newCommandClient.close()
                    return@launch
                }

                for (attempt in 1..MAX_CONNECT_ATTEMPTS) {
                    retryDelay(attempt)
                    if (!coroutineContext.isActive || !isCurrentConnectingClient(generation, newCommandClient)) {
                        return@launch
                    }
                    try {
                        newCommandClient.connect()
                    } catch (ignored: Exception) {
                        continue
                    }

                    if (!coroutineContext.isActive) {
                        return@launch
                    }

                    connected = synchronized(lock) {
                        if (isCurrentConnectingClientLocked(generation, newCommandClient)) {
                            isConnecting = false
                            true
                        } else {
                            false
                        }
                    }
                    if (connected) {
                        return@launch
                    }
                }
            } finally {
                if (!connected) {
                    closeConnectingGeneration(generation)
                }
            }
        }
        job.invokeOnCompletion {
            closeConnectingGeneration(generation)
        }
    }

    private fun isGenerationConnecting(generation: Long): Boolean = synchronized(lock) {
        currentGeneration == generation && isConnecting
    }

    private fun installClient(generation: Long, client: ClientLease): Boolean = synchronized(lock) {
        if (currentGeneration != generation || !isConnecting || commandClient != null) {
            false
        } else {
            commandClient = client
            true
        }
    }

    private fun isCurrentConnectingClient(
        generation: Long,
        client: ClientLease
    ): Boolean = synchronized(lock) {
        isCurrentConnectingClientLocked(generation, client)
    }

    private fun isCurrentConnectingClientLocked(
        generation: Long,
        client: ClientLease
    ): Boolean = currentGeneration == generation &&
        isConnecting &&
        commandClient === client

    private fun closeConnectingGeneration(generation: Long) {
        val client = synchronized(lock) {
            if (currentGeneration != generation || !isConnecting) {
                return
            }
            currentGeneration++
            isConnecting = false
            val current = commandClient
            commandClient = null
            current
        }
        client?.close()
    }

    fun disconnect() {
        val disconnected = synchronized(lock) {
            val wasActive = isConnecting || commandClient != null
            currentGeneration++
            isConnecting = false
            val current = commandClient
            commandClient = null
            DisconnectResult(current, currentGeneration, wasActive)
        }
        disconnected.client?.close()
        notifyDisconnectedIfStillIdle(disconnected)
    }

    fun isConnected(): Boolean {
        synchronized(lock) {
            return commandClient != null && !isConnecting
        }
    }

    private data class DisconnectResult(
        val client: ClientLease?,
        val terminalGeneration: Long,
        val shouldNotify: Boolean
    )

    private fun notifyDisconnectedIfStillIdle(result: DisconnectResult) {
        if (!result.shouldNotify) {
            return
        }
        synchronized(lock) {
            if (currentGeneration == result.terminalGeneration &&
                commandClient == null &&
                !isConnecting
            ) {
                handler.onDisconnected()
            }
        }
    }

    private fun disconnectGeneration(generation: Long) {
        val disconnected = synchronized(lock) {
            val current = commandClient
            if (currentGeneration != generation || current?.generation != generation) {
                return
            }
            currentGeneration++
            isConnecting = false
            commandClient = null
            DisconnectResult(current, currentGeneration, shouldNotify = true)
        }
        disconnected.client?.close()
        notifyDisconnectedIfStillIdle(disconnected)
    }

    private inline fun dispatchForGeneration(generation: Long, action: Handler.() -> Unit) {
        synchronized(lock) {
            if (currentGeneration == generation && commandClient?.generation == generation) {
                handler.action()
            }
        }
    }

    private inner class ClientHandler(
        private val generation: Long
    ) : CommandClientHandler {

        override fun connected() {
            dispatchForGeneration(generation) { onConnected() }
        }

        override fun disconnected(message: String?) {
            disconnectGeneration(generation)
        }

        override fun writeGroups(message: OutboundGroupIterator?) {
            dispatchForGeneration(generation) {
                if (message == null) {
                    return@dispatchForGeneration
                }
                val groups = mutableListOf<OutboundGroup>()
                while (message.hasNext()) {
                    groups.add(message.next())
                }
                updateGroups(groups)
            }
        }

        override fun clearLogs() {
            dispatchForGeneration(generation) { clearLog() }
        }

        override fun writeLogs(messageList: LogIterator?) {
            dispatchForGeneration(generation) {
                if (messageList == null) {
                    return@dispatchForGeneration
                }
                while (messageList.hasNext()) {
                    appendLog(messageList.next().message)
                }
            }
        }

        override fun writeStatus(message: StatusMessage?) {
            dispatchForGeneration(generation) {
                if (message != null) {
                    updateStatus(message)
                }
            }
        }

        override fun initializeClashMode(modeList: StringIterator, currentMode: String) {
            dispatchForGeneration(generation) {
                val modes = mutableListOf<String>()
                while (modeList.hasNext()) {
                    modes.add(modeList.next())
                }
                initializeClashMode(modes, currentMode)
            }
        }

        override fun updateClashMode(newMode: String) {
            dispatchForGeneration(generation) { updateClashMode(newMode) }
        }
        
        override fun writeConnectionEvents(events: ConnectionEvents?) {
            // Handle connection updates if needed
        }

        override fun setDefaultLogLevel(level: Int) {
            // The Flutter UI displays log entries as they arrive.
        }

    }

    private companion object {
        const val MAX_CONNECT_ATTEMPTS = 10
    }
}
