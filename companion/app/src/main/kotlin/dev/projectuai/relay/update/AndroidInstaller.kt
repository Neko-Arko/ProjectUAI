package dev.projectuai.relay.update

import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import android.os.Build
import java.io.File

/** Android owns the copied APK and confirmation; the app owns its cancellable session. */
class AndroidInstaller(private val context: Context) {
    private val installer get() = context.packageManager.packageInstaller

    fun prepare(apk: File, created: (Int) -> Unit): Int {
        val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL)
        params.setAppPackageName(context.packageName)
        params.setSize(apk.length())
        if (Build.VERSION.SDK_INT >= 31) params.setRequireUserAction(PackageInstaller.SessionParams.USER_ACTION_REQUIRED)
        val id = installer.createSession(params)
        try {
            created(id)
            installer.openSession(id).use { session ->
                session.openWrite("base.apk", 0, apk.length()).use { output ->
                    apk.inputStream().use { input -> input.copyTo(output) }
                    session.fsync(output)
                }
            }
            return id
        } catch (failure: Exception) {
            runCatching { installer.abandonSession(id) }
            throw failure
        }
    }

    fun commit(id: Int) {
        val callback = Intent(context, UpdateInstallReceiver::class.java)
            .setAction("${context.packageName}.UPDATE_INSTALL_STATUS")
            .putExtra("uaiSessionId", id)
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or if (Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_MUTABLE else 0
        val pending = PendingIntent.getBroadcast(context, id, callback, flags)
        installer.openSession(id).use { it.commit(pending.intentSender) }
    }

    /** Only this app's own self-update sessions can be abandoned by this path. */
    fun abandonOwned(id: Int) {
        installer.mySessions.filter { id < 0 || it.sessionId == id }.forEach { session ->
            // Android can omit package metadata before it has parsed the copied APK.
            // The persisted session ID and mySessions still establish our ownership.
            if (session.appPackageName == null || session.appPackageName == context.packageName) {
                installer.abandonSession(session.sessionId)
            } else if (id >= 0) {
                throw SecurityException("The saved installer session belongs to another package.")
            }
        }
    }
}
