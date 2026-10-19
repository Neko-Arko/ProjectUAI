package dev.projectuai.relay.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class RelayPresentationTest {
    @Test fun stoppedRelayNeverReportsOldClientContactAsConnected() {
        val view = relayPresentation(running = false, lastClientAt = 99_000, now = 100_000, updatePending = false)
        assertEquals("Off", view.relayLabel)
        assertEquals("Not connected", view.robloxLabel)
        assertFalse(view.connected)
    }

    @Test fun listenerWithoutAuthenticatedContactStillWaitsForRoblox() {
        val view = relayPresentation(running = true, lastClientAt = 0, now = 100_000, updatePending = false)
        assertEquals("Running", view.relayLabel)
        assertEquals("Waiting for the script", view.robloxLabel)
        assertFalse(view.connected)
    }

    @Test fun recentContactExpiresWithoutPretendingTheRelayStopped() {
        val recent = relayPresentation(running = true, lastClientAt = 55_000, now = 100_000, updatePending = false)
        assertTrue(recent.connected)
        val stale = relayPresentation(running = true, lastClientAt = 54_000, now = 100_000, updatePending = false)
        assertEquals("Running", stale.relayLabel)
        assertEquals("Last seen 46s ago", stale.robloxLabel)
        assertFalse(stale.connected)
    }

    @Test fun pendingInstallationDoesNotInviteMessagesEvenWhenRobloxIsConnected() {
        val view = relayPresentation(running = true, lastClientAt = 99_000, now = 100_000, updatePending = true)
        assertEquals("Paused", view.relayLabel)
        assertEquals("Connected", view.robloxLabel)
        assertFalse(view.connected)
        val stopped = relayPresentation(running = false, lastClientAt = 0, now = 100_000, updatePending = true)
        assertEquals("Off", stopped.relayLabel)
    }

    @Test fun onlyOwnedInstallationPhasesPauseTheRelay() {
        listOf("confirming", "confirmation_ready", "interrupted", "replacing").forEach {
            assertTrue(it, installationPausesRelay(it))
        }
        listOf("idle", "preparing", "permission", "waiting", "error").forEach {
            assertFalse(it, installationPausesRelay(it))
        }
    }
}
