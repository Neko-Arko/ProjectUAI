package dev.projectuai.relay.server

import dev.projectuai.relay.RelayLog
import dev.projectuai.relay.data.MemorySettings
import dev.projectuai.relay.engine.JobEngine
import dev.projectuai.relay.protocol.Hello
import dev.projectuai.relay.protocol.RelayJson
import dev.projectuai.relay.protocol.StatusResponse
import kotlinx.serialization.decodeFromString
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.cancel
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.net.ServerSocket

class RelayServerTest {
    private lateinit var upstream: MockWebServer
    private lateinit var settings: MemorySettings
    private lateinit var engine: JobEngine
    private lateinit var server: RelayServer
    private lateinit var client: OkHttpClient
    private lateinit var scope: CoroutineScope

    @Before
    fun setUp() {
        upstream = MockWebServer()
        upstream.start()
        settings = MemorySettings()
        scope = CoroutineScope(Dispatchers.IO)
        engine = JobEngine("inst-test", scope)
        server = RelayServer(freePort(), "inst-test", settings, engine, RelayLog())
        server.start()
        client = OkHttpClient()
        awaitUp()
    }

    @After
    fun tearDown() {
        server.stop()
        scope.cancel()
        upstream.shutdown()
    }

    private fun call(
        path: String,
        method: String = "GET",
        body: String? = null,
        token: String? = null,
        headers: Map<String, String> = emptyMap(),
    ): Response {
        val builder = Request.Builder().url("http://127.0.0.1:${server.port}$path")
        headers.forEach { (key, value) -> builder.addHeader(key, value) }
        token?.let { builder.addHeader("Authorization", "Bearer $it") }
        when (method) {
            "GET" -> builder.get()
            "DELETE" -> builder.delete()
            else -> builder.method(method, (body ?: "").toRequestBody("application/json".toMediaType()))
        }
        return client.newCall(builder.build()).execute()
    }

    private fun awaitUp() {
        val deadline = System.currentTimeMillis() + 5000
        while (true) {
            try {
                call("/api/hello").close()
                return
            } catch (error: Exception) {
                if (System.currentTimeMillis() > deadline) throw error
                Thread.sleep(50)
            }
        }
    }

    private fun pair(): String {
        call("/api/pair", "POST", "{}").use { response ->
            assertEquals(200, response.code)
            return Regex("\"token\":\"([a-f0-9]{64})\"").find(response.body!!.string())!!.groupValues[1]
        }
    }

    @Test
    fun `hello advertises protocol 2 and the marker`() {
        call("/api/hello").use { response ->
            assertEquals(200, response.code)
            val hello = RelayJson.decodeFromString<Hello>(response.body!!.string())
            assertEquals(2, hello.protocol)
            assertEquals("uai-relay", hello.server)
            assertEquals("inst-test", hello.instance)
            assertTrue(hello.capabilities.inference.unlimited)
            assertEquals(1, hello.capabilities.inference.schema)
        }
    }

    @Test
    fun `pairing is idempotent and persists the token`() {
        val first = pair()
        val second = pair()
        assertEquals(first, second)
        assertEquals(first, settings.token)
    }

    @Test
    fun `pairing rejects a foreign origin and host`() {
        call("/api/pair", "POST", "{}", headers = mapOf("Origin" to "http://evil.test")).use { assertEquals(403, it.code) }
        call("/api/pair", "POST", "{}", headers = mapOf("Host" to "evil.test")).use { assertEquals(403, it.code) }
        call("/api/pair", "POST", "{}", headers = mapOf("Host" to "localhost.evil.test")).use { assertEquals(403, it.code) }
        call("/api/pair", "POST", "{}", headers = mapOf("Origin" to "http://127.0.0.1.evil.test")).use { assertEquals(403, it.code) }
    }

    @Test
    fun `inference requires the token`() {
        call("/api/inference", "POST", "{}").use { assertEquals(401, it.code) }
        call("/api/inference/whatever").use { assertEquals(401, it.code) }
    }

    @Test
    fun `an unknown id is a 404 that tells the client not to resubmit`() {
        val token = pair()
        call("/api/inference/inference_missing1", token = token).use { response ->
            assertEquals(404, response.code)
            assertTrue(response.body!!.string().contains("do not resubmit"))
        }
    }

    @Test
    fun `submits, relays and completes a provider request`() {
        val token = pair()
        upstream.enqueue(MockResponse().setResponseCode(200).setBody("{\"answer\":42}"))
        val body = """
            {"id":"inference_abcdef12","instance":"inst-test","url":"${upstream.url("/v1/chat/completions")}",
             "headers":{"Authorization":"Bearer key"},"body":"{}","timeout":180}
        """.trimIndent()
        call("/api/inference", "POST", body, token = token).use { response ->
            assertEquals(202, response.code)
            assertTrue(response.body!!.string().contains("\"state\":\"running\""))
        }
        val completed = poll(token, "inference_abcdef12")
        assertTrue(completed.contains("\"state\":\"completed\""))
        assertTrue(completed.contains("answer"))
        assertEquals("Bearer key", upstream.takeRequest().getHeader("authorization"))
        call("/api/status", token = token).use { response ->
            val status = RelayJson.decodeFromString<StatusResponse>(response.body!!.string())
            assertEquals(1, status.activity.acceptedJobs)
            assertEquals(1, status.activity.completedJobs)
            assertEquals(0, status.activeJobs)
            assertTrue(status.lastClientAt > 0)
            assertTrue(status.capabilities.inference.unlimited)
        }
    }

    @Test
    fun `saved credentials are not evidence of a live client`() {
        settings.token = "a".repeat(64)
        call("/api/hello").close()
        call("/api/status").use { assertEquals(401, it.code) }
        call("/api/hello", token = "invalid").close()
        assertEquals(0L, server.lastClientAt)
        call("/api/hello", token = settings.token).use { assertEquals(200, it.code) }
        assertTrue(server.lastClientAt > 0)
    }

    @Test
    fun `negotiated zero timeout is accepted and cancellable`() {
        val token = pair()
        upstream.enqueue(MockResponse().setBody("{}").setBodyDelay(2, java.util.concurrent.TimeUnit.SECONDS))
        val body = """{"id":"inference_unlimited","instance":"inst-test","url":"${upstream.url("/v1")}","body":"{}","timeout":0}"""
        call("/api/inference", "POST", body, token = token).use { assertEquals(202, it.code) }
        call("/api/inference/inference_unlimited", "DELETE", token = token).use { assertEquals(200, it.code) }
        assertTrue(poll(token, "inference_unlimited").contains("cancelled"))
    }

    @Test
    fun `fractional timeout fails before dispatch and integer timeout reaches the provider`() {
        val token = pair()
        val body = """{"id":"inference_integer","instance":"inst-test","url":"${upstream.url("/v1")}","body":"{}","timeout":299.948}"""
        call("/api/inference", "POST", body, token = token).use { response ->
            assertEquals(400, response.code)
            assertTrue(response.body!!.string().contains("invalid request"))
        }
        assertEquals(0, upstream.requestCount)
        assertEquals(0, engine.activity().acceptedJobs)
        upstream.enqueue(MockResponse().setBody("integer accepted"))
        call("/api/inference", "POST", body.replace("299.948", "300"), token = token).use { response ->
            assertEquals(202, response.code)
        }
        assertTrue(poll(token, "inference_integer").contains("integer accepted"))
        assertEquals(1, upstream.requestCount)
    }

    @Test
    fun `a stale instance is refused`() {
        val token = pair()
        val body = """
            {"id":"inference_abcdef12","instance":"old","url":"https://provider.test/v1","headers":{},"body":"{}","timeout":180}
        """.trimIndent()
        call("/api/inference", "POST", body, token = token).use { assertEquals(409, it.code) }
    }

    private fun poll(token: String, id: String): String {
        val deadline = System.currentTimeMillis() + 5000
        while (System.currentTimeMillis() < deadline) {
            call("/api/inference/$id", token = token).use { response ->
                val text = response.body!!.string()
                if (!text.contains("\"state\":\"running\"")) return text
            }
            Thread.sleep(20)
        }
        error("job did not finish")
    }

    private companion object {
        fun freePort(): Int = ServerSocket(0).use { it.localPort }
    }
}
