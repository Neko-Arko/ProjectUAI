package dev.projectuai.relay.engine

import okhttp3.HttpUrl.Companion.toHttpUrlOrNull

/**
 * Request normalisation mirroring bridge/inference.js. The companion forwards provider
 * traffic, so header filtering, URL safety and the id shape are the trust boundary.
 */
object RequestRules {
    private val DROPPED_REQUEST = setOf(
        "host", "connection", "content-length", "transfer-encoding", "accept-encoding",
    )
    private val HOP_BY_HOP = setOf(
        "connection", "keep-alive", "proxy-authenticate", "proxy-authorization",
        "te", "trailer", "transfer-encoding", "upgrade",
    )
    val ID = Regex("^[\\w-]{8,100}$")

    fun filterRequestHeaders(input: Map<String, String>): Map<String, String> {
        val out = LinkedHashMap<String, String>()
        input.forEach { (key, value) -> if (key.lowercase() !in DROPPED_REQUEST) out[key] = value }
        out["accept-encoding"] = "identity"
        return out
    }

    fun filterResponseHeaders(input: Map<String, String>): Map<String, String> =
        input.filterKeys { it.lowercase() !in HOP_BY_HOP }

    // Zero is negotiated by capabilities.inference.unlimited. Positive legacy
    // budgets retain their original range; a missing field still defaults to 180.
    fun clampTimeout(seconds: Int): Int = if (seconds == 0) 0 else seconds.coerceIn(10, 86400)

    /** null when the URL may be forwarded; otherwise the reason to reject it. */
    fun validateUrl(raw: String): String? {
        val parsed = raw.toHttpUrlOrNull() ?: return "url must be an absolute http(s) URL"
        if (parsed.scheme != "http" && parsed.scheme != "https") return "url must use http or https"
        if (parsed.username.isNotEmpty() || parsed.password.isNotEmpty()) return "url must not carry credentials"
        if (isBlockedHost(parsed.host)) return "url targets a blocked address"
        return null
    }

    private fun isBlockedHost(host: String): Boolean {
        val lowered = host.lowercase()
        if (lowered == "metadata.google.internal" || lowered == "metadata") return true
        if (lowered.startsWith("fe80:")) return true
        val parts = lowered.split(".")
        if (parts.size == 4) {
            val octets = parts.map { it.toIntOrNull() ?: return false }
            // Link-local metadata range; a provider is never there.
            if (octets[0] == 169 && octets[1] == 254) return true
        }
        return false
    }
}
