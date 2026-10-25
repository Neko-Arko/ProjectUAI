package dev.projectuai.relay.service

import android.app.AlarmManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import dev.projectuai.relay.MainActivity
import dev.projectuai.relay.R
import dev.projectuai.relay.RelayApp
import dev.projectuai.relay.RelayLog
import dev.projectuai.relay.data.RelaySettings
import dev.projectuai.relay.engine.JobEngine
import dev.projectuai.relay.protocol.ActivitySnapshot
import dev.projectuai.relay.server.RelayServer
import dev.projectuai.relay.update.InstallationRecord
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.util.UUID

sealed interface RelayState {
    data object Stopped : RelayState
    data class Running(
        val port: Int,
        val instance: String,
        val paired: Boolean,
        val startedAt: Long,
    ) : RelayState
}

/**
 * The foreground service that owns the loopback server and the upstream connections.
 * It must not die under normal pressure: `specialUse` (no Android 15 six-hour cap),
 * START_STICKY, an exact-alarm watchdog and a wakelock held only while a job is in
 * flight. `userStopped` is the one flag watchdogs respect, so Kill stays down.
 */
class RelayService : Service() {
    private lateinit var settings: RelaySettings
    private lateinit var log: RelayLog
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private var engine: JobEngine? = null
    private var server: RelayServer? = null
    private var maintenance: Job? = null
    private var wakeLock: PowerManager.WakeLock? = null

    private val client = JobEngine.providerClient()

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        val app = application as RelayApp
        settings = app.settings
        log = app.log
        synchronized(installLock) { liveService = this; installPending = settings.updateInstallPending }
        createChannel()
        ServiceCompat.startForeground(this, NOTIFICATION_ID, buildNotification(settings.port, false), foregroundType())
        _state.value = RelayState.Stopped
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_KILL -> {
                kill()
                return START_NOT_STICKY
            }
            ACTION_RESTART -> {
                shutdown()
                start()
            }
            else -> start()
        }
        return START_STICKY
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        // Swiping the app out of Recents is not a Kill.
        if (!settings.userStopped) {
            scheduleWatchdog(this, immediate = true)
            log.add("Task removed; the relay keeps running")
        }
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        shutdown()
        synchronized(installLock) { if (liveService === this) liveService = null }
        scope.cancel()
        super.onDestroy()
    }

    private fun start() {
        synchronized(installLock) {
            // A queued automatic start must never override a newer explicit Stop.
            if (settings.userStopped) {
                shutdown()
                ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
                stopSelf()
                return
            }
            if (installPending || settings.updateInstallPending) {
                log.add("Finish or cancel Android installation before starting the relay")
                return
            }
            if (server != null) return
            val instance = UUID.randomUUID().toString()
            val kilo = if (settings.kiloEnabled) dev.projectuai.relay.engine.KiloRoute(
                dev.projectuai.relay.engine.AndroidKiloConnection(this, client)) else null
            val createdEngine = JobEngine(instance, scope, client, onChanged = { updateActivity() }, kilo = kilo)
            val createdServer = RelayServer(settings.port, instance, settings, createdEngine, log,
                onPaired = { token, place -> _token.value = token; _place.value = place },
                onClientContact = { at -> _lastClientAt.value = at })
            engine = createdEngine
            _kilo.value = createdEngine.kiloCapability()
            server = createdServer
            _activity.value = ActivitySnapshot()
            _lastClientAt.value = 0
            _place.value = 0
            createdServer.start()
            maintenance = scope.launch {
                while (isActive) {
                    delay(5_000)
                    if (engine !== createdEngine) break
                    createdEngine.sweep()
                    _kilo.value = createdEngine.kiloCapability()
                }
            }
            _token.value = settings.token
            _state.value = RelayState.Running(settings.port, instance, settings.token.isNotEmpty(), System.currentTimeMillis())
            log.add("Relay service started on port ${settings.port}")
            scheduleWatchdog(this, immediate = false)
            updateNotification()
        }
    }

    private fun kill() {
        InstallationRecord.stopRequested(settings)
        shutdown()
        log.add("Relay stopped by the user")
        ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun shutdown() {
        maintenance?.cancel()
        maintenance = null
        engine?.close()
        server?.stop()
        server = null
        engine = null
        cancelWatchdog(this)
        releaseWakeLock()
        _state.value = RelayState.Stopped
        _kilo.value = dev.projectuai.relay.protocol.KiloCapability()
        _lastClientAt.value = 0
    }

    @Synchronized
    private fun updateActivity() {
        val current = engine?.activity() ?: return
        val previous = _activity.value
        _activity.value = current
        if (current.acceptedJobs > previous.acceptedJobs) log.add("Request accepted; waiting for the provider")
        if (current.completedJobs > previous.completedJobs) log.add("Provider response received")
        if (current.failedJobs > previous.failedJobs) {
            val category = current.recent.firstOrNull { it.errorCode != null }?.errorCode ?: "transport"
            log.add("Request failed: $category; not repeated")
        }
        if (current.cancelledJobs > previous.cancelledJobs) {
            val disconnected = current.recent.any { job -> job.errorCode == "client_disconnected" &&
                previous.recent.none { before -> before.id == job.id && before.errorCode == "client_disconnected" } }
            log.add(if (disconnected) "Roblox stopped polling; abandoned request cancelled" else "Request cancelled")
        }
        updateNotification()
    }

    @Synchronized
    private fun updateNotification() {
        val engine = engine ?: return
        val working = engine.activeCount > 0
        if (working) acquireWakeLock() else releaseWakeLock()
        val manager = getSystemService(NotificationManager::class.java) ?: return
        manager.notify(NOTIFICATION_ID, buildNotification(settings.port, working))
    }

    private fun createChannel() {
        val manager = getSystemService(NotificationManager::class.java) ?: return
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return
        val channel = NotificationChannel(CHANNEL_ID, getString(R.string.notification_channel), NotificationManager.IMPORTANCE_LOW)
        channel.description = getString(R.string.notification_channel_description)
        channel.setShowBadge(false)
        manager.createNotificationChannel(channel)
    }

    private fun buildNotification(port: Int, working: Boolean) =
        NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_launcher_foreground)
            .setContentTitle(getString(R.string.notification_title))
            .setContentText(if (installPending) "Relay paused for Android update confirmation"
                else if (working) "Inference running on port $port" else "Listening on 127.0.0.1:$port")
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setContentIntent(
                PendingIntent.getActivity(this, 1, Intent(this, MainActivity::class.java),
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE),
            )
            .addAction(0, getString(R.string.notification_stop),
                PendingIntent.getService(this, 2, Intent(this, RelayService::class.java).setAction(ACTION_KILL),
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE))
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            .build()

    @Synchronized
    private fun acquireWakeLock() {
        if (wakeLock?.isHeld == true) return
        val manager = getSystemService(PowerManager::class.java) ?: return
        wakeLock = manager.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "uai-relay:job")
        // Accepted jobs release this in every terminal path and service shutdown.
        // A fixed ten-minute lease silently dropped protection for long reasoning.
        wakeLock?.acquire()
    }

    @Synchronized
    private fun releaseWakeLock() {
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
    }

    private fun foregroundType(): Int =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
        } else {
            0
        }

    companion object {
        const val ACTION_START = "dev.projectuai.relay.action.START"
        const val ACTION_KILL = "dev.projectuai.relay.action.KILL"
        private const val ACTION_RESTART = "dev.projectuai.relay.action.RESTART"
        private const val NOTIFICATION_ID = 41
        private const val CHANNEL_ID = "relay"
        private const val WATCHDOG_REQUEST = 7
        private const val WATCHDOG_INTERVAL_MS = 15 * 60 * 1000L

        private val _state = MutableStateFlow<RelayState>(RelayState.Stopped)
        val state: StateFlow<RelayState> = _state.asStateFlow()
        private val _token = MutableStateFlow("")
        val token: StateFlow<String> = _token.asStateFlow()
        private val _place = MutableStateFlow(0L)
        val place: StateFlow<Long> = _place.asStateFlow()
        private val _lastClientAt = MutableStateFlow(0L)
        val lastClientAt: StateFlow<Long> = _lastClientAt.asStateFlow()
        private val _activity = MutableStateFlow(ActivitySnapshot())
        val activity: StateFlow<ActivitySnapshot> = _activity.asStateFlow()
        private val _kilo = MutableStateFlow(dev.projectuai.relay.protocol.KiloCapability())
        val kilo = _kilo.asStateFlow()
        private val installLock = Any()
        private var installPending = false
        private var liveService: RelayService? = null

        /** Reserve installation before Android opens its confirmation screen. */
        fun beginUpdateInstall(context: Context, version: String): Boolean = synchronized(installLock) {
            val settings = (context.applicationContext as RelayApp).settings
            if (installPending || settings.updateInstallPending) return false
            val service = liveService
            if (service?.engine?.pauseForUpdate() == false) return false
            try {
                settings.lastInstallVersion = version
                settings.resumeAfterUpdate = service?.server != null && !settings.userStopped
                settings.updateInstallPending = true
            } catch (failure: RuntimeException) {
                // No Android commit can occur when reservation persistence fails.
                service?.engine?.resumeAfterUpdate()
                throw failure
            }
            installPending = true
            service?.updateNotification()
            true
        }

        fun endUpdateInstall(context: Context, preserveResume: Boolean = false) = synchronized(installLock) {
            val settings = (context.applicationContext as RelayApp).settings
            settings.updateInstallPending = false
            if (!preserveResume) settings.resumeAfterUpdate = false
            liveService?.engine?.resumeAfterUpdate()
            installPending = false
            liveService?.updateNotification()
        }

        fun start(context: Context, userInitiated: Boolean = false) {
            synchronized(installLock) {
                val settings = (context.applicationContext as RelayApp).settings
                if (installPending || settings.updateInstallPending) return
                if (userInitiated) settings.userStopped = false
                if (settings.userStopped) return
            }
            ContextCompat.startForegroundService(context, Intent(context, RelayService::class.java).setAction(ACTION_START))
        }

        fun kill(context: Context) {
            synchronized(installLock) {
                InstallationRecord.stopRequested((context.applicationContext as RelayApp).settings)
            }
            context.startService(Intent(context, RelayService::class.java).setAction(ACTION_KILL))
        }

        /** Apply a settings change while preserving a Stop issued before delivery. */
        fun restart(context: Context) {
            context.startService(Intent(context, RelayService::class.java).setAction(ACTION_RESTART))
        }

        fun scheduleWatchdog(context: Context, immediate: Boolean) {
            val alarm = context.getSystemService(AlarmManager::class.java) ?: return
            val pending = watchdogIntent(context)
            val at = System.currentTimeMillis() + if (immediate) 1_000L else WATCHDOG_INTERVAL_MS
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && !alarm.canScheduleExactAlarms()) {
                alarm.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, pending)
            } else {
                alarm.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, pending)
            }
        }

        fun cancelWatchdog(context: Context) {
            context.getSystemService(AlarmManager::class.java)?.cancel(watchdogIntent(context))
        }

        private fun watchdogIntent(context: Context): PendingIntent =
            PendingIntent.getBroadcast(context, WATCHDOG_REQUEST, Intent(context, WatchdogReceiver::class.java),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    }
}
