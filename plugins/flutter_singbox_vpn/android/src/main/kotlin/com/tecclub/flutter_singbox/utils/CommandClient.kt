package com.tecclub.flutter_singbox.utils

import go.Seq
import io.nekohasekai.libbox.CommandClient
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
import com.tecclub.flutter_singbox.ktx.toList
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

open class CommandClient(
    private val scope: CoroutineScope,
    private val connectionType: ConnectionType,
    private val handler: Handler
) {

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


    private var commandClient: LibboxCommandClient? = null
    private val clientHandler = ClientHandler()
    private val lock = Object()
    @Volatile private var isConnecting = false
    
    fun connect() {
        synchronized(lock) {
            // If already connecting or connected, don't try again
            if (isConnecting || commandClient != null) {
                return
            }
            isConnecting = true
        }
        
        // Disconnect any existing client first
        disconnectInternal()
        
        scope.launch(Dispatchers.IO) {
            val options = CommandClientOptions()
            val command = when (connectionType) {
                ConnectionType.Status -> Libbox.CommandStatus
                ConnectionType.Groups -> Libbox.CommandGroup
                ConnectionType.Log -> Libbox.CommandLog
                ConnectionType.ClashMode -> Libbox.CommandClashMode
                ConnectionType.GroupOnly -> Libbox.CommandGroup
            }
            options.addCommand(command)
            options.statusInterval = 2 * 1000 * 1000 * 1000
            val newCommandClient = CommandClient(clientHandler, options)
            try {
                for (i in 1..10) {
                    delay(100 + i.toLong() * 50)
                    synchronized(lock) {
                        if (!isConnecting) {
                            runCatching {
                                newCommandClient.disconnect()
                            }
                            return@launch
                        }
                    }
                    try {
                        newCommandClient.connect()
                    } catch (ignored: Exception) {
                        continue
                    }
                    if (!isActive) {
                        runCatching {
                            newCommandClient.disconnect()
                        }
                        synchronized(lock) {
                            isConnecting = false
                        }
                        return@launch
                    }
                    synchronized(lock) {
                        if (!isConnecting) {
                            runCatching {
                                newCommandClient.disconnect()
                            }
                            return@launch
                        }
                        this@CommandClient.commandClient = newCommandClient
                        isConnecting = false
                    }
                    return@launch
                }
                runCatching {
                    newCommandClient.disconnect()
                }
            } finally {
                synchronized(lock) {
                    isConnecting = false
                }
            }
        }
    }
    
    private fun disconnectInternal() {
        val client = synchronized(lock) {
            val c = commandClient
            commandClient = null
            c
        }
        client?.apply {
            runCatching {
                disconnect()
            }
            runCatching {
                Seq.destroyRef(refnum)
            }
        }
    }

    fun disconnect() {
        synchronized(lock) {
            isConnecting = false
        }
        disconnectInternal()
    }
    
    fun isConnected(): Boolean {
        synchronized(lock) {
            return commandClient != null && !isConnecting
        }
    }

    private inner class ClientHandler : CommandClientHandler {

        override fun connected() {
            handler.onConnected()
        }

        override fun disconnected(message: String?) {
            synchronized(lock) {
                commandClient = null
                isConnecting = false
            }
            handler.onDisconnected()
        }

        override fun writeGroups(message: OutboundGroupIterator?) {
            if (message == null) {
                return
            }
            val groups = mutableListOf<OutboundGroup>()
            while (message.hasNext()) {
                groups.add(message.next())
            }
            handler.updateGroups(groups)
        }

        override fun clearLogs() {
            handler.clearLog()
        }

        override fun writeLogs(messageList: LogIterator?) {
            if (messageList == null) {
                return
            }
            while (messageList.hasNext()) {
                val message = messageList.next().message
                handler.appendLog(message)
            }
        }

        override fun writeStatus(message: StatusMessage?) {
            if (message == null) {
                return
            }
            handler.updateStatus(message)
        }

        override fun initializeClashMode(modeList: StringIterator, currentMode: String) {
            handler.initializeClashMode(modeList.toList(), currentMode)
        }

        override fun updateClashMode(newMode: String) {
            handler.updateClashMode(newMode)
        }
        
        override fun writeConnectionEvents(events: ConnectionEvents?) {
            // Handle connection updates if needed
        }

        override fun setDefaultLogLevel(level: Int) {
            // The Flutter UI displays log entries as they arrive.
        }

    }
}
