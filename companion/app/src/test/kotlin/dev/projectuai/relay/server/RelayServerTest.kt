package dev.projectuai.relay.server

import dev.projectuai.relay.RelayLog
import dev.projectuai.relay.data.MemorySettings
import dev.projectuai.relay.engine.JobEngine
import dev.projectuai.relay.protocol.Hello
import dev.projectuai.relay.protocol.ExecutorRequest
import dev.projectuai.relay.protocol.ExecutorResponse
import kotlinx.serialization.encodeToString
import dev.projectuai.relay.protocol.RelayJson
import dev.projectuai.relay.protocol.StatusResponse
import dev.projectuai.relay.protocol.SubmitRequest
import dev.projectuai.relay.protocol.ErrorBody
import dev.projectuai.relay.protocol.JobState
import dev.projectuai.relay.protocol.JobView
import kotlinx.serialization.decodeFromString
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.cancel
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import okio.BufferedSink
import java.io.ByteArrayOutputStream
import java.net.ServerSocket
import java.util.zip.GZIPOutputStream

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

    private fun executor(token: String, method: String, path: String, body: String = ""): ExecutorResponse {
        val input = RelayJson.encodeToString(ExecutorRequest(1, method, path, token, body))
        return call("/api/executor", "POST", input).use {
            assertEquals(200, it.code)
            assertEquals("no-store", it.header("Cache-Control"))
            RelayJson.decodeFromString<ExecutorResponse>(it.body!!.string())
        }
    }

    @Test
    fun `executor POST preserves authentication and rejects browser and unknown operations`() {
        val token = pair()
        assertEquals(401, executor("bad", "GET", "/api/status").status)
        assertEquals(200, executor(token, "GET", "/api/status").status)
        assertEquals(400, executor(token, "POST", "/api/pair").status)
        assertEquals(400, executor(token, "GET", "https://other.test").status)
        assertEquals(404, executor(token, "GET", "/api/inference/missing").status)
        val body = RelayJson.encodeToString(ExecutorRequest(1, "GET", "/api/status", token))
        for (headers in listOf(mapOf("Host" to "evil.test"), mapOf("Origin" to "http://127.0.0.1"),
            mapOf("Sec-Fetch-Site" to "cross-site"))) {
            call("/api/executor", "POST", body, headers = headers).use { assertEquals(403, it.code) }
        }
        val plain = Request.Builder().url("http://127.0.0.1:${server.port}/api/executor")
            .post(body.toRequestBody("text/plain".toMediaType())).build()
        client.newCall(plain).execute().use { assertEquals(403, it.code) }
        assertEquals(0, upstream.requestCount)
    }

    @Test
    fun `executor POST uses the same engine for submission polling replay and cancellation`() {
        val token = pair()
        upstream.enqueue(MockResponse().setBody("executor answer").setBodyDelay(300, java.util.concurrent.TimeUnit.MILLISECONDS))
        val body = """{"id":"inference_executor","instance":"inst-test","url":"${upstream.url("/v1")}","body":"{}","timeout":0}"""
        assertEquals(202, executor(token, "POST", "/api/inference", body).status)
        assertEquals(202, executor(token, "POST", "/api/inference", body).status)
        assertTrue(poll(token, "inference_executor").contains("executor answer"))
        assertTrue(executor(token, "GET", "/api/inference/inference_executor").body.contains("executor answer"))
        assertEquals(1, upstream.requestCount)
        assertEquals(409, executor(token, "POST", "/api/inference", body.replace("inst-test", "stale")).status)
        upstream.enqueue(MockResponse().setBody("later").setBodyDelay(2, java.util.concurrent.TimeUnit.SECONDS))
        assertEquals(202, executor(token, "POST", "/api/inference", body.replace("inference_executor", "inference_cancel")).status)
        assertEquals(200, executor(token, "DELETE", "/api/inference/inference_cancel").status)
        assertTrue(executor(token, "GET", "/api/inference/inference_cancel").body.contains("cancelled"))
    }

    @Test
    fun `executor rejects expanded response before native delivery without discarding or replaying receipt`() {
        val token = pair()
        // This provider body fits the raw cap and the direct JSON response, but
        // the second layer of escaping exceeds the native 8 MiB response cap.
        val answer = "\"".repeat((ResponseBodySize.LIMIT / 4).toInt())
        val id = "inference_executor_limit"
        upstream.enqueue(MockResponse().setBody(answer))
        val submission = RelayJson.encodeToString(SubmitRequest(id, "inst-test", upstream.url("/v1").toString(), body = "{}"))
        assertEquals(202, executor(token, "POST", "/api/inference", submission).status)
        val receipt = awaitReceipt(id)
        assertEquals(JobState.COMPLETED, receipt.state)
        assertTrue(ResponseBodySize.bytes(receipt) < ResponseBodySize.LIMIT)
        assertTrue(ResponseBodySize.bytes(receipt, 200) > ResponseBodySize.LIMIT)
        repeat(2) {
            val response = executor(token, "GET", "/api/inference/$id")
            assertEquals(413, response.status)
            assertEquals(ResponseBodySize.FAILURE, RelayJson.decodeFromString<ErrorBody>(response.body).error)
            assertTrue(response.body.length < 256)
            assertEquals(answer, engine.poll(id)!!.body)
        }
        // A matching retry is still the original completed job, even when its
        // executor response cannot be delivered. No second provider submission.
        assertEquals(413, executor(token, "POST", "/api/inference", submission).status)
        call("/api/inference/$id", token = token).use {
            assertEquals(200, it.code)
            assertEquals(answer, RelayJson.decodeFromString<JobView>(it.body!!.string()).body)
        }
        assertEquals(1, upstream.requestCount)
        assertEquals(1, engine.activity().acceptedJobs)
        assertEquals(token, settings.token)
    }

    @Test
    fun `direct polling rejects response expansion while retaining the exact completed body`() {
        val token = pair()
        val answer = "\"".repeat((ResponseBodySize.LIMIT / 2).toInt())
        val id = "inference_direct_limit"
        upstream.enqueue(MockResponse().setBody(answer))
        val submission = RelayJson.encodeToString(SubmitRequest(id, "inst-test", upstream.url("/v1").toString(), body = "{}"))
        call("/api/inference", "POST", submission, token = token).use { assertEquals(202, it.code) }
        assertEquals(JobState.COMPLETED, awaitReceipt(id).state)
        repeat(2) {
            call("/api/inference/$id", token = token).use {
                assertEquals(413, it.code)
                val body = it.body!!.string()
                assertTrue(body.length < 256)
                assertEquals(ResponseBodySize.FAILURE, RelayJson.decodeFromString<ErrorBody>(body).error)
            }
            assertEquals(answer, engine.poll(id)!!.body)
        }
        assertEquals(1, upstream.requestCount)
    }

    private fun awaitReceipt(id: String): JobView {
        val deadline = System.currentTimeMillis() + 5000
        while (System.currentTimeMillis() < deadline) {
            engine.poll(id)?.let { if (it.state != JobState.RUNNING) return it }
            Thread.sleep(20)
        }
        error("job did not finish")
    }

    private fun gzip(text: String): ByteArray = ByteArrayOutputStream().also { output ->
        GZIPOutputStream(output).use { it.write(text.toByteArray(Charsets.UTF_8)) }
    }.toByteArray()

    private fun encodedCall(path: String, bytes: ByteArray, encoding: String? = "gzip", chunked: Boolean = false, token: String? = null): Response {
        val body = object : RequestBody() {
            override fun contentType() = "application/json".toMediaType()
            override fun contentLength() = if (chunked) -1L else bytes.size.toLong()
            override fun writeTo(sink: BufferedSink) { sink.write(bytes) }
        }
        val request = Request.Builder().url("http://127.0.0.1:${server.port}$path").post(body)
        if (encoding != null) request.header("Content-Encoding", encoding)
        if (token != null) request.header("Authorization", "Bearer $token")
        return client.newCall(request.build()).execute()
    }

    @Test
    fun `compressed executor messages preserve large nested JSON and same ID without repairing pairing`() {
        val token = pair()
        val providerBody = RelayJson.encodeToString(mapOf("message" to "A long message: \"quoted\" \\ path\n你好 🌿".repeat(4000)))
        upstream.enqueue(MockResponse().setBody("large message answered"))
        val submission = RelayJson.encodeToString(SubmitRequest("inference_compressed", "inst-test", upstream.url("/v1").toString(),
            mapOf("Authorization" to "Bearer private-test-key"), providerBody, 0))
        val envelope = RelayJson.encodeToString(ExecutorRequest(1, "POST", "/api/inference", token, submission))
        // POST implementations may use a declared body length or chunked transfer,
        // and may omit the encoding header. All retries refer to the same job.
        for ((encoding, chunked) in listOf("gzip" to false, "gzip" to true, null to true)) {
            encodedCall("/api/executor", gzip(envelope), encoding, chunked).use {
                assertEquals(200, it.code)
                assertEquals(202, RelayJson.decodeFromString<ExecutorResponse>(it.body!!.string()).status)
            }
        }
        assertTrue(poll(token, "inference_compressed").contains("large message answered"))
        val sent = upstream.takeRequest()
        assertEquals(providerBody, sent.body.readUtf8())
        assertEquals("Bearer private-test-key", sent.getHeader("Authorization"))
        assertEquals(1, upstream.requestCount)
        assertEquals(token, settings.token)
        assertEquals(1, engine.activity().acceptedJobs)
    }

    @Test
    fun `compressed pairing direct submission and authenticated polling keep their contracts`() {
        val token = encodedCall("/api/pair", gzip("{}"), chunked = true).use {
            assertEquals(200, it.code)
            RelayJson.decodeFromString<dev.projectuai.relay.protocol.PairResponse>(it.body!!.string()).token
        }
        upstream.enqueue(MockResponse().setBody("direct gzip answer"))
        val submission = RelayJson.encodeToString(SubmitRequest("inference_direct_gzip", "inst-test", upstream.url("/v1").toString(), body = "{}"))
        encodedCall("/api/inference", gzip(submission), token = token).use { assertEquals(202, it.code) }
        assertTrue(poll(token, "inference_direct_gzip").contains("direct gzip answer"))
        val envelope = RelayJson.encodeToString(ExecutorRequest(1, "GET", "/api/status", "wrong-token"))
        encodedCall("/api/executor", gzip(envelope)).use {
            assertEquals(401, RelayJson.decodeFromString<ExecutorResponse>(it.body!!.string()).status)
        }
        assertEquals(1, upstream.requestCount)
    }

    @Test
    fun `invalid compressed and oversized executor bodies cannot start work`() {
        pair()
        val cases = listOf(
            Triple(gzip("{}").copyOf(12), "gzip", 400),
            Triple("{}".toByteArray(), "br", 415),
            Triple(byteArrayOf(0xc3.toByte(), 0x28), "identity", 400),
            Triple(gzip("x".repeat(RelayServer.MAX_REQUEST_BYTES.toInt() + 1)), "gzip", 413),
            Triple(ByteArray(RelayServer.MAX_REQUEST_BYTES.toInt() + 1) { 32 }, "identity", 413),
        )
        for ((bytes, encoding, expected) in cases) {
            encodedCall("/api/executor", bytes, encoding, chunked = true).use {
                assertEquals(200, it.code)
                assertEquals(expected, RelayJson.decodeFromString<ExecutorResponse>(it.body!!.string()).status)
            }
        }
        assertEquals(0, upstream.requestCount)
        assertEquals(0, engine.activity().acceptedJobs)
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
