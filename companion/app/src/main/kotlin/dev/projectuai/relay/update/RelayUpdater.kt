package dev.projectuai.relay.update

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.*
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.security.MessageDigest
import java.util.UUID

@Serializable
data class RelayPackage(val name: String, val bytes: Long, val sha256: String, val signerSha256: String)

@Serializable
data class RelayManifest(
    val format: String, val schema: Int, val version: String, val versionCode: Long,
    val platform: String, val applicationId: String, val minSdk: Int, val protocol: Int,
    @SerialName("package") val artifact: RelayPackage,
)

data class UpdateState(
    val phase: String = "idle", val detail: String = "Updates are checked automatically.",
    val version: String? = null, val downloadedBytes: Long = 0, val totalBytes: Long = 0,
)

/** Owns verified staging only. The Android coordinator owns scheduling and installation. */
class RelayUpdater(
    directory: File,
    private val currentVersion: String,
    private val currentVersionCode: Long,
    private val sdkInt: Int,
    private val apkVerifier: (File, RelayManifest) -> Unit,
    private val fetcher: UpdateFetcher = GitHubFetcher(currentVersion),
) {
    private val root = directory.canonicalFile
    private val mutex = Mutex()
    private val mutableState = MutableStateFlow(UpdateState())
    val state: StateFlow<UpdateState> = mutableState.asStateFlow()
    private var staged: String? = null
    private val json = Json { ignoreUnknownKeys = true }

    suspend fun restore() = withContext(Dispatchers.IO) {
        mutex.withLock {
            root.mkdirs()
            // Only our bounded, flat staging names are eligible for cleanup.
            root.listFiles()?.filter { it.name.matches(Regex("stage-[a-f0-9-]{36}\\.(part|apk)")) }
                ?.forEach { runCatching { child(it.name).delete() } }
            try {
                val pointer = child("pending.json")
                if (!pointer.exists()) return@withLock
                val key = json.parseToJsonElement(read(pointer, 4096)).jsonObject["key"]?.jsonPrimitive?.content
                    ?: throw IOException("Invalid update pointer")
                val manifest = manifestFor(key)
                if (manifest.versionCode <= currentVersionCode) {
                    removeStage(key)
                    pointer.delete()
                    return@withLock
                }
                verify(key, manifest)
                staged = key
                ready(manifest)
            } catch (_: Exception) {
                staged = null
                child("pending.json").delete()
                mutableState.value = UpdateState("error", "A saved update could not be verified. Check again to download a fresh copy.")
            } finally {
                cleanupUnusedStages()
            }
        }
    }

    suspend fun check(download: Boolean = true) = withContext(Dispatchers.IO) {
        mutex.withLock {
            if (staged != null) return@withLock
            root.mkdirs()
            mutableState.value = UpdateState("checking", "Checking official relay releases...")
            var partial: File? = null
            try {
                val catalog = fetchText(RELEASES_URL, 2L * 1024 * 1024)
                var selected: Pair<Candidate, RelayManifest>? = null
                for (candidate in candidates(catalog, currentVersion)) {
                    val manifest = parseManifest(fetchText(candidate.manifestUrl, 64L * 1024), candidate.version)
                    if (manifest.versionCode <= currentVersionCode || manifest.minSdk > sdkInt) continue
                    selected = candidate to manifest
                    break
                }
                if (selected == null) {
                    mutableState.value = UpdateState("idle", "No newer compatible relay release is published.")
                    return@withLock
                }
                val (candidate, manifest) = selected
                if (!download) {
                    mutableState.value = UpdateState("available", "Version ${manifest.version} is available to download.", manifest.version)
                    return@withLock
                }
                mutableState.value = UpdateState("downloading", "Downloading a verified relay update...", manifest.version, 0, manifest.artifact.bytes)
                val file = child("stage-${UUID.randomUUID()}.apk")
                partial = file
                FileOutputStream(file).use { output ->
                    fetcher.download(candidate.apkUrl, manifest.artifact.bytes, output) { count, _ ->
                        mutableState.value = UpdateState("downloading", "Downloading version ${manifest.version}...", manifest.version, count, manifest.artifact.bytes)
                    }
                    output.fd.sync()
                }
                verifyFile(file, manifest)
                apkVerifier(file, manifest)
                val key = "${manifest.versionCode}-${manifest.artifact.sha256}"
                atomicMove(file, child("$key.apk"))
                partial = null
                atomicText(child("$key.json"), json.encodeToString(manifest))
                // Publish the pointer only after both immutable artifacts verify.
                verify(key, manifest)
                atomicText(child("pending.json"), buildJsonObject { put("key", key) }.toString())
                staged = key
                ready(manifest)
            } catch (cancelled: CancellationException) {
                mutableState.value = UpdateState("idle", "Update download stopped. The installed app is unchanged.")
                throw cancelled
            } catch (_: Exception) {
                mutableState.value = UpdateState("error", "The update could not be downloaded or verified. The installed app is unchanged; try again later.")
            } finally {
                partial?.let { runCatching { it.delete() } }
                cleanupUnusedStages()
            }
        }
    }

    /** Rehash and inspect the exact staged APK immediately before the system installer. */
    suspend fun verifiedApk(): File? = withContext(Dispatchers.IO) {
        mutex.withLock {
            val key = staged ?: return@withLock null
            try {
                val manifest = manifestFor(key)
                verify(key, manifest)
                child("$key.apk")
            } catch (_: Exception) {
                staged = null
                child("pending.json").delete()
                cleanupUnusedStages()
                mutableState.value = UpdateState("error", "The saved update changed or is incompatible. Download it again before installing.")
                null
            }
        }
    }

    private fun ready(manifest: RelayManifest) {
        mutableState.value = UpdateState("ready", "Version ${manifest.version} is verified and ready to install.", manifest.version, manifest.artifact.bytes, manifest.artifact.bytes)
    }

    private suspend fun fetchText(url: String, limit: Long): String {
        val out = ByteArrayOutputStream()
        fetcher.download(url, limit, out) { _, _ -> }
        if (out.size() > limit) throw IOException("Update metadata limit")
        return out.toString(Charsets.UTF_8.name())
    }

    private fun child(name: String): File {
        if (!name.matches(Regex("[a-zA-Z0-9.-]+"))) throw IOException("Invalid update path")
        return File(root, name).also { if (it.canonicalFile.parentFile != root) throw IOException("Update path escaped cache") }
    }

    private fun manifestFor(key: String): RelayManifest {
        if (!key.matches(Regex("[1-9][0-9]{0,9}-[a-f0-9]{64}"))) throw IOException("Invalid update key")
        return parseManifest(read(child("$key.json"), 64 * 1024)).also {
            if (key != "${it.versionCode}-${it.artifact.sha256}") throw IOException("Update key mismatch")
        }
    }

    private fun verify(key: String, manifest: RelayManifest) {
        if (manifest.versionCode <= currentVersionCode || compareVersions(manifest.version, currentVersion) <= 0 || manifest.minSdk > sdkInt) {
            throw IOException("Update is not compatible or newer")
        }
        val file = child("$key.apk")
        verifyFile(file, manifest)
        apkVerifier(file, manifest)
    }

    private fun removeStage(key: String) {
        child("$key.apk").delete()
        child("$key.json").delete()
    }

    private fun cleanupUnusedStages() {
        root.listFiles()?.filter { it.name.matches(Regex("[1-9][0-9]{0,9}-[a-f0-9]{64}\\.(apk|json)")) }
            ?.filter { it.name.substringBeforeLast('.') != staged }
            ?.forEach { runCatching { child(it.name).delete() } }
    }

    private fun atomicText(destination: File, text: String) {
        val temp = child("stage-${UUID.randomUUID()}.part")
        try {
            FileOutputStream(temp).use { it.write(text.toByteArray(Charsets.UTF_8)); it.fd.sync() }
            atomicMove(temp, destination)
        } finally { temp.delete() }
    }

    companion object {
        const val REPOSITORY = "Project-Ptolemy/ProjectUAI"
        const val RELEASES_URL = "https://api.github.com/repos/$REPOSITORY/releases?per_page=100"
        const val MAX_APK_BYTES = 150L * 1024 * 1024
        private val codec = Json { ignoreUnknownKeys = true }
        data class Candidate(val version: String, val manifestUrl: String, val apkUrl: String)

        fun parseManifest(text: String, expectedVersion: String? = null): RelayManifest {
            if (text.toByteArray(Charsets.UTF_8).size > 64 * 1024) throw IOException("Manifest limit")
            val value = codec.decodeFromString<RelayManifest>(text)
            versionParts(value.version)
            if (value.format != "project-uai-relay-release" || value.schema != 1 || value.platform != "android" ||
                value.applicationId != "dev.projectuai.relay" || value.protocol != 2 || value.versionCode !in 1..2_100_000_000L ||
                value.minSdk !in 26..100 || expectedVersion != null && expectedVersion != value.version ||
                value.artifact.name != "UAI-Relay-${value.version}.apk" || value.artifact.bytes !in 1..MAX_APK_BYTES ||
                !value.artifact.sha256.matches(Regex("[a-f0-9]{64}")) || !value.artifact.signerSha256.matches(Regex("[a-f0-9]{64}"))) {
                throw IOException("Invalid relay release manifest")
            }
            return value
        }

        fun candidates(text: String, currentVersion: String): List<Candidate> {
            val releases = codec.parseToJsonElement(text) as? JsonArray ?: throw IOException("Invalid release list")
            val found = ArrayList<Candidate>()
            for (item in releases.take(100)) {
                val release = item as? JsonObject ?: continue
                if (release["draft"] != JsonPrimitive(false) || release["prerelease"] != JsonPrimitive(false)) continue
                val tag = release["tag_name"]?.jsonPrimitive?.content ?: continue
                val version = Regex("(?:relay-)?v([0-9]+\\.[0-9]+\\.[0-9]+)").matchEntire(tag)?.groupValues?.get(1) ?: continue
                if (runCatching { compareVersions(version, currentVersion) > 0 }.getOrDefault(false).not()) continue
                val assets = release["assets"] as? JsonArray ?: continue
                fun asset(name: String): String? {
                    val matches = assets.mapNotNull { it as? JsonObject }.filter { it["name"] == JsonPrimitive(name) }
                    val expected = "https://github.com/$REPOSITORY/releases/download/$tag/$name"
                    return expected.takeIf { matches.size == 1 && matches[0]["browser_download_url"] == JsonPrimitive(expected) }
                }
                val manifest = asset("relay-release.json") ?: continue
                val apk = asset("UAI-Relay-$version.apk") ?: continue
                found += Candidate(version, manifest, apk)
            }
            return found.sortedWith { a, b -> compareVersions(b.version, a.version) }
        }

        private fun versionParts(value: String): List<Int> {
            if (!value.matches(Regex("(0|[1-9][0-9]{0,5})\\.(0|[1-9][0-9]{0,5})\\.(0|[1-9][0-9]{0,5})"))) throw IOException("Invalid stable version")
            return value.split('.').map { it.toInt() }
        }

        fun compareVersions(a: String, b: String): Int {
            val left = versionParts(a); val right = versionParts(b)
            for (i in 0..2) if (left[i] != right[i]) return left[i].compareTo(right[i])
            return 0
        }

        private fun read(file: File, limit: Int): String {
            if (!file.isFile || file.length() > limit) throw IOException("Invalid cached metadata")
            return file.inputStream().use { input ->
                val output = ByteArrayOutputStream()
                val buffer = ByteArray(8192)
                while (true) {
                    val count = input.read(buffer)
                    if (count < 0) break
                    if (output.size() + count > limit) throw IOException("Cached metadata limit")
                    output.write(buffer, 0, count)
                }
                output.toString(Charsets.UTF_8.name())
            }
        }

        private fun verifyFile(file: File, manifest: RelayManifest) {
            if (!file.isFile || file.length() != manifest.artifact.bytes) throw IOException("APK size mismatch")
            val digest = MessageDigest.getInstance("SHA-256")
            file.inputStream().use { input ->
                val buffer = ByteArray(64 * 1024)
                var total = 0L
                while (true) {
                    val count = input.read(buffer)
                    if (count < 0) break
                    total += count
                    if (total > manifest.artifact.bytes) throw IOException("APK grew during verification")
                    digest.update(buffer, 0, count)
                }
                if (total != manifest.artifact.bytes) throw IOException("APK changed during verification")
            }
            if (digest.digest().joinToString("") { "%02x".format(it) } != manifest.artifact.sha256) throw IOException("APK hash mismatch")
        }

        private fun atomicMove(source: File, target: File) {
            Files.move(source.toPath(), target.toPath(), StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING)
        }
    }
}
