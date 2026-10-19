package dev.projectuai.relay.server

import io.ktor.server.application.ApplicationCall
import io.ktor.server.request.receiveChannel
import io.ktor.utils.io.readAvailable
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.nio.ByteBuffer
import java.nio.charset.CharacterCodingException
import java.nio.charset.CodingErrorAction
import java.util.zip.GZIPInputStream

/** Bound both the wire body and its expanded JSON before deserializing it. */
internal class RequestBodyFailure(val status: Int, val reason: String) : Exception(reason)

internal suspend fun ApplicationCall.readRelayJson(limit: Long): String {
    val encoding = request.headers["Content-Encoding"].orEmpty().trim().lowercase()
    if (encoding !in listOf("", "identity", "gzip", "x-gzip")) {
        throw RequestBodyFailure(415, "unsupported request encoding; use JSON or gzip")
    }
    val declared = request.headers["Content-Length"]?.toLongOrNull()
    if (declared != null && declared > limit) throw RequestBodyFailure(413, "request too large")
    val channel = receiveChannel()
    val output = ByteArrayOutputStream()
    val buffer = ByteArray(8192)
    while (true) {
        val count = channel.readAvailable(buffer, 0, buffer.size)
        if (count == -1) break
        if (output.size().toLong() + count > limit) throw RequestBodyFailure(413, "request too large")
        output.write(buffer, 0, count)
    }
    val wire = output.toByteArray()
    // Some executor HttpPost implementations compress larger POSTs. Also accept
    // the unambiguous gzip signature if their wrapper omitted Content-Encoding.
    val gzip = encoding == "gzip" || encoding == "x-gzip" ||
        (wire.size >= 2 && wire[0] == 0x1f.toByte() && wire[1] == 0x8b.toByte())
    val bytes = if (gzip) withContext(Dispatchers.IO) {
        try {
            GZIPInputStream(wire.inputStream()).use { input ->
                val expanded = ByteArrayOutputStream()
                while (true) {
                    val count = input.read(buffer)
                    if (count == -1) break
                    if (expanded.size().toLong() + count > limit) throw RequestBodyFailure(413, "expanded request too large")
                    expanded.write(buffer, 0, count)
                }
                expanded.toByteArray()
            }
        } catch (_: IOException) {
            throw RequestBodyFailure(400, "invalid gzip request; no inference was started")
        }
    } else wire
    return try {
        Charsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(bytes)).toString().removePrefix("\uFEFF")
    } catch (_: CharacterCodingException) {
        throw RequestBodyFailure(400, "request is not UTF-8 JSON; no inference was started")
    }
}
