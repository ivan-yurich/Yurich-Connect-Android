package com.tecclub.flutter_singbox.bg

import android.net.DnsResolver
import android.os.Build
import android.os.CancellationSignal
import android.system.ErrnoException
import android.util.Log
import androidx.annotation.RequiresApi
import io.nekohasekai.libbox.ExchangeContext
import io.nekohasekai.libbox.LocalDNSTransport
import kotlinx.coroutines.CancellableContinuation
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.asExecutor
import kotlinx.coroutines.runInterruptible
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withTimeout
import java.net.InetAddress
import java.net.UnknownHostException

object LocalResolver : LocalDNSTransport {

    private const val TAG = "LocalResolver"
    private const val RCODE_NXDOMAIN = 3
    private const val RCODE_SERVFAIL = 2
    private const val DNS_TIMEOUT_MS = 6_000L

    override fun raw(): Boolean {
        return Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q
    }

    @RequiresApi(Build.VERSION_CODES.Q)
    override fun exchange(ctx: ExchangeContext, message: ByteArray) {
        runDnsOperation(ctx) {
            val defaultNetwork = withTimeout(DNS_TIMEOUT_MS) {
                DefaultNetworkMonitor.require()
            }
            withTimeout(DNS_TIMEOUT_MS) {
                suspendCancellableCoroutine { continuation ->
                val signal = CancellationSignal()
                    bindCancellation(ctx, signal, continuation)
                val callback = object : DnsResolver.Callback<ByteArray> {
                    override fun onAnswer(answer: ByteArray, rcode: Int) {
                        if (rcode == 0) {
                            ctx.rawSuccess(answer)
                        } else {
                            ctx.errorCode(rcode)
                        }
                            continuation.resumeSafely()
                    }

                    override fun onError(error: DnsResolver.DnsException) {
                        when (val cause = error.cause) {
                            is ErrnoException -> {
                                ctx.errnoCode(cause.errno)
                                    continuation.resumeSafely()
                                return
                            }
                        }
                            continuation.resumeExceptionSafely(error)
                    }
                }
                DnsResolver.getInstance().rawQuery(
                    defaultNetwork,
                    message,
                    DnsResolver.FLAG_NO_RETRY,
                    Dispatchers.IO.asExecutor(),
                    signal,
                    callback
                )
            }
        }
        }
    }

    override fun lookup(ctx: ExchangeContext, network: String, domain: String) {
        runDnsOperation(ctx) {
            val defaultNetwork = withTimeout(DNS_TIMEOUT_MS) {
                DefaultNetworkMonitor.require()
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                withTimeout(DNS_TIMEOUT_MS) {
                    suspendCancellableCoroutine { continuation ->
                    val signal = CancellationSignal()
                        bindCancellation(ctx, signal, continuation)
                    val callback = object : DnsResolver.Callback<Collection<InetAddress>> {
                        @Suppress("ThrowableNotThrown")
                        override fun onAnswer(answer: Collection<InetAddress>, rcode: Int) {
                            if (rcode == 0) {
                                ctx.success((answer as Collection<InetAddress?>).mapNotNull { it?.hostAddress }
                                    .joinToString("\n"))
                            } else {
                                ctx.errorCode(rcode)
                            }
                                continuation.resumeSafely()
                        }

                        override fun onError(error: DnsResolver.DnsException) {
                            when (val cause = error.cause) {
                                is ErrnoException -> {
                                    ctx.errnoCode(cause.errno)
                                        continuation.resumeSafely()
                                    return
                                }
                            }
                                continuation.resumeExceptionSafely(error)
                        }
                    }
                    val type = when {
                        network.endsWith("4") -> DnsResolver.TYPE_A
                        network.endsWith("6") -> DnsResolver.TYPE_AAAA
                        else -> null
                    }
                    if (type != null) {
                        DnsResolver.getInstance().query(
                            defaultNetwork,
                            domain,
                            type,
                            DnsResolver.FLAG_NO_RETRY,
                            Dispatchers.IO.asExecutor(),
                            signal,
                            callback
                        )
                    } else {
                        DnsResolver.getInstance().query(
                            defaultNetwork,
                            domain,
                            DnsResolver.FLAG_NO_RETRY,
                            Dispatchers.IO.asExecutor(),
                            signal,
                            callback
                        )
                    }
                }
                }
            } else {
                val answer = try {
                    runInterruptible { defaultNetwork.getAllByName(domain) }
                } catch (e: UnknownHostException) {
                    ctx.errorCode(RCODE_NXDOMAIN)
                    return@runDnsOperation
                }
                ctx.success(answer.mapNotNull { it.hostAddress }.joinToString("\n"))
            }
        }
    }

    private fun runDnsOperation(ctx: ExchangeContext, operation: suspend () -> Unit) {
        try {
            runBlocking(Dispatchers.IO) {
                withTimeout(DNS_TIMEOUT_MS) {
                    operation()
                }
            }
        } catch (error: TimeoutCancellationException) {
            Log.w(TAG, "DNS operation timed out")
            ctx.errorCode(RCODE_SERVFAIL)
        } catch (error: Exception) {
            Log.w(TAG, "DNS operation failed", error)
            ctx.errorCode(RCODE_SERVFAIL)
        }
    }

    private fun bindCancellation(
        ctx: ExchangeContext,
        signal: CancellationSignal,
        continuation: CancellableContinuation<Unit>,
    ) {
        continuation.invokeOnCancellation { signal.cancel() }
        ctx.onCancel {
            signal.cancel()
            continuation.cancel()
        }
    }

    private fun CancellableContinuation<Unit>.resumeSafely() {
        try {
            resumeWith(Result.success(Unit))
        } catch (_: IllegalStateException) {
        }
    }

    private fun CancellableContinuation<Unit>.resumeExceptionSafely(error: Throwable) {
        try {
            resumeWith(Result.failure(error))
        } catch (_: IllegalStateException) {
        }
    }
}
