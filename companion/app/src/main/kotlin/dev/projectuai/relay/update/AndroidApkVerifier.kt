package dev.projectuai.relay.update

import android.content.Context
import android.content.pm.PackageInfo
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.os.Build
import java.io.File
import java.io.IOException
import java.security.MessageDigest

/** Archive identity checks supplement the core's byte/hash checks and Android's installer. */
class AndroidApkVerifier(private val context: Context) {
    @Suppress("DEPRECATION")
    operator fun invoke(apk: File, manifest: RelayManifest) {
        val flags = if (Build.VERSION.SDK_INT >= 28) PackageManager.GET_SIGNING_CERTIFICATES else PackageManager.GET_SIGNATURES
        val installed = context.packageManager.getPackageInfo(context.packageName, flags)
        val archive = context.packageManager.getPackageArchiveInfo(apk.absolutePath, flags)
            ?: throw IOException("The downloaded file is not a readable Android package.")
        verifyIdentity(identity(installed), identity(archive), manifest)
    }

    @Suppress("DEPRECATION")
    private fun identity(info: PackageInfo): ApkIdentity {
        val signatures = if (Build.VERSION.SDK_INT >= 28) info.signingInfo?.apkContentsSigners else info.signatures
        return ApkIdentity(
            applicationId = info.packageName,
            version = info.versionName ?: "",
            versionCode = if (Build.VERSION.SDK_INT >= 28) info.longVersionCode else info.versionCode.toLong(),
            minSdk = info.applicationInfo?.minSdkVersion ?: throw IOException("Android package metadata is missing."),
            debuggable = info.applicationInfo?.flags?.and(ApplicationInfo.FLAG_DEBUGGABLE) != 0,
            signers = signatures.orEmpty().map { signature ->
                MessageDigest.getInstance("SHA-256").digest(signature.toByteArray()).joinToString("") { "%02x".format(it) }
            }.toSet(),
        )
    }

    companion object {
        internal fun verifyIdentity(installed: ApkIdentity, archive: ApkIdentity, manifest: RelayManifest) {
            if (installed.applicationId != manifest.applicationId || archive.applicationId != manifest.applicationId ||
                archive.version != manifest.version || archive.versionCode != manifest.versionCode || archive.minSdk != manifest.minSdk ||
                archive.versionCode <= installed.versionCode || archive.debuggable) {
                throw IOException("The downloaded Android package does not match the update metadata.")
            }
            if (installed.signers.size != 1 || archive.signers.size != 1 || installed.signers != archive.signers ||
                archive.signers.single() != manifest.artifact.signerSha256.lowercase()) {
                throw IOException("The update was not signed with this installation's signing key.")
            }
        }
    }
}

internal data class ApkIdentity(
    val applicationId: String,
    val version: String,
    val versionCode: Long,
    val minSdk: Int,
    val signers: Set<String>,
    val debuggable: Boolean = false,
)
