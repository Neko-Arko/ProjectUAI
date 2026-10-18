package dev.projectuai.relay.update

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import okhttp3.Call
import okhttp3.EventListener
import okhttp3.OkHttpClient
import okhttp3.Protocol
import okhttp3.Response
import okhttp3.ResponseBody
import okhttp3.ResponseBody.Companion.toResponseBody
import okio.Buffer
import okio.Source
import okio.Timeout
import okio.buffer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

class GitHubFetcherLifecycleTest {
    @Test
    fun `cancelling while headers wait cancels the native call and never dispatches again`() = runBlocking {
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val cancelled = CountDownLatch(1)
        val failed = CountDownLatch(1)
        val requests = AtomicInteger(0)
        val output = ByteArrayOutputStream()
        val client = OkHttpClient.Builder().retryOnConnectionFailure(false).eventListener(object : EventListener() {
            override fun canceled(call: Call) { cancelled.countDown() }
            override fun callFailed(call: Call, ioe: IOException) { failed.countDown() }
        }).addInterceptor { chain ->
            requests.incrementAndGet()
            entered.countDown()
            if (!release.await(5, TimeUnit.SECONDS)) throw IOException("fixture release timeout")
            if (chain.call().isCanceled()) throw IOException("fixture call cancelled")
            Response.Builder().request(chain.request()).protocol(Protocol.HTTP_1_1)
                .code(200).message("OK").body("must not arrive".toResponseBody()).build()
        }.build()
        val download = launch(Dispatchers.IO) {
            GitHubFetcher("1.1.0", client).download("https://github.com/test", 32, output) { _, _ -> }
        }
        try {
            assertTrue(entered.await(2, TimeUnit.SECONDS))
            download.cancel()
            // The interceptor remains blocked: cancellation must reach Call.cancel
            // independently instead of waiting for the upstream response.
            assertTrue(cancelled.await(2, TimeUnit.SECONDS))
            release.countDown()
            assertTrue(failed.await(2, TimeUnit.SECONDS))
        } finally {
            release.countDown()
            download.cancelAndJoin()
            client.dispatcher.executorService.shutdown()
            assertTrue(client.dispatcher.executorService.awaitTermination(2, TimeUnit.SECONDS))
        }
        assertEquals(0, output.size())
        assertEquals(1, requests.get())
    }

    @Test
    fun `cancelling while a body waits closes the source and prevents later writes`() = runBlocking {
        val waiting = CountDownLatch(1)
        val release = CountDownLatch(1)
        val cancelled = CountDownLatch(1)
        val closed = CountDownLatch(1)
        val requests = AtomicInteger(0)
        val output = ByteArrayOutputStream()
        val client = OkHttpClient.Builder().retryOnConnectionFailure(false).eventListener(object : EventListener() {
            override fun canceled(call: Call) { cancelled.countDown() }
        }).addInterceptor { chain ->
            requests.incrementAndGet()
            val source = object : Source {
                var first = true
                override fun read(sink: Buffer, byteCount: Long): Long {
                    if (first) {
                        first = false
                        sink.writeUtf8("head")
                        return 4
                    }
                    waiting.countDown()
                    if (!release.await(5, TimeUnit.SECONDS)) throw IOException("fixture release timeout")
                    // A buffered read can win the socket-cancellation race and
                    // still return bytes. The fetcher must not publish them.
                    sink.writeUtf8("late")
                    return 4
                }
                override fun timeout(): Timeout = Timeout.NONE
                override fun close() { closed.countDown() }
            }.buffer()
            val body = object : ResponseBody() {
                override fun contentType() = null
                override fun contentLength() = -1L
                override fun source() = source
            }
            Response.Builder().request(chain.request()).protocol(Protocol.HTTP_1_1)
                .code(200).message("OK").body(body).build()
        }.build()
        val download = launch(Dispatchers.IO) {
            GitHubFetcher("1.1.0", client).download("https://github.com/test", 32, output) { _, _ -> }
        }
        try {
            assertTrue(waiting.await(2, TimeUnit.SECONDS))
            assertEquals("head", output.toString(Charsets.UTF_8.name()))
            download.cancel()
            assertTrue(cancelled.await(2, TimeUnit.SECONDS))
            release.countDown()
            assertTrue(closed.await(2, TimeUnit.SECONDS))
        } finally {
            release.countDown()
            download.cancelAndJoin()
            client.dispatcher.executorService.shutdown()
            assertTrue(client.dispatcher.executorService.awaitTermination(2, TimeUnit.SECONDS))
        }
        assertEquals("head", output.toString(Charsets.UTF_8.name()))
        assertEquals(1, requests.get())
    }
}
