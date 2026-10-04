package com.aeidolon.vaultexplorer.saf

import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.Callable
import java.util.concurrent.ExecutionException
import java.util.concurrent.Future
import java.util.concurrent.ThreadFactory
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.atomic.AtomicInteger

/** Runs potentially blocking calls into third-party document providers with
 * a bounded wait. Some cloud-backed providers never return from a delete for
 * stale documents, which otherwise leaves a native file operation pending
 * forever. The bounded worker pool also prevents repeated stuck Binder calls
 * from creating an unbounded number of threads. */
internal object SafProviderOperationRunner {
    private const val DELETE_TIMEOUT_SECONDS = 15L
    private val threadIds = AtomicInteger()
    private val executor = ThreadPoolExecutor(
        2,
        2,
        0L,
        TimeUnit.MILLISECONDS,
        ArrayBlockingQueue(8),
        ThreadFactory { task ->
            Thread(task, "saf-provider-delete-${threadIds.incrementAndGet()}").apply {
                isDaemon = true
            }
        },
        ThreadPoolExecutor.AbortPolicy(),
    )

    fun <T> runDelete(description: String, operation: () -> T): T {
        val future: Future<T> = try {
            executor.submit(Callable { operation() })
        } catch (e: RejectedExecutionException) {
            throw SafIOException("SAF provider is busy; could not start $description", e)
        }

        try {
            return future.get(DELETE_TIMEOUT_SECONDS, TimeUnit.SECONDS)
        } catch (e: TimeoutException) {
            cancel(future)
            throw SafIOException("Timed out deleting $description after ${DELETE_TIMEOUT_SECONDS}s", e)
        } catch (e: InterruptedException) {
            cancel(future)
            Thread.currentThread().interrupt()
            throw SafIOException("Interrupted while deleting $description", e)
        } catch (e: ExecutionException) {
            val cause = e.cause ?: e
            if (cause is Exception) throw cause
            throw SafIOException("Failed deleting $description", cause)
        }
    }

    private fun cancel(future: Future<*>) {
        future.cancel(true)
        if (future is Runnable) executor.remove(future)
    }
}
