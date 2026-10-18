package dev.projectuai.relay.update

import dev.projectuai.relay.data.RelaySettings

/** An interrupted Android installer must lose its session before admission resumes. */
internal class InstallRecovery(
    private val settings: RelaySettings,
    private val abandon: (Int) -> Unit,
    private val release: () -> Unit,
) {
    fun resume(): Boolean {
        return try {
            abandon(settings.updateInstallSessionId)
            settings.updateInstallSessionId = -1
            release()
            true
        } catch (_: RuntimeException) {
            false
        }
    }
}
