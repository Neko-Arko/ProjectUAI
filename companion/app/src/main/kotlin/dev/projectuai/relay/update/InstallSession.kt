package dev.projectuai.relay.update

/** Small platform-independent ownership rule for the Android installer reservation. */
internal class InstallSession(
    private val reserve: (String) -> Boolean,
    private val release: () -> Unit,
    private val abort: () -> Boolean = { true },
) {
    enum class Result { LAUNCHED, BUSY, FAILED }
    private var active = false

    @Synchronized
    fun launch(version: String, action: () -> Unit): Result {
        if (active || !reserve(version)) return Result.BUSY
        active = true
        return try {
            action()
            Result.LAUNCHED
        } catch (_: RuntimeException) {
            if (abort()) finish()
            Result.FAILED
        }
    }

    @Synchronized
    fun finish(): Boolean {
        if (!active) return false
        release()
        active = false
        return true
    }

    @Synchronized
    fun disown() { active = false }
}
