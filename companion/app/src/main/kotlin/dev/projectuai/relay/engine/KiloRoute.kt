package dev.projectuai.relay.engine

import dev.projectuai.relay.protocol.KiloCapability
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import okhttp3.Call
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.ResponseBody.Companion.toResponseBody
import okhttp3.Headers
import okhttp3.Protocol
import java.io.InterruptedIOException
import java.util.concurrent.TimeUnit

interface KiloConnection {
    val generation: Int
    fun client(check: () -> Unit): OkHttpClient
    fun rotate(expected: Int, check: () -> Unit)
    fun capability(): KiloCapability
    fun close()
}

/** Only a completed anonymous quota refusal permits resending a POST. */
class KiloRoute(private val connection: KiloConnection, private val clock: () -> Long = System::currentTimeMillis) {
    @Volatile private var directUntil = 0L
    private data class Refusal(val until: Long, val headers: Headers, val body: String)
    @Volatile private var refusal: Refusal? = null
    fun capability(): KiloCapability {
        val current = connection.capability()
        return if (refusal?.let { clock() < it.until } == true) current.copy(available = false, state = "limited",
            message = "Kilo free access is limited on the available connections. Wait a minute or choose another provider.")
        else current
    }
    fun close() = connection.close()

    fun execute(request: Request, direct: OkHttpClient, timeout: Int, cancelled: () -> Boolean, onCall: (Call) -> Unit): Response {
        val started = System.nanoTime()
        fun remaining(): Long = if (timeout == 0) Long.MAX_VALUE else timeout * 1000L - (System.nanoTime() - started) / 1_000_000L
        val check = { if (cancelled() || remaining() <= 0) throw InterruptedIOException("Kilo request stopped") }
        refusal?.takeIf { clock() < it.until }?.let {
            check()
            return Response.Builder().request(request).protocol(Protocol.HTTP_1_1).code(429).message("Too Many Requests")
                .headers(it.headers).header("x-should-retry", "false").body(it.body.toResponseBody()).build()
        }
        var tunnel = clock() < directUntil
        var retried = false
        while (true) {
            check()
            val client = if (tunnel) connection.client(check) else direct
            val epoch = connection.generation
            check()
            val call = client.newCall(request)
            onCall(call)
            check()
            call.timeout().timeout(if (timeout == 0) 0 else remaining().coerceAtLeast(1), TimeUnit.MILLISECONDS)
            val response = call.execute()
            if (response.code != 429) return response
            val quotaBytes = try { response.peekBody(65537).bytes() } catch (error: Exception) { response.close(); throw error }
            // A replay requires the entire refusal, never a truncated prefix.
            if (quotaBytes.size > 65536) return response
            val quotaBody = quotaBytes.toString(Charsets.UTF_8)
            if (!quota(quotaBody)) return response
            if (!tunnel) {
                directUntil = clock() + 3_600_000L
                response.close(); tunnel = true
            } else if (!retried) {
                response.close(); retried = true
                connection.rotate(epoch, check)
            } else {
                refusal = Refusal(clock() + 60_000L, response.headers, quotaBody)
                return response.newBuilder().header("x-should-retry", "false").build()
            }
        }
    }

    companion object {
        private val paths = listOf("/api/gateway", "/api/gateway/v1", "/api/v1").flatMap { base ->
            listOf("/chat/completions", "/responses", "/messages").map { base + it }
        }.toSet()
        fun eligible(request: Request, body: String): Boolean {
            val url = request.url
            if (url.scheme != "https" || url.port != 443 || url.host !in setOf("api.kilo.ai", "ai-gateway.kilo.ai") ||
                url.encodedPath !in paths || url.query != null || url.username.isNotEmpty() || url.password.isNotEmpty()) return false
            if (request.headers.names().any { Regex("authorization|api[-_]?key|token|cookie|organization", RegexOption.IGNORE_CASE).containsMatchIn(it) }) return false
            return runCatching {
                val model = Json.parseToJsonElement(body).jsonObject["model"]?.jsonPrimitive?.content.orEmpty()
                model == "kilo-auto/free" || model.endsWith(":free")
            }.getOrDefault(false)
        }
        fun quota(body: String): Boolean = runCatching {
            Json.parseToJsonElement(body).jsonObject["error"]?.jsonObject?.get("code")?.jsonPrimitive?.content == "PROMOTION_MODEL_LIMIT_REACHED"
        }.getOrDefault(false)
    }
}
