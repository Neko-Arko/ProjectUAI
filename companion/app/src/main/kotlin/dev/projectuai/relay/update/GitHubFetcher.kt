package dev.projectuai.relay.update

import kotlinx.coroutines.suspendCancellableCoroutine
import okhttp3.Call
import okhttp3.Callback
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import java.io.IOException
import java.io.OutputStream
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

interface UpdateFetcher {
    suspend fun download(url: String, maxBytes: Long, output: OutputStream, progress: (Long, Long) -> Unit)
}

/** Public release traffic never carries provider keys or the local relay token. */
class GitHubFetcher(version: String, private val client: OkHttpClient = OkHttpClient.Builder()
    .connectTimeout(15, TimeUnit.SECONDS).readTimeout(30, TimeUnit.SECONDS)
    .callTimeout(5, TimeUnit.MINUTES).retryOnConnectionFailure(false)
    .followRedirects(false).followSslRedirects(false).build()) : UpdateFetcher {
    private val userAgent = "ProjectUAI-Relay/$version"

    override suspend fun download(url: String, maxBytes: Long, output: OutputStream, progress: (Long, Long) -> Unit) {
        require(maxBytes in 1..RelayUpdater.MAX_APK_BYTES)
        suspendCancellableCoroutine<Unit> { continuation ->
            val active = AtomicReference<Call?>()
            val deadline = System.nanoTime() + TimeUnit.MINUTES.toNanos(5)
            continuation.invokeOnCancellation { active.get()?.cancel() }
            fun request(address: String, redirects: Int) {
                if (!continuation.isActive) return
                val parsed: HttpUrl
                try { parsed = trustedUrl(address) } catch (error: Exception) { continuation.resumeWithException(error); return }
                val remaining = deadline - System.nanoTime()
                if (remaining <= 0) { continuation.resumeWithException(IOException("Update download deadline")); return }
                val accept = if (parsed.host == "api.github.com") "application/json" else "application/octet-stream"
                val call = client.newCall(Request.Builder().url(parsed).header("User-Agent", userAgent)
                    .header("Accept", accept).header("Accept-Encoding", "identity").build())
                call.timeout().timeout(remaining, TimeUnit.NANOSECONDS)
                active.set(call)
                if (!continuation.isActive) { call.cancel(); return }
                call.enqueue(object : Callback {
                    override fun onFailure(call: Call, e: IOException) { continuation.resumeWithException(e) }
                    override fun onResponse(call: Call, response: Response) {
                        try {
                            response.use { res ->
                                if (res.code in listOf(301, 302, 303, 307, 308)) {
                                    val location = res.header("Location") ?: throw IOException("Missing release redirect")
                                    if (redirects >= 4) throw IOException("Release redirect limit")
                                    val next = parsed.resolve(location) ?: throw IOException("Invalid release redirect")
                                    request(next.toString(), redirects + 1)
                                    return
                                }
                                if (res.code != 200) throw IOException("Release service returned HTTP ${res.code}")
                                val body = res.body ?: throw IOException("Empty release response")
                                val size = body.contentLength()
                                if (size > maxBytes) throw IOException("Release exceeds size limit")
                                body.byteStream().use { input ->
                                    val buffer = ByteArray(64 * 1024)
                                    var count = 0L
                                    while (true) {
                                        if (!continuation.isActive) return
                                        val read = input.read(buffer)
                                        if (read < 0) break
                                        if (!continuation.isActive) return
                                        count += read
                                        if (count > maxBytes) throw IOException("Release exceeds size limit")
                                        output.write(buffer, 0, read)
                                        progress(count, size)
                                    }
                                    if (size >= 0 && count != size) throw IOException("Truncated release response")
                                }
                            }
                            continuation.resume(Unit)
                        } catch (error: Exception) { continuation.resumeWithException(error) }
                    }
                })
            }
            request(url, 0)
        }
    }

    companion object {
        fun trustedUrl(raw: String): HttpUrl {
            val url = raw.toHttpUrl()
            if (url.scheme != "https" || url.port != 443 || url.username.isNotEmpty() || url.password.isNotEmpty() || url.fragment != null ||
                url.host !in setOf("api.github.com", "github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com")) {
                throw IOException("Untrusted release URL")
            }
            return url
        }
    }
}
