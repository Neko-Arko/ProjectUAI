package dev.projectuai.relay.update

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import dev.projectuai.relay.RelayApp

/** Explicit, non-exported PendingIntent callback from Android's package installer. */
class UpdateInstallReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val pending = goAsync()
        (context.applicationContext as RelayApp).updates.installerStatus(intent) { pending.finish() }
    }
}
