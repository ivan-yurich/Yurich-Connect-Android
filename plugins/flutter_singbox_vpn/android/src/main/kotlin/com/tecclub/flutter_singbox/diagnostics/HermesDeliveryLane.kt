package com.tecclub.flutter_singbox.diagnostics

import android.content.Context
import android.net.LocalSocket
import android.net.LocalSocketAddress
import android.net.Network
import android.os.ParcelFileDescriptor
import android.os.Process
import androidx.annotation.RequiresApi
import kotlinx.coroutines.*
import java.io.Closeable
import java.io.IOException
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference

/** Not persisted or supplied by the UI. This exact listener belongs to this live runtime. */
internal class HermesLiveRoute(
    val sessionGeneration: Long,
    val configuration: String,
    val command: String,
    val descriptor: ParcelFileDescriptor,
    val network: Network,
    val networkEpoch: Long,
    val path: String,
)

internal class HermesDeliveryTicket(
    val reportId: String,
    val occurredAtMillis: Long,
    val epoch: String,
    val revision: String,
    val attempt: Int,
)

/** One worker for the VPN process. It is never started by a pending report or by Android boot. */
@RequiresApi(29)
internal class HermesDeliveryLane(
    private val context: Context,
    scope: CoroutineScope,
    private val routeIsCurrent: (HermesLiveRoute) -> Boolean,
) : Closeable {
    private class Flight(val route: HermesLiveRoute) {
        val socket = AtomicReference<LocalSocket?>(null)
        val cancelled = AtomicBoolean()

        fun close() {
            cancelled.set(true)
            // Closing the actual connected UDS invalidates the TLS stream,
            // including a blocking read. No network socket is available here.
            socket.getAndSet(null)?.let { stream ->
                runCatching { stream.fileDescriptor?.let {
                    android.system.Os.shutdown(it, android.system.OsConstants.SHUT_RDWR)
                } }
                runCatching { stream.close() }
            }
        }
    }

    private val lock = Any()
    @Volatile private var route: HermesLiveRoute? = null
    private var flight: Flight? = null
    private var closed = false
    private val wake = kotlinx.coroutines.channels.Channel<Unit>(kotlinx.coroutines.channels.Channel.CONFLATED)
    private val worker = scope.launch(Dispatchers.IO) {
        for (signal in wake) {
            while (isActive && route != null) {
                sendOne(this)
                // No wake lock, WorkManager or independent Internet task.
                // Wait for a signal, or re-evaluate durable pacing periodically.
                withTimeoutOrNull(IDLE_CHECK_MS) { wake.receiveCatching() }
            }
        }
    }

    fun install(value: HermesLiveRoute) {
        // Never take the VPN command fence while holding the lane lock.
        if (!routeIsCurrent(value)) return
        synchronized(lock) {
            if (closed) return
            if (sameLease(route, value)) return
            invalidateRouteLocked()
            route = value
            wake.trySend(Unit)
        }
    }

    private fun sameLease(left: HermesLiveRoute?, right: HermesLiveRoute): Boolean =
        left != null && left.sessionGeneration == right.sessionGeneration && left.configuration == right.configuration &&
            left.command == right.command && left.descriptor === right.descriptor && left.network == right.network &&
            left.networkEpoch == right.networkEpoch && left.path == right.path

    fun invalidateRoute() = synchronized(lock) { invalidateRouteLocked() }

    private fun invalidateRouteLocked() {
        route = null
        flight?.close()
    }

    fun accessChanged() = synchronized(lock) {
        // Re-read the epoch/grant under the process-shared disk lock.
        // Already sent bytes cannot be taken back.
        flight?.close()
        wake.trySend(Unit)
        Unit
    }

    fun queueChanged() {
        wake.trySend(Unit)
    }

    fun hasRoute(): Boolean = route?.let(::validRoute) == true

    private fun verifiedPeer(socket: LocalSocket): Boolean =
        socket.peerCredentials.let { it.uid == Process.myUid() && it.pid == Process.myPid() }

    private fun validRoute(value: HermesLiveRoute): Boolean =
        route === value && runCatching { routeIsCurrent(value) }.getOrDefault(false) && route === value

    private suspend fun sendOne(scope: CoroutineScope) {
        val selected = route ?: return
        if (!validRoute(selected)) {
            synchronized(lock) { if (route === selected) invalidateRouteLocked() }
            return
        }
        val ticket = runCatching { LocalConnectionIncidents.claimDelivery(context) }.getOrNull() ?: return
        val active = synchronized(lock) {
            if (closed || route !== selected || flight != null) return
            Flight(selected).also { flight = it }
        }
        fun admitted(): Boolean =
            !active.cancelled.get() && validRoute(active.route) &&
                runCatching { LocalConnectionIncidents.deliveryIsCurrent(context, ticket) }.getOrDefault(false) &&
                !active.cancelled.get() && route === active.route

        // A second watcher is deliberate: the broadcast wakes/aborts promptly,
        // but durable state and the command fence also cover missed callbacks,
        // network replacement, process changes and grant rotation.
        val observer = scope.launch(Dispatchers.IO) {
            val start = android.os.SystemClock.elapsedRealtime()
            while (isActive && !active.cancelled.get()) {
                if (android.os.SystemClock.elapsedRealtime() - start >= REQUEST_TIMEOUT_MS || !admitted()) {
                    active.close()
                    break
                }
                delay(LEASE_POLL_MS)
            }
        }
        try {
            val response = if (admitted()) try {
                val socket = LocalSocket()
                active.socket.set(socket)
                if (!admitted()) {
                    active.close()
                    null
                } else {
                    socket.connect(LocalSocketAddress(selected.path, LocalSocketAddress.Namespace.FILESYSTEM))
                    // Credentials belong to the connected fd. A pathname,
                    // a port, or a password alone would not authenticate Xray.
                    if (!verifiedPeer(socket) || !admitted()) {
                        throw IOException("Unverified local peer")
                    }
                    socket.soTimeout = IO_TIMEOUT_MS
                    HermesHttpsTransport().post(
                        HermesIncidentContract.HOST, socket.inputStream, socket.outputStream,
                        routeAllowed = ::admitted,
                    ) {
                        if (!admitted()) null else LocalConnectionIncidents.openDeliveryBody(context, ticket)?.let {
                            HermesWireRequest(it.body, it.bearer, ::admitted)
                        }
                    }
                }
            } catch (_: Exception) {
                // TLS, socket and storage details must never leave this worker.
                null
            } else null
            if (admitted()) runCatching {
                // Do not take command/protection locks while the queue file is
                // locked. Live invalidation also closes the socket itself.
                LocalConnectionIncidents.completeDelivery(context, ticket, response) {
                    !active.cancelled.get() && route === selected
                }
            }
        } finally {
            observer.cancel()
            active.close()
            synchronized(lock) { if (flight === active) flight = null }
        }
    }

    override fun close() {
        synchronized(lock) {
            closed = true
            invalidateRouteLocked()
            wake.close()
        }
        worker.cancel()
    }

    companion object {
        private const val IDLE_CHECK_MS = 30_000L
        private const val LEASE_POLL_MS = 350L
        private const val IO_TIMEOUT_MS = 5_000
        private const val REQUEST_TIMEOUT_MS = 12_000L
    }
}
