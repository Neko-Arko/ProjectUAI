package dev.projectuai.relay.engine

import dev.projectuai.relay.protocol.KiloCapability
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import okhttp3.Protocol
import okhttp3.ResponseBody.Companion.toResponseBody
import okhttp3.ResponseBody
import okio.Buffer
import okio.Source
import okio.Timeout
import okio.buffer
import org.junit.Assert.*
import org.junit.Test
import java.io.IOException
import java.io.InterruptedIOException
import java.util.concurrent.TimeUnit

class KiloRouteTest {
    private val body = """{"model":"kilo-auto/free","messages":[]}"""
    private val request = Request.Builder().url("https://api.kilo.ai/api/gateway/chat/completions").post(body.toRequestBody()).build()
    private val quota = """{"error":{"code":"PROMOTION_MODEL_LIMIT_REACHED"}}"""
    private fun client(reply: (Request) -> Pair<Int, String>) = OkHttpClient.Builder().addInterceptor { chain ->
        val (code, text) = reply(chain.request())
        Response.Builder().request(chain.request()).protocol(Protocol.HTTP_1_1).code(code).message("fixture")
            .body(text.toResponseBody()).build()
    }.build()
    private class Connection(val proxy: OkHttpClient) : KiloConnection {
        override var generation = 0
        var starts = 0
        var rotations = 0
        var beforeClient: (() -> Unit)? = null
        override fun client(check: () -> Unit): OkHttpClient { starts++; beforeClient?.invoke(); check(); return proxy }
        override fun rotate(expected: Int, check: () -> Unit) { check(); if (expected == generation) { generation++; rotations++ } }
        override fun capability() = KiloCapability(enabled = true, available = true, state = "ready")
        override fun close() = Unit
    }
    @Test fun anonymousFreeScopeExcludesCredentialsAndOtherRoutes() {
        assertTrue(KiloRoute.eligible(request, body))
        for (name in listOf("Authorization", "Cookie", "x-api-key", "x-token", "organization"))
            assertFalse(KiloRoute.eligible(request.newBuilder().header(name, "private").build(), body))
        for (url in listOf("http://api.kilo.ai/api/gateway/chat/completions", "https://api.kilo.ai.evil.test/api/gateway/chat/completions",
            "https://api.kilo.ai:444/api/gateway/chat/completions", "https://api.kilo.ai/api/gateway/models", "https://api.kilo.ai/api/gateway/chat/completions?key=private"))
            assertFalse(KiloRoute.eligible(request.newBuilder().url(url).build(), body))
        assertFalse(KiloRoute.eligible(request, """{"model":"paid-model"}"""))
        // Kilo spells free routes ":free", "/free" and "-free".
        for (model in listOf("reflection/beam-free", "openrouter/free", "kilo-auto/free"))
            assertTrue(KiloRoute.eligible(request, """{"model":"$model"}"""))
        for (model in listOf("paid-model", "free", "carefree", "kilo-auto/free-tier"))
            assertFalse(KiloRoute.eligible(request, """{"model":"$model"}"""))
    }
    @Test fun quotaRecoveryPreservesPayloadAndOneDeadline() {
        var directCalls = 0
        var proxyCalls = 0
        val timeouts = mutableListOf<Long>()
        val direct = client { directCalls++; 429 to quota }
        val connection = Connection(client { assertEquals(request, it); proxyCalls++; 200 to "data: [DONE]\n\n" })
        connection.beforeClient = { Thread.sleep(30) }
        val route = KiloRoute(connection)
        route.execute(request, direct, 5, { false }) {}.use { assertEquals(200, it.code); assertTrue(it.body!!.string().contains("[DONE]")) }
        assertEquals(1, directCalls); assertEquals(1, proxyCalls); assertEquals(0, connection.rotations)
        val budgetClient = OkHttpClient.Builder().addInterceptor { chain ->
            timeouts += chain.call().timeout().timeoutNanos()
            Response.Builder().request(chain.request()).protocol(Protocol.HTTP_1_1).code(200).message("ok").body("ok".toResponseBody()).build()
        }.build()
        val budgetConnection = Connection(budgetClient).also { it.beforeClient = { Thread.sleep(30) } }
        KiloRoute(budgetConnection).execute(request, direct, 5, { false }) {}.close()
        assertTrue(timeouts.single() in 1 until TimeUnit.SECONDS.toNanos(5))
        KiloRoute(budgetConnection).execute(request, direct, 0, { false }) {}.close()
        assertEquals(0L, timeouts.last())
    }
    @Test fun exhaustedExitsRotateOnceAndSuppressRepeatedSends() {
        var now = 1000L
        var calls = 0
        val upstream = client { calls++; 429 to quota }
        val connection = Connection(upstream)
        val route = KiloRoute(connection) { now }
        repeat(2) { route.execute(request, upstream, 5, { false }) {}.use {
            assertEquals(429, it.code); assertEquals("false", it.header("x-should-retry"))
        } }
        assertEquals(3, calls); assertEquals(1, connection.rotations)
        assertEquals("limited", route.capability().state)
        assertFalse(route.capability().available)
        now += 61000
        assertEquals("ready", route.capability().state)
        route.execute(request, upstream, 5, { false }) {}.close()
        assertEquals(5, calls)
    }
    @Test fun ordinaryAndIncompleteErrorsNeverReplay() {
        for ((code, text) in listOf(429 to "busy", 500 to "error", 401 to "denied", 429 to (quota + " ".repeat(65536)))) {
            var calls = 0
            val direct = client { calls++; code to text }
            val connection = Connection(client { fail("Unexpected tunnel request"); 200 to "" })
            KiloRoute(connection).execute(request, direct, 5, { false }) {}.use { assertEquals(code, it.code) }
            assertEquals(1, calls); assertEquals(0, connection.starts)
        }
        var calls = 0
        val direct = client { calls++; throw IOException("partial connection") }
        val connection = Connection(direct)
        assertThrows(IOException::class.java) { KiloRoute(connection).execute(request, direct, 5, { false }) {} }
        assertEquals(1, calls); assertEquals(0, connection.starts)
    }
    @Test fun cancellationDuringSetupCannotDispatch() {
        var cancelled = false
        val direct = client { 429 to quota }
        val connection = Connection(client { fail("Cancelled request dispatched"); 200 to "" })
        connection.beforeClient = { cancelled = true }
        assertThrows(InterruptedIOException::class.java) { KiloRoute(connection).execute(request, direct, 5, { cancelled }) {} }
    }
    @Test fun setupCannotExtendTheOriginalDeadline() {
        val direct = client { 429 to quota }
        val connection = Connection(client { fail("Expired request dispatched"); 200 to "" })
        connection.beforeClient = { Thread.sleep(1100) }
        assertThrows(InterruptedIOException::class.java) { KiloRoute(connection).execute(request, direct, 1, { false }) {} }
    }
    @Test fun completeLookingJsonWithoutResponseCompletionCannotReplay() {
        var reads = 0
        val source = object : Source {
            override fun read(sink: Buffer, byteCount: Long): Long {
                if (reads++ > 0) throw IOException("Response connection lost")
                sink.writeUtf8(quota)
                return quota.toByteArray().size.toLong()
            }
            override fun timeout() = Timeout.NONE
            override fun close() = Unit
        }.buffer()
        val direct = OkHttpClient.Builder().addInterceptor { chain ->
            Response.Builder().request(chain.request()).protocol(Protocol.HTTP_1_1).code(429).message("fixture")
                .body(object : ResponseBody() {
                    override fun contentType() = null
                    override fun contentLength() = -1L
                    override fun source() = source
                }).build()
        }.build()
        val connection = Connection(client { fail("Incomplete refusal replayed"); 200 to "" })
        assertThrows(IOException::class.java) { KiloRoute(connection).execute(request, direct, 5, { false }) {} }
        assertEquals(0, connection.starts)
    }
}
