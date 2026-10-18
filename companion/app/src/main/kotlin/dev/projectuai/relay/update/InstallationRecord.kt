package dev.projectuai.relay.update

import dev.projectuai.relay.data.RelaySettings

/** Only the installed requested version may consume a successful update's restart marker. */
object InstallationRecord {
    /** Record the user's intent before any service command is queued. */
    @Synchronized
    fun stopRequested(settings: RelaySettings) {
        settings.userStopped = true
        settings.resumeAfterUpdate = false
    }

    /** Recheck after asynchronous installer cleanup, immediately before restart. */
    @Synchronized
    fun mayResume(settings: RelaySettings, requested: Boolean): Boolean = requested && !settings.userStopped

    @Synchronized
    fun consumeReplacement(settings: RelaySettings, installedVersion: String?): Boolean {
        if (settings.lastInstallVersion != installedVersion) return false
        val resume = mayResume(settings, settings.resumeAfterUpdate)
        settings.updateInstallPending = false
        settings.updateInstallSessionId = -1
        settings.resumeAfterUpdate = false
        return resume
    }
}
