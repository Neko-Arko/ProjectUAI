package dev.projectuai.relay.engine

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class RequestRulesTest {
    @Test
    fun `filters hop-by-hop and forced headers`() {
        val filtered = RequestRules.filterRequestHeaders(
            mapOf(
                "Host" to "provider.test",
                "Connection" to "keep-alive",
                "Content-Length" to "999",
                "Transfer-Encoding" to "chunked",
                "Accept-Encoding" to "gzip",
                "Authorization" to "Bearer key",
                "Content-Type" to "application/json",
            ),
        )
        assertFalse(filtered.keys.any { it.equals("host", true) })
        assertFalse(filtered.keys.any { it.equals("connection", true) })
        assertFalse(filtered.keys.any { it.equals("content-length", true) })
        assertFalse(filtered.keys.any { it.equals("transfer-encoding", true) })
        assertEquals("identity", filtered["accept-encoding"])
        assertEquals("Bearer key", filtered["Authorization"])
        assertEquals("application/json", filtered["Content-Type"])
    }

    @Test
    fun `drops hop-by-hop response headers`() {
        val filtered = RequestRules.filterResponseHeaders(
            mapOf("content-type" to "application/json", "Connection" to "close", "Transfer-Encoding" to "chunked", "x-request-id" to "1", "x-should-retry" to "false"),
        )
        assertEquals(setOf("content-type", "x-request-id", "x-should-retry"), filtered.keys)
        assertEquals("false", filtered["x-should-retry"])
    }

    @Test
    fun `clamps the timeout to the contract range`() {
        assertEquals(0, RequestRules.clampTimeout(0))
        assertEquals(10, RequestRules.clampTimeout(-1))
        assertEquals(10, RequestRules.clampTimeout(1))
        assertEquals(180, RequestRules.clampTimeout(180))
        assertEquals(86400, RequestRules.clampTimeout(999999))
    }

    @Test
    fun `id regex matches the relay contract`() {
        assertTrue(RequestRules.ID.matches("inference_1234abcd"))
        assertTrue(RequestRules.ID.matches("abc-def_12"))
        assertFalse(RequestRules.ID.matches("short"))
        assertFalse(RequestRules.ID.matches("has spaces"))
        assertFalse(RequestRules.ID.matches("x".repeat(101)))
    }

    @Test
    fun `url validation rejects credentials and link-local metadata`() {
        assertNull(RequestRules.validateUrl("https://api.example.com/v1/chat/completions"))
        assertNull(RequestRules.validateUrl("http://192.168.1.20:1234/v1/chat/completions"))
        assertTrue(RequestRules.validateUrl("ftp://example.com/v1") != null)
        assertTrue(RequestRules.validateUrl("https://user:pass@example.com/v1") != null)
        assertTrue(RequestRules.validateUrl("http://169.254.169.254/latest/meta-data") != null)
        assertTrue(RequestRules.validateUrl("http://metadata.google.internal/") != null)
        assertTrue(RequestRules.validateUrl("not a url") != null)
    }
}
