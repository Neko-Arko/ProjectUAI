package dev.projectuai.relay.ui

/** Status follows this service run's authenticated contact, never a saved token. */
internal data class RelayPresentation(
    val title: String,
    val detail: String,
    val relayLabel: String,
    val robloxLabel: String,
    val connected: Boolean = false,
)

internal fun relayPresentation(running: Boolean, lastClientAt: Long, now: Long, updatePending: Boolean): RelayPresentation {
    val contactAge = if (lastClientAt > 0) (now - lastClientAt).coerceAtLeast(0) / 1000 else -1
    val robloxLabel = when {
        !running -> "Not connected"
        contactAge < 0 -> "Waiting for the script"
        contactAge <= 45 -> "Connected"
        else -> "Last seen ${contactAge}s ago"
    }
    return when {
        updatePending -> RelayPresentation(
            "Paused for an update",
            "New replies are paused. App updates below shows the next step.",
            if (running) "Paused" else "Off", robloxLabel,
        )
        !running -> RelayPresentation(
            "Ready when you are.",
            "Start the relay, then open Project UAI in Roblox on this phone.",
            "Off", robloxLabel,
        )
        contactAge < 0 -> RelayPresentation(
            "Now open Roblox.",
            "The relay is running. Run the Project UAI script to connect automatically.",
            "Running", robloxLabel,
        )
        contactAge <= 45 -> RelayPresentation(
            "You're connected.",
            "Send your message in Project UAI. Keep the relay running while you play.",
            "Running", robloxLabel, connected = true,
        )
        else -> RelayPresentation(
            "Waiting for Roblox.",
            "The relay is still running. Return to Project UAI in Roblox to reconnect.",
            "Running", robloxLabel,
        )
    }
}

internal fun installationPausesRelay(phase: String): Boolean =
    phase == "confirming" || phase == "confirmation_ready" || phase == "interrupted" || phase == "replacing"
