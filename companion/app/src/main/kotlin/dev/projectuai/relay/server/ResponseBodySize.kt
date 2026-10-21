package dev.projectuai.relay.server

import dev.projectuai.relay.protocol.ExecutorResponse
import dev.projectuai.relay.protocol.JobView
import dev.projectuai.relay.protocol.RelayJson
import kotlinx.serialization.encodeToString

/** Count the complete UTF-8 wire response before expanding a retained provider body. */
internal object ResponseBodySize {
    const val LIMIT = 8L * 1024 * 1024
    const val FAILURE = "response_limit: companion transport envelope exceeds 8 MiB; do not resubmit"

    fun bytes(json: String, executorStatus: Int? = null): Long =
        if (executorStatus == null) utf8Bytes(json) else {
            val emptyEnvelope = RelayJson.encodeToString(ExecutorResponse(status = executorStatus, body = ""))
            utf8Bytes(emptyEnvelope) + quotedBytes(json, layers = 1) - 2
        }

    fun bytes(view: JobView, executorStatus: Int? = null): Long {
        val body = view.body ?: return bytes(RelayJson.encodeToString(view), executorStatus)
        // Serialize only metadata. The empty body's quotes are replaced by the
        // size of the real JSON string, including the executor's second escaping.
        val metadata = RelayJson.encodeToString(view.copy(body = ""))
        val layers = if (executorStatus == null) 1 else 2
        val emptyBody = if (layers == 1) 2 else 4
        return bytes(metadata, executorStatus) - emptyBody + quotedBytes(body, layers)
    }

    private fun utf8Bytes(text: String): Long {
        var bytes = 0L
        var index = 0
        while (index < text.length) {
            val char = text[index++]
            bytes += when {
                char.code < 0x80 -> 1
                char.code < 0x800 -> 2
                char.isHighSurrogate() && index < text.length && text[index].isLowSurrogate() -> {
                    index++
                    4
                }
                // JVM UTF-8 replaces an unpaired surrogate with one question mark.
                char.isSurrogate() -> 1
                else -> 3
            }
        }
        return bytes
    }

    private fun quotedBytes(text: String, layers: Int): Long {
        var bytes = if (layers == 1) 2L else 4L
        var index = 0
        while (index < text.length) {
            val char = text[index++]
            bytes += when {
                char == '"' || char == '\\' -> if (layers == 1) 2 else 4
                char == '\b' || char == '\t' || char == '\n' || char == '\u000C' || char == '\r' ->
                    if (layers == 1) 2 else 3
                char.code < 0x20 -> if (layers == 1) 6 else 7
                char.code < 0x80 -> 1
                char.code < 0x800 -> 2
                char.isHighSurrogate() && index < text.length && text[index].isLowSurrogate() -> {
                    index++
                    4
                }
                char.isSurrogate() -> 1
                else -> 3
            }
        }
        return bytes
    }
}
