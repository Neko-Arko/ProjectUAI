package dev.projectuai.relay.update

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import android.net.Uri
import android.os.Build
import android.provider.Settings
import dev.projectuai.relay.RelayLog
import dev.projectuai.relay.data.RelaySettings
import dev.projectuai.relay.service.RelayService
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.withContext
import java.io.File
import java.lang.ref.WeakReference

data class InstallState(val phase: String = "idle", val detail: String = "")

/** App-owned update work never shares the provider scope or silently installs an APK. */
class UpdateCoordinator(
    private val context: Context,
    private val settings: RelaySettings,
    private val log: RelayLog,
) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val restored = CompletableDeferred<Unit>()
    private val checkLock = Mutex()
    private val installLock = Mutex()
    private val androidInstaller = AndroidInstaller(context)
    private val installSession = InstallSession(
        reserve = { version -> RelayService.beginUpdateInstall(context, version) },
        release = { RelayService.endUpdateInstall(context) },
        abort = { runCatching { androidInstaller.abandonOwned(settings.updateInstallSessionId) }.isSuccess },
    )
    private val recovery = InstallRecovery(settings, androidInstaller::abandonOwned) {
        if (!installSession.finish()) RelayService.endUpdateInstall(context)
    }
    private data class Confirmation(val activity: WeakReference<Activity>, val launch: (Intent) -> Unit)
    private var confirmation: Confirmation? = null
    private var confirmationIntent: Intent? = null
    @Suppress("DEPRECATION")
    private val installed = context.packageManager.getPackageInfo(context.packageName, 0)
    val currentVersion: String = installed.versionName ?: "unknown"
    @Suppress("DEPRECATION")
    private val currentVersionCode = if (Build.VERSION.SDK_INT >= 28) installed.longVersionCode else installed.versionCode.toLong()
    private val verifier = AndroidApkVerifier(context)
    private val updater = RelayUpdater(File(context.filesDir, "updates"), currentVersion, currentVersionCode,
        Build.VERSION.SDK_INT, apkVerifier = { file, manifest -> verifier(file, manifest) })
    val state: StateFlow<UpdateState> = updater.state
    private val _automatic = MutableStateFlow(settings.automaticUpdates)
    val automatic: StateFlow<Boolean> = _automatic.asStateFlow()
    private val _lastChecked = MutableStateFlow(settings.lastUpdateCheckAt)
    val lastChecked: StateFlow<Long> = _lastChecked.asStateFlow()
    private val _install = MutableStateFlow(if (settings.updateInstallPending) interrupted() else InstallState())
    val install: StateFlow<InstallState> = _install.asStateFlow()
    private val _installAllowed = MutableStateFlow(context.packageManager.canRequestPackageInstalls())
    val installAllowed: StateFlow<Boolean> = _installAllowed.asStateFlow()

    init {
        scope.launch {
            try {
                if (settings.lastInstallVersion == currentVersion) {
                    val resume = InstallationRecord.consumeReplacement(settings, currentVersion)
                    withContext(Dispatchers.Main) {
                        RelayService.endUpdateInstall(context)
                        if (InstallationRecord.mayResume(settings, resume)) RelayService.start(context)
                        _install.value = InstallState("idle", "Android installed the update.")
                    }
                }
                // A crash during APK copying can leave a session before reservation.
                // No installer is active in that state; clear all our stale sessions.
                if (!settings.updateInstallPending) {
                    androidInstaller.abandonOwned(-1)
                    settings.updateInstallSessionId = -1
                }
                updater.restore()
            } catch (_: Exception) {
                log.add("Saved update state needs another check")
            } finally { restored.complete(Unit) }
            check(manual = false)
            while (isActive) { delay(CHECK_INTERVAL_MS); check(manual = false) }
        }
    }

    fun automaticDownloads(enabled: Boolean) {
        settings.automaticUpdates = enabled
        _automatic.value = enabled
        if (enabled) check(manual = false)
    }

    fun checkNow() = check(manual = true)

    private fun check(manual: Boolean) {
        scope.launch {
            restored.await()
            if (!checkLock.tryLock()) return@launch
            try {
                updater.check(download = manual || settings.automaticUpdates)
                settings.lastUpdateCheckAt = System.currentTimeMillis()
                _lastChecked.value = settings.lastUpdateCheckAt
            } catch (cancelled: CancellationException) { throw cancelled
            } catch (_: Exception) { log.add("App update check could not finish; another check will follow")
            } finally { checkLock.unlock() }
        }
    }

    fun refreshInstallPermission() { _installAllowed.value = context.packageManager.canRequestPackageInstalls() }

    fun allowInstallation(activity: Activity, launch: (Intent) -> Unit) {
        if (settings.updateInstallPending) return
        try {
            launch(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:${activity.packageName}")))
            _install.value = InstallState("permission", "Return here and tap Install after allowing app updates.")
        } catch (_: RuntimeException) {
            _install.value = InstallState("error", "Android could not open this app's installation permission settings.")
        }
    }

    fun permissionReturned() {
        refreshInstallPermission()
        if (settings.updateInstallPending) return
        _install.value = InstallState("idle", if (_installAllowed.value) "Permission granted. Tap Install when ready." else "Installation permission is still off.")
    }

    fun requestInstall(activity: Activity, launch: (Intent) -> Unit) {
        if (_install.value.phase == "replacing") return
        if (settings.updateInstallPending) {
            confirmation = Confirmation(WeakReference(activity), launch)
            if (!showConfirmation()) _install.value = interrupted()
            return
        }
        scope.launch {
            if (!installLock.tryLock()) return@launch
            try {
                restored.await()
                if (settings.updateInstallPending) { _install.value = interrupted(); return@launch }
                _install.value = InstallState("preparing", "Checking the downloaded Android package again.")
                // RelayUpdater keeps a verified staged file/version immutable across
                // checks. Restore is finished and installLock serializes invalidation.
                val apk = updater.verifiedApk()
                val version = state.value.version
                if (apk == null || version == null) {
                    _install.value = InstallState("error", "No verified update is ready. Check for updates again.")
                    return@launch
                }
                val allowed = withContext(Dispatchers.Main) {
                    refreshInstallPermission()
                    if (!_installAllowed.value) _install.value = InstallState("permission", "Allow this app to install updates, then tap Install.")
                    val focused = !activity.isFinishing && !activity.isDestroyed && activity.hasWindowFocus()
                    if (_installAllowed.value && !focused) _install.value = InstallState("waiting", "Return to this app and tap Install when ready.")
                    _installAllowed.value && focused
                }
                if (!allowed) return@launch
                val id = androidInstaller.prepare(apk) { settings.updateInstallSessionId = it }
                val result = withContext(Dispatchers.Main) {
                    if (activity.isFinishing || activity.isDestroyed || !activity.hasWindowFocus()) return@withContext InstallSession.Result.BUSY
                    installSession.launch(version) {
                        confirmation = Confirmation(WeakReference(activity), launch)
                        _install.value = InstallState("confirming", "Android is preparing its installation confirmation. New relay requests are paused.")
                        androidInstaller.commit(id)
                    }
                }
                if (result != InstallSession.Result.LAUNCHED) {
                    if (result == InstallSession.Result.FAILED && !recovery.resume()) {
                        _install.value = interrupted()
                        return@launch
                    }
                    androidInstaller.abandonOwned(id)
                    settings.updateInstallSessionId = -1
                    _install.value = if (result == InstallSession.Result.BUSY) InstallState("waiting", "Wait for active requests and retained replies, then tap Install while this app is open.")
                        else InstallState("error", "Android could not start installation. The verified update remains ready.")
                } else log.add("Verified update staged in Android; waiting for confirmation")
            } catch (cancelled: CancellationException) { throw cancelled
            } catch (_: Exception) {
                if (recovery.resume()) _install.value = InstallState("error", "The installation could not start. The current app remains available.")
                else _install.value = interrupted()
            } finally { installLock.unlock() }
        }
    }

    /** Called only through an explicit, non-exported PendingIntent owned by this app. */
    fun installerStatus(intent: Intent, finished: () -> Unit) {
        scope.launch {
            var locked = false
            try {
                installLock.lock()
                locked = true
                val id = intent.getIntExtra("uaiSessionId", -1)
                if (_install.value.phase == "replacing" || !settings.updateInstallPending || id < 0 || id != settings.updateInstallSessionId) return@launch
                when (intent.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE)) {
                    PackageInstaller.STATUS_PENDING_USER_ACTION -> withContext(Dispatchers.Main) {
                        @Suppress("DEPRECATION")
                        val prompt = if (Build.VERSION.SDK_INT >= 33) intent.getParcelableExtra(Intent.EXTRA_INTENT, Intent::class.java)
                            else intent.getParcelableExtra<Intent>(Intent.EXTRA_INTENT)
                        confirmationIntent = prompt
                        if (!showConfirmation()) _install.value = InstallState("confirmation_ready", "Open this app and tap Continue installation to confirm with Android, or Resume relay to cancel this attempt.")
                    }
                    PackageInstaller.STATUS_SUCCESS -> withContext(Dispatchers.Main) {
                        installSession.disown()
                        confirmation = null
                        confirmationIntent = null
                        // The old process must not accept new jobs while Android
                        // replaces it. Only the matching new package clears this.
                        _install.value = InstallState("replacing", "Android installed the update; waiting for the updated app.")
                    }
                    else -> cancelInstallation("Android did not install the update. The verified download remains ready.")
                }
            } catch (cancelled: CancellationException) { throw cancelled
            } catch (_: Exception) { if (_install.value.phase != "replacing") _install.value = interrupted()
            } finally { if (locked) installLock.unlock(); finished() }
        }
    }

    /** Never called from startup or permission return; a foreground Install tap owns it. */
    private fun showConfirmation(): Boolean {
        val intent = confirmationIntent ?: return false
        val target = confirmation ?: return false
        val activity = target.activity.get() ?: return false
        if (activity.isFinishing || activity.isDestroyed || !activity.hasWindowFocus()) return false
        return try {
            target.launch(intent)
            confirmationIntent = null
            _install.value = InstallState("confirming", "Confirm or cancel in Android. Resume relay cancels the pending installation if you return without completing it.")
            true
        } catch (_: RuntimeException) { false }
    }

    fun installerReturned() {
        confirmation = null
        if (settings.updateInstallPending && _install.value.phase != "replacing") _install.value = interrupted()
        refreshInstallPermission()
    }

    fun resumeRelay() {
        scope.launch {
            if (!installLock.tryLock()) return@launch
            try {
                if (_install.value.phase != "replacing") cancelInstallation("Pending installation cancelled. The relay can accept requests again.")
            }
            finally { installLock.unlock() }
        }
    }

    private suspend fun cancelInstallation(message: String) {
        val restart = settings.resumeAfterUpdate && !settings.userStopped
        if (recovery.resume()) {
            withContext(Dispatchers.Main) {
                confirmation = null
                confirmationIntent = null
                _install.value = InstallState("idle", message)
                if (InstallationRecord.mayResume(settings, restart)) RelayService.start(context)
            }
        } else _install.value = InstallState("interrupted", "Android could not cancel the pending installation. Finish or cancel it in Android before resuming the relay.")
    }

    companion object {
        private const val CHECK_INTERVAL_MS = 15 * 60 * 1000L
        private fun interrupted() = InstallState("interrupted", "An installation attempt is pending. Resume relay cancels its Android session before accepting new requests; then you can try Install again.")
    }
}
