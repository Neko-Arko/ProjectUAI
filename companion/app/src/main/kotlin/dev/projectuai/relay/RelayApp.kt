package dev.projectuai.relay

import android.app.Application
import dev.projectuai.relay.data.PrefsSettings
import dev.projectuai.relay.data.RelaySettings
import dev.projectuai.relay.update.UpdateCoordinator

class RelayApp : Application() {
    lateinit var settings: RelaySettings
        private set
    val log = RelayLog()
    lateinit var updates: UpdateCoordinator
        private set

    override fun onCreate() {
        super.onCreate()
        settings = PrefsSettings(this)
        updates = UpdateCoordinator(this, settings, log)
    }
}
