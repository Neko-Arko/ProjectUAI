package dev.projectuai.relay.server

import dev.projectuai.relay.RelayLog
import dev.projectuai.relay.data.RelaySettings
import dev.projectuai.relay.engine.JobEngine
import dev.projectuai.relay.protocol.CancelledResponse
import dev.projectuai.relay.protocol.ErrorBody
import dev.projectuai.relay.protocol.ExecutorRequest
import dev.projectuai.relay.protocol.ExecutorResponse
import dev.projectuai.relay.protocol.Hello
import dev.projectuai.relay.protocol.JobView
import dev.projectuai.relay.protocol.PairRequest
import dev.projectuai.relay.protocol.PairResponse
import dev.projectuai.relay.protocol.RelayJson
import dev.projectuai.relay.protocol.StatusResponse
import dev.projectuai.relay.protocol.SubmitRequest
import io.ktor.http.ContentType
import io.ktor.http.HttpStatusCode
import io.ktor.server.application.Application
import io.ktor.server.application.ApplicationCall
import io.ktor.server.cio.CIO
import io.ktor.server.engine.EmbeddedServer
import io.ktor.server.engine.embeddedServer
import io.ktor.server.response.respondText
import io.ktor.server.routing.delete
import io.ktor.server.routing.get
import io.ktor.server.routing.post
import io.ktor.server.routing.routing
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import java.security.MessageDigest
import java.security.SecureRandom

/**
 * The loopback relay server. Loopback-only, token-authenticated, and deliberately
 * narrow: it serves just the routes in the relay contract and nothing else. It never
 * serves files and never emits CORS headers.
 */
class RelayServer(
    val port: Int,
    val instance: String,
    private val settings: RelaySettings,
    private val engine: JobEngine,
    private val log: RelayLog,
    private val onPaired: (token: String, placeId: Long) -> Unit = { _, _ -> },
    private val onClientContact: (at: Long) -> Unit = {},
) {
    private var server: EmbeddedServer<*, *>? = null
    private val startedAt = System.currentTimeMillis()
    private val random = SecureRandom()
    private val pairLock = Any()
    private val pairTimes = ArrayDeque<Long>()

    @Volatile
    var lastPlaceId: Long = 0
        private set
    @Volatile var lastClientAt: Long = 0
        private set

    fun start() {
        if (server != null) return
        val created = embeddedServer(CIO, port = port, host = LOOPBACK) { module() }
        created.start(wait = false)
        server = created
        log.add("Relay listening on $LOOPBACK:$port")
    }

    fun stop() {
        server?.stop(500, 1500)
        server = null
        log.add("Relay stopped")
    }

    private fun Application.module() {
        routing {
            get("/api/hello") {
                // Discovery remains public; only a valid saved bearer counts as
                // continued client contact while Roblox is idle.
                if (call.request.headers["Authorization"] != null) call.authorised()
                call.respondJson(Hello(instance = instance))
            }
            post("/api/pair") { handlePair(call) }
            post("/api/executor") { handleExecutor(call) }
            post("/api/inference") {
                if (!call.authorised()) { call.respondJson(ErrorBody("bad token"), HttpStatusCode.Unauthorized); return@post }
                handleSubmit(call)
            }
            get("/api/inference/{id}") {
                if (!call.authorised()) { call.respondJson(ErrorBody("bad token"), HttpStatusCode.Unauthorized); return@get }
                handlePoll(call)
            }
            delete("/api/inference/{id}") {
                if (!call.authorised()) { call.respondJson(ErrorBody("bad token"), HttpStatusCode.Unauthorized); return@delete }
                handleCancel(call)
            }
            get("/api/status") {
                if (!call.authorised()) { call.respondJson(ErrorBody("bad token"), HttpStatusCode.Unauthorized); return@get }
                handleStatus(call)
            }
        }
    }

    // HttpPost returns only a body. Preserve operation status in an envelope.
    private suspend fun handleExecutor(call: ApplicationCall) {
        if (!loopbackHost(call.request.headers["Host"].orEmpty()) || call.request.headers["Origin"] != null ||
            call.request.headers["Sec-Fetch-Site"] != null ||
            call.request.headers["Content-Type"]?.substringBefore(';')?.trim()?.lowercase() != "application/json") {
            call.respondJson(ErrorBody("invalid executor transport origin"), HttpStatusCode.Forbidden); return
        }
        val text = requestText(call, executor = true) ?: return
        val input = decodeJson<ExecutorRequest>(text)
        if (input == null || input.schema != 1) {
            log.add("Executor request rejected: invalid JSON envelope or schema")
            call.respondExecutor(ErrorBody("invalid executor request; update the UAI client and Relay app; resetting pairing will not fix request encoding"), 400)
            return
        }
        if (!authorisedToken(input.token)) { call.respondExecutor(ErrorBody("bad token"), 401); return }
        val id = Regex("^/api/inference/([A-Za-z0-9_-]{1,128})$").matchEntire(input.path)?.groupValues?.get(1)
        when {
            input.method == "GET" && input.path == "/api/hello" -> call.respondExecutor(Hello(instance = instance))
            input.method == "GET" && input.path == "/api/status" -> call.respondExecutor(status())
            input.method == "POST" && input.path == "/api/inference" -> {
                val request = decodeJson<SubmitRequest>(input.body)
                if (request == null) { call.respondExecutor(ErrorBody("invalid request"), 400); return }
                when (val result = engine.submit(request)) {
                    is JobEngine.Submission.Accepted -> call.respondExecutor(result.view, 202)
                    is JobEngine.Submission.Rejected -> call.respondExecutor(ErrorBody(result.message), result.status)
                }
            }
            input.method == "GET" && id != null -> {
                val view = engine.poll(id)
                if (view == null) call.respondExecutor(ErrorBody("Unknown inference ID; do not resubmit"), 404)
                else call.respondExecutor(view)
            }
            input.method == "DELETE" && id != null -> {
                if (engine.cancel(id)) call.respondExecutor(CancelledResponse(true))
                else call.respondExecutor(ErrorBody("Unknown inference ID"), 404)
            }
            else -> call.respondExecutor(ErrorBody("unsupported executor operation"), 400)
        }
    }

    private suspend fun handlePair(call: ApplicationCall) {
        val host = call.request.headers["Host"].orEmpty()
        if (!loopbackHost(host)) { call.respondJson(ErrorBody("bad host"), HttpStatusCode.Forbidden); return }
        val origin = call.request.headers["Origin"]
        if (origin != null && !loopbackOrigin(origin)) {
            call.respondJson(ErrorBody("bad origin"), HttpStatusCode.Forbidden); return
        }
        if (!pairAllowed()) {
            call.respondJson(ErrorBody("too many pairing attempts"), HttpStatusCode.TooManyRequests); return
        }
        val text = requestText(call) ?: return
        val request = if (text.isBlank()) PairRequest() else decodeJson<PairRequest>(text)
        if (request == null) { call.respondJson(ErrorBody("invalid pairing request"), HttpStatusCode.BadRequest); return }
        if (request.placeId > 0) lastPlaceId = request.placeId
        var token = settings.token
        if (token.isEmpty()) {
            token = newToken()
            settings.token = token
            log.add("Paired a client" + if (request.placeId > 0) " from place ${request.placeId}" else "")
        }
        onPaired(token, lastPlaceId)
        clientContact()
        call.respondJson(PairResponse(token = token, instance = instance))
    }

    private suspend fun handleSubmit(call: ApplicationCall) {
        val text = requestText(call) ?: return
        val request = decodeJson<SubmitRequest>(text)
        if (request == null) { call.respondJson(ErrorBody("invalid request"), HttpStatusCode.BadRequest); return }
        when (val result = engine.submit(request)) {
            is JobEngine.Submission.Accepted -> call.respondJson(result.view, HttpStatusCode.Accepted)
            is JobEngine.Submission.Rejected -> call.respondJson(ErrorBody(result.message), HttpStatusCode.fromValue(result.status))
        }
    }

    private suspend fun handlePoll(call: ApplicationCall) {
        val id = call.parameters["id"]
        if (id.isNullOrEmpty()) { call.respondJson(ErrorBody("missing id"), HttpStatusCode.BadRequest); return }
        val view: JobView = engine.poll(id)
            ?: run { call.respondJson(ErrorBody("Unknown inference ID; do not resubmit"), HttpStatusCode.NotFound); return }
        call.respondJson(view)
    }

    private suspend fun requestText(call: ApplicationCall, executor: Boolean = false): String? = try {
        call.readRelayJson(MAX_REQUEST_BYTES)
    } catch (failure: RequestBodyFailure) {
        // Fixed categories only: never log bodies, token values or decoder exceptions.
        log.add("Request rejected: ${failure.reason}")
        if (executor) call.respondExecutor(ErrorBody(failure.reason), failure.status)
        else call.respondJson(ErrorBody(failure.reason), HttpStatusCode.fromValue(failure.status))
        null
    }

    private suspend fun handleCancel(call: ApplicationCall) {
        val id = call.parameters["id"]
        if (id.isNullOrEmpty()) { call.respondJson(ErrorBody("missing id"), HttpStatusCode.BadRequest); return }
        if (engine.cancel(id)) call.respondJson(CancelledResponse(true))
        else call.respondJson(ErrorBody("Unknown inference ID"), HttpStatusCode.NotFound)
    }

    private suspend fun handleStatus(call: ApplicationCall) {
        call.respondJson(status())
    }

    private fun status() = StatusResponse(
        instance = instance,
        port = port,
        uptimeMs = System.currentTimeMillis() - startedAt,
        activeJobs = engine.activeCount,
        retainedBytes = engine.retained,
        paired = settings.token.isNotEmpty(),
        userStopped = settings.userStopped,
        lastClientAt = lastClientAt,
        activity = engine.activity(),
    )

    private fun pairAllowed(): Boolean {
        val now = System.currentTimeMillis()
        synchronized(pairLock) {
            while (pairTimes.isNotEmpty() && now - pairTimes.first() > PAIR_WINDOW_MS) pairTimes.removeFirst()
            if (pairTimes.size >= PAIR_LIMIT) return false
            pairTimes.addLast(now)
            return true
        }
    }

    private fun ApplicationCall.authorised(): Boolean {
        val header = request.headers["Authorization"] ?: return false
        val supplied = if (header.startsWith("Bearer ")) header.substring(7).trim() else header.trim()
        return authorisedToken(supplied)
    }

    private fun authorisedToken(supplied: String): Boolean {
        val expected = settings.token
        if (expected.isEmpty() || supplied.length != expected.length) return false
        val matches = MessageDigest.isEqual(supplied.toByteArray(Charsets.UTF_8), expected.toByteArray(Charsets.UTF_8))
        if (matches) clientContact()
        return matches
    }

    private fun clientContact() {
        lastClientAt = System.currentTimeMillis()
        onClientContact(lastClientAt)
    }

    private fun newToken(): String {
        val bytes = ByteArray(32)
        random.nextBytes(bytes)
        return bytes.joinToString("") { "%02x".format(it) }
    }

    companion object {
        const val LOOPBACK = "127.0.0.1"
        const val MAX_REQUEST_BYTES = 8L * 1024 * 1024
        private const val PAIR_LIMIT = 10
        private const val PAIR_WINDOW_MS = 60_000L

        fun loopbackHost(host: String): Boolean {
            val match = Regex("^(127\\.0\\.0\\.1|localhost|\\[::1\\])(?::([0-9]{1,5}))?$").matchEntire(host.lowercase()) ?: return false
            return match.groupValues[2].isEmpty() || match.groupValues[2].toInt() in 1..65535
        }

        fun loopbackOrigin(origin: String): Boolean =
            origin.startsWith("http://") && loopbackHost(origin.removePrefix("http://"))
    }
}

private suspend inline fun <reified T> ApplicationCall.respondJson(value: T, status: HttpStatusCode = HttpStatusCode.OK) {
    if (value is JobView && ResponseBodySize.bytes(value) > ResponseBodySize.LIMIT) {
        respondText(RelayJson.encodeToString(ErrorBody(ResponseBodySize.FAILURE)), ContentType.Application.Json, HttpStatusCode.PayloadTooLarge)
        return
    }
    val json = RelayJson.encodeToString(value)
    if (ResponseBodySize.bytes(json) > ResponseBodySize.LIMIT) {
        respondText(RelayJson.encodeToString(ErrorBody(ResponseBodySize.FAILURE)), ContentType.Application.Json, HttpStatusCode.PayloadTooLarge)
        return
    }
    respondText(json, ContentType.Application.Json, status)
}

private suspend inline fun <reified T> ApplicationCall.respondExecutor(value: T, status: Int = 200) {
    response.headers.append("Cache-Control", "no-store")
    if (value is JobView && ResponseBodySize.bytes(value, status) > ResponseBodySize.LIMIT) {
        respondExecutorLimit()
        return
    }
    val json = RelayJson.encodeToString(value)
    if (ResponseBodySize.bytes(json, status) > ResponseBodySize.LIMIT) {
        respondExecutorLimit()
        return
    }
    respondJson(ExecutorResponse(status = status, body = json))
}

private suspend fun ApplicationCall.respondExecutorLimit() {
    val body = RelayJson.encodeToString(ErrorBody(ResponseBodySize.FAILURE))
    respondJson(ExecutorResponse(status = 413, body = body))
}

private inline fun <reified T> decodeJson(text: String): T? =
    try {
        RelayJson.decodeFromString<T>(text)
    } catch (_: Exception) {
        null
    }
