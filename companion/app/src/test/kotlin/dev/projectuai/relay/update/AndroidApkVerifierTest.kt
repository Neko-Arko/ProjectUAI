package dev.projectuai.relay.update

import org.junit.Assert.assertThrows
import org.junit.Test
import java.io.IOException

/** Tests identity policy only; Android's native APK parser/installer require a device. */
class AndroidApkVerifierTest {
    private val signer = "a".repeat(64)
    private val installed = ApkIdentity("dev.projectuai.relay", "1.1.0", 2, 26, setOf(signer))
    private val archive = installed.copy(version = "1.2.0", versionCode = 3)
    private val manifest = RelayManifest("project-uai-relay-release", 1, "1.2.0", 3, "android", "dev.projectuai.relay", 26, 2,
        RelayPackage("UAI-Relay-1.2.0.apk", 128, "b".repeat(64), signer))

    @Test
    fun `matching metadata and installed signing identity are accepted`() {
        AndroidApkVerifier.verifyIdentity(installed, archive, manifest)
    }

    @Test
    fun `different package version code name and minimum SDK are rejected`() {
        listOf(
            archive.copy(applicationId = "other.application"),
            archive.copy(versionCode = 4),
            archive.copy(version = "1.2.1"),
            archive.copy(minSdk = 27),
            archive.copy(versionCode = installed.versionCode),
            archive.copy(debuggable = true),
        ).forEach { changed ->
            assertThrows(IOException::class.java) { AndroidApkVerifier.verifyIdentity(installed, changed, manifest) }
        }
    }

    @Test
    fun `different missing multiple and manifest mismatched signers are rejected`() {
        listOf(setOf("c".repeat(64)), emptySet(), setOf(signer, "c".repeat(64))).forEach { changed ->
            assertThrows(IOException::class.java) { AndroidApkVerifier.verifyIdentity(installed, archive.copy(signers = changed), manifest) }
        }
        assertThrows(IOException::class.java) {
            AndroidApkVerifier.verifyIdentity(installed, archive, manifest.copy(artifact = manifest.artifact.copy(signerSha256 = "c".repeat(64))))
        }
        assertThrows(IOException::class.java) {
            AndroidApkVerifier.verifyIdentity(installed.copy(signers = emptySet()), archive, manifest)
        }
    }
}
