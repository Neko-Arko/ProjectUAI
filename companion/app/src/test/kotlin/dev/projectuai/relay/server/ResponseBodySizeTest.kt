package dev.projectuai.relay.server

import dev.projectuai.relay.protocol.ExecutorResponse
import dev.projectuai.relay.protocol.JobState
import dev.projectuai.relay.protocol.JobView
import dev.projectuai.relay.protocol.RelayJson
import kotlinx.serialization.encodeToString
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ResponseBodySizeTest {
    private fun view(body: String?) = JobView("inference_size", JobState.COMPLETED,
        error = "metadata \" \\ \n \u4F60", status = 200,
        headers = mapOf("x-test" to "\u00E9 \uD83C\uDF3F \t"), body = body)

    private fun encodedBytes(view: JobView, status: Int?): Long {
        val json = RelayJson.encodeToString(view)
        val wire = if (status == null) json else RelayJson.encodeToString(ExecutorResponse(status = status, body = json))
        return wire.toByteArray(Charsets.UTF_8).size.toLong()
    }

    @Test
    fun `preflight matches serializer UTF8 for every escape and Unicode width`() {
        val cases = listOf(null, "", "ASCII", "\"\\\b\t\n\u000C\r", (0..31).map { it.toChar() }.joinToString(""),
            "\u007F\u0080\u07FF\u0800\u4F60\uFFFF\uD83C\uDF3F", "\uD800", "\uDC00", "\uD800x\uDC00",
            "quoted \" path \\ newline\n \u4F60\u597D \uD83C\uDF3F".repeat(300))
        for (body in cases) {
            for (status in listOf(null, 200, 202, 413)) {
                val value = view(body)
                assertEquals(encodedBytes(value, status), ResponseBodySize.bytes(value, status))
                assertEquals(encodedBytes(value, status), ResponseBodySize.bytes(RelayJson.encodeToString(value), status))
            }
        }
    }

    @Test
    fun `boundary accounts for full metadata and both layers of quote expansion`() {
        for (status in listOf(null, 200)) {
            val empty = view("")
            val available = (ResponseBodySize.LIMIT - ResponseBodySize.bytes(empty, status)).toInt()
            val value = empty.copy(body = "x".repeat(available))
            assertEquals(ResponseBodySize.LIMIT, ResponseBodySize.bytes(value, status))
            assertEquals(ResponseBodySize.LIMIT, encodedBytes(value, status))
            assertEquals(ResponseBodySize.LIMIT + 1, ResponseBodySize.bytes(value.copy(body = value.body + "x"), status))
        }
        val escaped = view("\"".repeat((ResponseBodySize.LIMIT / 4).toInt()))
        assertTrue(ResponseBodySize.bytes(escaped) < ResponseBodySize.LIMIT)
        assertTrue(ResponseBodySize.bytes(escaped, 200) > ResponseBodySize.LIMIT)
        assertEquals(encodedBytes(escaped, 200), ResponseBodySize.bytes(escaped, 200))
    }
}
