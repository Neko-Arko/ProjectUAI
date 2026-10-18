package dev.projectuai.relay.update

import dev.projectuai.relay.data.MemorySettings
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class InstallSessionTest {
    @Test
    fun `cancelling the installer releases admission exactly once`() {
        var reserved = false
        var releases = 0
        val session = InstallSession(reserve = { reserved = true; true }, release = { reserved = false; releases++ })
        assertEquals(InstallSession.Result.LAUNCHED, session.launch("1.2.0") {})
        assertTrue(reserved)
        session.finish()
        session.finish()
        assertFalse(reserved)
        assertEquals(1, releases)
    }

    @Test
    fun `installer launch failure releases admission and allows a retry`() {
        var releases = 0
        val session = InstallSession(reserve = { true }, release = { releases++ })
        assertEquals(InstallSession.Result.FAILED, session.launch("1.2.0") { throw IllegalStateException("no installer") })
        assertEquals(1, releases)
        assertEquals(InstallSession.Result.LAUNCHED, session.launch("1.2.0") {})
        session.finish()
        assertEquals(2, releases)
    }

    @Test
    fun `busy relay never launches the installer or releases someone else's gate`() {
        var launched = false
        var released = false
        val session = InstallSession(reserve = { false }, release = { released = true })
        assertEquals(InstallSession.Result.BUSY, session.launch("1.2.0") { launched = true })
        session.finish()
        assertFalse(launched)
        assertFalse(released)
    }

    @Test
    fun `failed release retains ownership so recovery can retry`() {
        var fail = true
        var releases = 0
        val session = InstallSession(reserve = { true }, release = {
            if (fail) throw IllegalStateException("preference commit failed")
            releases++
        })
        session.launch("1.2.0") {}
        org.junit.Assert.assertThrows(IllegalStateException::class.java) { session.finish() }
        assertEquals(InstallSession.Result.BUSY, session.launch("1.2.0") {})
        fail = false
        assertTrue(session.finish())
        assertFalse(session.finish())
        assertEquals(1, releases)
    }

    @Test
    fun `ambiguous commit failure abandons before releasing and retains gate when abandonment fails`() {
        val events = ArrayList<String>()
        var canAbandon = false
        val session = InstallSession(reserve = { true }, release = { events.add("release") },
            abort = { events.add("abandon"); canAbandon })
        assertEquals(InstallSession.Result.FAILED, session.launch("1.2.0") { throw IllegalStateException("commit response lost") })
        assertEquals(listOf("abandon"), events)
        assertEquals(InstallSession.Result.BUSY, session.launch("1.2.0") {})
        canAbandon = true
        val recovery = InstallRecovery(MemorySettings(updateInstallPending = true), abandon = {
            check(canAbandon)
            events.add("abandon succeeded")
        }, release = { session.finish() })
        assertTrue(recovery.resume())
        assertEquals(listOf("abandon", "abandon succeeded", "release"), events)
    }
}
