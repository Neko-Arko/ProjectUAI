package dev.projectuai.relay.update

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.*
import okhttp3.OkHttpClient
import okhttp3.Protocol
import okhttp3.Response
import okhttp3.ResponseBody.Companion.toResponseBody
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.IOException
import java.io.OutputStream
import java.security.MessageDigest

class RelayUpdaterTest {
    @get:Rule val temporary = TemporaryFolder()
    private val payload = "signed-apk-fixture".toByteArray()
    private fun hash(bytes: ByteArray) = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
    private fun manifest(version: String = "1.2.0", code: Long = 3, minSdk: Int = 26) = RelayManifest(
        "project-uai-relay-release", 1, version, code, "android", "dev.projectuai.relay", minSdk, 2,
        RelayPackage("UAI-Relay-$version.apk", payload.size.toLong(), hash(payload), "a".repeat(64)),
    )

    private fun release(version: String = "1.2.0", draft: Boolean = false): JsonObject {
        val tag = "relay-v$version"
        return buildJsonObject {
            put("tag_name", tag); put("draft", draft); put("prerelease", false)
            putJsonArray("assets") {
                for (name in listOf("relay-release.json", "UAI-Relay-$version.apk")) add(buildJsonObject {
                    put("name", name); put("browser_download_url", "https://github.com/${RelayUpdater.REPOSITORY}/releases/download/$tag/$name")
                })
            }
        }
    }

    private class FixtureFetcher(val responses: MutableMap<String, ByteArray>) : UpdateFetcher {
        val calls = ArrayList<String>()
        var cancelApk = false
        override suspend fun download(url: String, maxBytes: Long, output: OutputStream, progress: (Long, Long) -> Unit) {
            calls += url
            if (cancelApk && url.endsWith(".apk")) { output.write(1); throw CancellationException("fixture cancellation") }
            val body = responses[url] ?: throw IOException("fixture missing")
            output.write(body); progress(body.size.toLong(), body.size.toLong())
        }
    }

    private fun fixture(manifest: RelayManifest = manifest()): FixtureFetcher {
        val candidate = RelayUpdater.candidates(JsonArray(listOf(release(manifest.version))).toString(), "1.1.0").single()
        return FixtureFetcher(mutableMapOf(
            RelayUpdater.RELEASES_URL to JsonArray(listOf(release(manifest.version))).toString().toByteArray(),
            candidate.manifestUrl to Json.encodeToString(manifest).toByteArray(), candidate.apkUrl to payload,
        ))
    }

    @Test fun `stages verified bytes restores offline and rechecks before installation`() = runBlocking {
        val dir = temporary.newFolder()
        val fetcher = fixture()
        var inspections = 0
        val inspector: (File, RelayManifest) -> Unit = { file, _ -> assertArrayEquals(payload, file.readBytes()); inspections++ }
        val updater = RelayUpdater(dir, "1.1.0", 2, 36, inspector, fetcher)
        updater.check()
        assertEquals("ready", updater.state.value.phase)
        assertTrue(File(dir, "pending.json").isFile)
        val restored = RelayUpdater(dir, "1.1.0", 2, 36, inspector, FixtureFetcher(mutableMapOf()))
        restored.restore()
        val file = restored.verifiedApk()!!
        assertTrue(inspections >= 4)
        file.writeText("tampered")
        assertNull(restored.verifiedApk())
        assertEquals("error", restored.state.value.phase)
        assertFalse(File(dir, "pending.json").exists())
    }

    @Test fun `automatic download preference leaves discovery available until manual download`() = runBlocking {
        val dir = temporary.newFolder(); val fetcher = fixture()
        val updater = RelayUpdater(dir, "1.1.0", 2, 36, { _, _ -> }, fetcher)
        updater.check(download = false)
        assertEquals("available", updater.state.value.phase)
        assertFalse(fetcher.calls.any { it.endsWith(".apk") })
        updater.check(download = true)
        assertEquals("ready", updater.state.value.phase)
        val count = fetcher.calls.size
        updater.check()
        assertEquals(count, fetcher.calls.size)
    }

    @Test fun `bad hash or Android signature rejection never publishes pending pointer`() = runBlocking {
        for (signatureFailure in listOf(false, true)) {
            val dir = temporary.newFolder(); val fetcher = fixture()
            if (!signatureFailure) fetcher.responses.keys.first { it.endsWith(".apk") }.let {
                fetcher.responses[it] = payload.copyOf().also { bytes -> bytes[0] = (bytes[0].toInt() xor 1).toByte() }
            }
            val updater = RelayUpdater(dir, "1.1.0", 2, 36, { _, _ -> if (signatureFailure) throw IOException("different signer") }, fetcher)
            updater.check()
            assertEquals("error", updater.state.value.phase)
            assertFalse(File(dir, "pending.json").exists())
            assertFalse(dir.listFiles()!!.any { it.name.startsWith("stage-") })
        }
    }

    @Test fun `version code downgrade and unsupported Android release are never downloaded`() = runBlocking {
        for (manifest in listOf(manifest(code = 2), manifest(minSdk = 37))) {
            val fetcher = fixture(manifest)
            val updater = RelayUpdater(temporary.newFolder(), "1.1.0", 2, 36, { _, _ -> fail("must not inspect an incompatible APK") }, fetcher)
            updater.check()
            assertEquals("idle", updater.state.value.phase)
            assertFalse(fetcher.calls.any { it.endsWith(".apk") })
        }
    }

    @Test fun `a supported older candidate is selected when newest requires a newer Android`() = runBlocking {
        val fetcher = fixture()
        val newer = RelayUpdater.candidates(JsonArray(listOf(release("1.3.0"))).toString(), "1.1.0").single()
        fetcher.responses[RelayUpdater.RELEASES_URL] = JsonArray(listOf(release("1.3.0"), release())).toString().toByteArray()
        fetcher.responses[newer.manifestUrl] = Json.encodeToString(manifest("1.3.0", 4, 37)).toByteArray()
        val updater = RelayUpdater(temporary.newFolder(), "1.1.0", 2, 36, { _, _ -> }, fetcher)
        updater.check()
        assertEquals("ready", updater.state.value.phase)
        assertEquals("1.2.0", updater.state.value.version)
        assertFalse(fetcher.calls.contains(newer.apkUrl))
    }

    @Test fun `cancelled downloads leave no installable partial`() = runBlocking {
        val dir = temporary.newFolder(); val fetcher = fixture().also { it.cancelApk = true }
        val updater = RelayUpdater(dir, "1.1.0", 2, 36, { _, _ -> fail("partial APK inspected") }, fetcher)
        try { updater.check(); fail("must preserve coroutine cancellation") } catch (_: CancellationException) { }
        assertNull(updater.verifiedApk())
        assertFalse(File(dir, "pending.json").exists())
        assertFalse(dir.listFiles()!!.any { it.name.startsWith("stage-") })
    }

    @Test fun `completed installation clears old cache while path injection preserves unrelated files`() = runBlocking {
        val dir = temporary.newFolder()
        val updater = RelayUpdater(dir, "1.1.0", 2, 36, { _, _ -> }, fixture())
        updater.check()
        val next = RelayUpdater(dir, "1.2.0", 3, 36, { _, _ -> fail("already installed") }, fixture())
        next.restore()
        assertFalse(File(dir, "pending.json").exists())
        assertFalse(dir.listFiles()!!.any { it.extension == "apk" })
        val unrelated = File(temporary.root, "keep.txt").also { it.writeText("keep") }
        File(dir, "pending.json").writeText("{\"key\":\"../keep\"}")
        next.restore()
        assertEquals("keep", unrelated.readText())
        assertEquals("error", next.state.value.phase)
    }

    @Test fun `manifest requires exact product filename stable version digest and bounded size`() {
        val original = Json.encodeToJsonElement(manifest()).jsonObject
        val changes = listOf(
            original + ("applicationId" to JsonPrimitive("different.app")),
            original + ("version" to JsonPrimitive("1.2.0-beta")),
            original + ("versionCode" to JsonPrimitive(0)),
            original + ("package" to JsonObject(original.getValue("package").jsonObject + ("name" to JsonPrimitive("../payload.apk")))),
            original + ("package" to JsonObject(original.getValue("package").jsonObject + ("bytes" to JsonPrimitive(RelayUpdater.MAX_APK_BYTES + 1)))),
            original + ("package" to JsonObject(original.getValue("package").jsonObject + ("signerSha256" to JsonPrimitive("bad")))),
        )
        for (bad in changes) assertThrows(Exception::class.java) { RelayUpdater.parseManifest(JsonObject(bad).toString()) }
        assertThrows(Exception::class.java) { RelayUpdater.parseManifest(Json.encodeToString(manifest()), "1.3.0") }
    }

    @Test fun `candidate assets must belong to exact official release with no duplicates`() {
        val good = release()
        val assets = good.getValue("assets").jsonArray
        val foreign = JsonObject(assets[0].jsonObject + ("browser_download_url" to JsonPrimitive("https://evil.example/relay-release.json")))
        val bad = listOf(
            release(draft = true), JsonObject(good + ("prerelease" to JsonPrimitive(true))),
            JsonObject(good + ("assets" to JsonArray(listOf(foreign, assets[1])))),
            JsonObject(good + ("assets" to JsonArray(assets + assets[0]))),
        )
        assertTrue(RelayUpdater.candidates(JsonArray(bad).toString(), "1.1.0").isEmpty())
        assertEquals("1.10.0", RelayUpdater.candidates(JsonArray(listOf(good, release("1.10.0"))).toString(), "1.1.0").first().version)
    }

    @Test fun `fetcher rejects external redirects and never includes local credentials`() = runBlocking {
        var requests = 0
        val client = OkHttpClient.Builder().followRedirects(false).addInterceptor { chain ->
            requests++
            assertNull(chain.request().header("Authorization"))
            assertEquals("identity", chain.request().header("Accept-Encoding"))
            Response.Builder().request(chain.request()).protocol(Protocol.HTTP_1_1).code(302).message("redirect")
                .header("Location", "https://other.example/file.apk").body(ByteArray(0).toResponseBody()).build()
        }.build()
        try {
            GitHubFetcher("1.1.0", client).download("https://github.com/test", 10, ByteArrayOutputStream()) { _, _ -> }
            fail("untrusted redirect accepted")
        } catch (_: IOException) { }
        assertEquals(1, requests)
        client.dispatcher.executorService.shutdown()
    }

    @Test fun `release catalog requests JSON while release assets request binary content`() = runBlocking {
        val client = OkHttpClient.Builder().addInterceptor { chain ->
            val expected = if (chain.request().url.host == "api.github.com") "application/json" else "application/octet-stream"
            // The real GitHub releases API rejects octet-stream with HTTP 415.
            val accepted = chain.request().header("Accept") == expected
            Response.Builder().request(chain.request()).protocol(Protocol.HTTP_1_1)
                .code(if (accepted) 200 else 415).message(if (accepted) "ok" else "unsupported media type")
                .body("fixture".toResponseBody()).build()
        }.build()
        try {
            for (url in listOf(RelayUpdater.RELEASES_URL, "https://github.com/release/relay-release.json", "https://github.com/release/update.apk")) {
                val output = ByteArrayOutputStream()
                GitHubFetcher("1.1.0", client).download(url, 32, output) { _, _ -> }
                assertEquals("fixture", output.toString(Charsets.UTF_8.name()))
            }
        } finally { client.dispatcher.executorService.shutdown() }
    }

    @Test fun `fetcher bounds provider body and validates TLS destinations`() = runBlocking {
        for (url in listOf("http://github.com/file", "https://github.com.evil.test/file", "https://user:pass@github.com/file", "https://github.com:8443/file", "https://github.com/file#fragment")) {
            assertThrows(Exception::class.java) { GitHubFetcher.trustedUrl(url) }
        }
        val client = OkHttpClient.Builder().addInterceptor { chain ->
            Response.Builder().request(chain.request()).protocol(Protocol.HTTP_1_1).code(200).message("ok")
                .body(ByteArray(11).toResponseBody()).build()
        }.build()
        val out = ByteArrayOutputStream()
        try { GitHubFetcher("1.1.0", client).download("https://github.com/test", 10, out) { _, _ -> }; fail("oversize accepted") }
        catch (_: IOException) { }
        assertEquals(0, out.size())
        client.dispatcher.executorService.shutdown()
    }
}
