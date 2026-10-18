package dev.projectuai.relay.update

import dev.projectuai.relay.data.MemorySettings
import org.junit.Assert.*
import org.junit.Test

/** Persisted-state model and injected installer; this does not execute Android APIs. */
class InstallRecoveryTest {
    private fun pending() = MemorySettings(token = "d".repeat(64), userStopped = false,
        lastInstallVersion = "1.2.0", resumeAfterUpdate = true, updateInstallPending = true, updateInstallSessionId = 42)

    @Test
    fun `a fresh coordinator abandons persisted Android work before releasing admission`() {
        val saved = pending()
        val reloaded = MemorySettings(token = saved.token, userStopped = saved.userStopped,
            lastInstallVersion = saved.lastInstallVersion, resumeAfterUpdate = saved.resumeAfterUpdate,
            updateInstallPending = saved.updateInstallPending, updateInstallSessionId = saved.updateInstallSessionId)
        val events = ArrayList<String>()
        val recovery = InstallRecovery(reloaded, abandon = { id ->
            assertEquals(42, id)
            assertTrue(reloaded.updateInstallPending)
            events.add("abandon")
        }, release = { reloaded.updateInstallPending = false; events.add("release") })
        assertTrue(recovery.resume())
        assertEquals(listOf("abandon", "release"), events)
        assertFalse(reloaded.updateInstallPending)
        assertEquals(-1, reloaded.updateInstallSessionId)
        assertEquals(saved.token, reloaded.token)
        assertFalse(reloaded.userStopped)
    }

    @Test
    fun `failed abandonment keeps the persisted reservation and session identity`() {
        val saved = pending()
        var released = false
        val recovery = InstallRecovery(saved, abandon = { throw SecurityException("installer busy") }, release = { released = true })
        assertFalse(recovery.resume())
        assertFalse(released)
        assertTrue(saved.updateInstallPending)
        assertEquals(42, saved.updateInstallSessionId)
    }

    @Test
    fun `only the requested installed version consumes the restart marker`() {
        val saved = pending()
        assertFalse(InstallationRecord.consumeReplacement(saved, "1.1.0"))
        assertTrue(saved.updateInstallPending)
        assertTrue(InstallationRecord.consumeReplacement(saved, "1.2.0"))
        assertFalse(saved.updateInstallPending)
        assertEquals(-1, saved.updateInstallSessionId)
        assertFalse(InstallationRecord.consumeReplacement(saved, "1.2.0"))
        assertEquals("d".repeat(64), saved.token)
    }

    @Test
    fun `explicit stop survives successful replacement`() {
        val saved = pending()
        InstallationRecord.stopRequested(saved)
        assertFalse(InstallationRecord.consumeReplacement(saved, "1.2.0"))
        assertTrue(saved.userStopped)
        assertFalse(saved.updateInstallPending)
        assertFalse(saved.resumeAfterUpdate)
        assertEquals("d".repeat(64), saved.token)
    }

    @Test
    fun `stop during installer cleanup invalidates an earlier restart decision`() {
        val saved = pending()
        val restartBeforeCleanup = saved.resumeAfterUpdate
        val recovery = InstallRecovery(saved, abandon = {
            InstallationRecord.stopRequested(saved)
        }, release = { saved.updateInstallPending = false })
        assertTrue(recovery.resume())
        assertTrue(restartBeforeCleanup)
        assertFalse(InstallationRecord.mayResume(saved, restartBeforeCleanup))
        assertTrue(saved.userStopped)
        assertFalse(saved.resumeAfterUpdate)
        assertEquals("d".repeat(64), saved.token)
    }
}
