package com.tecclub.flutter_singbox.bg

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import java.net.Socket
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

internal suspend fun <T> withCancellableSocket(
    socket: Socket = Socket(),
    block: (Socket) -> T,
): T = suspendCancellableCoroutine { continuation ->
    // Cancelling an IO coroutine does not interrupt java.net.Socket reads.
    // Closing the underlying socket also unblocks its layered SSLSocket.
    continuation.invokeOnCancellation { runCatching { socket.close() } }
    CoroutineScope(continuation.context + Dispatchers.IO).launch {
        try {
            val result = try {
                block(socket)
            } finally {
                runCatching { socket.close() }
            }
            continuation.resume(result)
        } catch (error: Exception) {
            continuation.resumeWithException(error)
        }
    }
}
