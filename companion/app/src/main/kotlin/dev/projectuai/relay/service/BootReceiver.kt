package dev.projectuai.relay.service

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import dev.projectuai.relay.RelayApp
import dev.projectuai.relay.update.InstallationRecord

/** Resurrects a relay that was running when the device rebooted or the app updated. */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val settings = (context.applicationContext as RelayApp).settings
        if (intent.action == Intent.ACTION_MY_PACKAGE_REPLACED) {
            @Suppress("DEPRECATION")
            val installedVersion = context.packageManager.getPackageInfo(context.packageName, 0).versionName
            if (settings.lastInstallVersion == installedVersion) {
                val resume = InstallationRecord.consumeReplacement(settings, installedVersion)
                RelayService.endUpdateInstall(context)
                if (InstallationRecord.mayResume(settings, resume)) RelayService.start(context)
            }
            return
        }
        if (settings.autoStart && !settings.userStopped) RelayService.start(context)
    }
}
