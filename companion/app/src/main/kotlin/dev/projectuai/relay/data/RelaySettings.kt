package dev.projectuai.relay.data

import android.content.Context
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey

/**
 * Persisted relay state. The token is stable across restarts so a killed-and-restarted
 * service never forces a re-pair; `userStopped` is the one flag watchdogs must respect.
 */
interface RelaySettings {
    var port: Int
    var token: String
    var userStopped: Boolean
    var autoStart: Boolean
    var automaticUpdates: Boolean
    var kiloEnabled: Boolean
    var lastUpdateCheckAt: Long
    var lastInstallVersion: String
    var resumeAfterUpdate: Boolean
    var updateInstallPending: Boolean
    var updateInstallSessionId: Int
    fun rotateToken() { token = "" }
}

class PrefsSettings(context: Context) : RelaySettings {
    private val prefs = EncryptedSharedPreferences.create(
        context,
        "relay",
        MasterKey.Builder(context).setKeyScheme(MasterKey.KeyScheme.AES256_GCM).build(),
        EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
        EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
    )

    override var port: Int
        get() = prefs.getInt("port", DEFAULT_PORT)
        set(value) = prefs.edit().putInt("port", value.coerceIn(1, 65535)).apply()

    override var token: String
        get() = prefs.getString("token", "") ?: ""
        set(value) = prefs.edit().putString("token", value).apply()

    override var userStopped: Boolean
        get() = prefs.getBoolean("userStopped", false)
        set(value) { check(prefs.edit().putBoolean("userStopped", value).commit()) { "Could not save relay stop preference" } }

    override var autoStart: Boolean
        get() = prefs.getBoolean("autoStart", true)
        set(value) = prefs.edit().putBoolean("autoStart", value).apply()

    override var automaticUpdates: Boolean
        get() = prefs.getBoolean("automaticUpdates", true)
        set(value) = prefs.edit().putBoolean("automaticUpdates", value).apply()

    override var kiloEnabled: Boolean
        get() = prefs.getBoolean("kiloEnabled", true)
        set(value) = prefs.edit().putBoolean("kiloEnabled", value).apply()

    override var lastUpdateCheckAt: Long
        get() = prefs.getLong("lastUpdateCheckAt", 0)
        set(value) = prefs.edit().putLong("lastUpdateCheckAt", value).apply()

    override var lastInstallVersion: String
        get() = prefs.getString("lastInstallVersion", "") ?: ""
        set(value) { check(prefs.edit().putString("lastInstallVersion", value).commit()) { "Could not save installation state" } }

    override var resumeAfterUpdate: Boolean
        get() = prefs.getBoolean("resumeAfterUpdate", false)
        set(value) { check(prefs.edit().putBoolean("resumeAfterUpdate", value).commit()) { "Could not save installation state" } }

    override var updateInstallPending: Boolean
        get() = prefs.getBoolean("updateInstallPending", false)
        set(value) { check(prefs.edit().putBoolean("updateInstallPending", value).commit()) { "Could not save installation state" } }

    override var updateInstallSessionId: Int
        get() = prefs.getInt("updateInstallSessionId", -1)
        set(value) { check(prefs.edit().putInt("updateInstallSessionId", value).commit()) { "Could not save installation state" } }

    companion object {
        const val DEFAULT_PORT = 8790
    }
}

/** JVM tests and previews: no Android dependency. */
class MemorySettings(
    override var port: Int = 8790,
    override var token: String = "",
    override var userStopped: Boolean = false,
    override var autoStart: Boolean = true,
    override var automaticUpdates: Boolean = true,
    override var lastUpdateCheckAt: Long = 0,
    override var lastInstallVersion: String = "",
    override var resumeAfterUpdate: Boolean = false,
    override var updateInstallPending: Boolean = false,
    override var updateInstallSessionId: Int = -1,
    override var kiloEnabled: Boolean = true,
) : RelaySettings
