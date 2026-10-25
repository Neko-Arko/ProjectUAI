package dev.projectuai.relay.protocol

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/** Exactly the contract in src/net/relay.lua. Protocol 2 is the only accepted value. */
const val PROTOCOL = 2
const val SERVER_MARKER = "uai-relay"

val RelayJson = Json {
    ignoreUnknownKeys = true
    encodeDefaults = true
}

object JobState {
    const val RUNNING = "running"
    const val COMPLETED = "completed"
    const val FAILED = "failed"
    const val CANCELLED = "cancelled"
    const val EXPIRED = "expired"
}

@Serializable
data class Capabilities(
    val serverSidePairing: Boolean = true,
    val deltas: Boolean = false,
    val inference: InferenceCapability = InferenceCapability(),
    val executorPost: ExecutorPostCapability = ExecutorPostCapability(),
    val kilo: KiloCapability = KiloCapability(),
)

@Serializable
data class KiloCapability(val schema: Int = 1, val enabled: Boolean = false, val available: Boolean = false,
    val state: String = "disabled", val message: String = "Kilo tunnel is off.")

@Serializable
data class ExecutorPostCapability(val schema: Int = 1)

@Serializable
data class ExecutorRequest(val schema: Int = 0, val method: String, val path: String, val token: String, val body: String = "")

@Serializable
data class ExecutorResponse(val schema: Int = 1, val status: Int, val body: String)

@Serializable
data class InferenceCapability(val schema: Int = 1, val unlimited: Boolean = true)

@Serializable
data class Hello(
    val ok: Boolean = true,
    val protocol: Int = PROTOCOL,
    val instance: String,
    val server: String = SERVER_MARKER,
    val capabilities: Capabilities = Capabilities(),
)

@Serializable
data class PairRequest(
    val client: String = "",
    val version: String = "",
    val protocol: Int = 0,
    val placeId: Long = 0,
    val gameId: Long = 0,
)

@Serializable
data class PairResponse(
    val ok: Boolean = true,
    val token: String,
    val instance: String,
    val protocol: Int = PROTOCOL,
)

@Serializable
data class SubmitRequest(
    val id: String,
    val instance: String,
    val url: String,
    val headers: Map<String, String> = emptyMap(),
    val body: String = "",
    val timeout: Int = 180,
    val sessionId: String? = null,
)

@Serializable
data class JobView(
    val id: String,
    val state: String,
    val error: String? = null,
    val status: Int = 0,
    val headers: Map<String, String> = emptyMap(),
    val body: String? = null,
    val errorCode: String? = null,
)

/** Diagnostic metadata only: no request/response contents, URL paths or credentials. */
@Serializable
data class JobActivity(
    val id: String,
    val provider: String,
    val state: String,
    val stage: String,
    val startedAt: Long,
    val finishedAt: Long = 0,
    val receivedBytes: Long = 0,
    val status: Int = 0,
    val errorCode: String? = null,
)

@Serializable
data class ActivitySnapshot(
    val activeJobs: Int = 0,
    val acceptedJobs: Int = 0,
    val completedJobs: Int = 0,
    val failedJobs: Int = 0,
    val cancelledJobs: Int = 0,
    val recent: List<JobActivity> = emptyList(),
)

@Serializable
data class ErrorBody(val error: String)

@Serializable
data class StatusResponse(
    val ok: Boolean = true,
    val server: String = SERVER_MARKER,
    val protocol: Int = PROTOCOL,
    val instance: String,
    val port: Int,
    val uptimeMs: Long,
    val activeJobs: Int,
    val retainedBytes: Long,
    val paired: Boolean,
    val userStopped: Boolean,
    val lastClientAt: Long = 0,
    val activity: ActivitySnapshot = ActivitySnapshot(),
    val capabilities: Capabilities = Capabilities(),
)
