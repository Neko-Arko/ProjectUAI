package dev.projectuai.relay.engine

import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.ServiceConnection
import android.os.IBinder
import androidx.localbroadcastmanager.content.LocalBroadcastManager
import dev.projectuai.relay.protocol.KiloCapability
import okhttp3.ConnectionPool
import okhttp3.OkHttpClient
import okhttp3.Protocol
import org.torproject.jni.TorService
import java.io.IOException
import java.io.InterruptedIOException
import java.net.InetSocketAddress
import java.net.Proxy
import java.util.concurrent.TimeUnit

/** Owns a bound in-app Tor service; never changes Android's VPN or proxy settings. */
class AndroidKiloConnection(context: Context, private val direct: OkHttpClient) : KiloConnection {
    private val context = context.applicationContext
    private val broadcasts = LocalBroadcastManager.getInstance(this.context)
    @Volatile private var service: TorService? = null
    @Volatile private var state = "standby"
    @Volatile private var closed = false
    @Volatile override var generation = 0
        private set
    private var bound = false
    private var registered = false
    private var lastRotation = 0L
    private val rotationLock = Any()
    private var proxyClient: OkHttpClient? = null
    private val binding = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName, binder: IBinder) {
            if (!closed) service = (binder as TorService.LocalBinder).service
        }
        override fun onServiceDisconnected(name: ComponentName) { service = null; if (!closed) state = "failed" }
    }
    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (closed || intent.getStringExtra(TorService.EXTRA_SERVICE_PACKAGE_NAME) != context.packageName) return
            state = when (intent.getStringExtra(TorService.EXTRA_STATUS)) {
                TorService.STATUS_ON -> "ready"
                TorService.STATUS_STARTING -> "starting"
                else -> "failed"
            }
        }
    }
    @Synchronized private fun start() {
        if (closed || state != "standby") return
        state = "starting"
        try {
            broadcasts.registerReceiver(receiver, IntentFilter(TorService.ACTION_STATUS)); registered = true
            // The library uses a private Unix control socket. Public proxy listeners
            // are restricted to loopback and selected dynamically.
            // TorService discovers both listeners during setup, so its SOCKS
            // listener must remain enabled even though UAI uses HTTP CONNECT.
            TorService.getTorrc(this.context).writeText("SocksPort 127.0.0.1:auto\nHTTPTunnelPort 127.0.0.1:auto\nMaxCircuitDirtiness 3600\nAvoidDiskWrites 1\n")
            bound = this.context.bindService(Intent(this.context, TorService::class.java), binding, Context.BIND_AUTO_CREATE)
            if (!bound) state = "failed"
        } catch (error: IOException) { state = "failed" }
        catch (error: RuntimeException) { state = "failed" }
        catch (error: UnsatisfiedLinkError) { state = "failed" }
    }
    override fun capability() = KiloCapability(enabled = true, available = state == "ready" || state == "rotating", state = state,
        message = when (state) {
            "disabled" -> "Kilo tunnel is off."
            "standby" -> "Starts automatically after an anonymous Kilo quota response."
            "ready" -> "Kilo tunnel is ready. Each outbound address still has an hourly allowance."
            "rotating" -> "Trying another Kilo connection after a quota response."
            "failed" -> "Kilo tunnel could not connect. Stop and start the relay to try again."
            else -> "Connecting the Kilo tunnel."
        })
    override fun client(check: () -> Unit): OkHttpClient {
        start()
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(120)
        while (!closed && state != "failed") {
            check()
            val port = service?.httpTunnelPort ?: -1
            if (state == "ready" && port in 1..65535) return synchronized(this) {
                check()
                if (closed) throw IOException("Kilo tunnel stopped")
                proxyClient ?: direct.newBuilder().proxy(Proxy(Proxy.Type.HTTP, InetSocketAddress("127.0.0.1", port)))
                    .connectionPool(ConnectionPool(0, 1, TimeUnit.SECONDS)).protocols(listOf(Protocol.HTTP_1_1))
                    .build().also { proxyClient = it }
            }
            if (System.nanoTime() >= deadline) { state = "failed"; break }
            pause()
        }
        throw IOException("Kilo tunnel is unavailable")
    }
    override fun rotate(expected: Int, check: () -> Unit) = synchronized(rotationLock) {
        if (expected != generation) return@synchronized
        while (System.nanoTime() / 1_000_000L - lastRotation < 15000) { check(); if (closed) throw IOException("Kilo tunnel stopped"); pause() }
        check()
        if (closed) throw IOException("Kilo tunnel stopped")
        val control = service?.torControlConnection ?: throw IOException("Kilo tunnel control is unavailable")
        state = "rotating"
        try {
            control.signal("NEWNYM")
            generation++; lastRotation = System.nanoTime() / 1_000_000L
            synchronized(this) {
                proxyClient?.connectionPool?.evictAll(); proxyClient = null
                if (!closed) state = "ready"
            }
        } catch (error: IOException) { if (!closed) state = "failed"; throw error }
    }
    private fun pause() {
        try { Thread.sleep(100) } catch (error: InterruptedException) {
            Thread.currentThread().interrupt()
            throw InterruptedIOException("Kilo tunnel stopped")
        }
    }
    @Synchronized override fun close() {
        if (closed) return
        closed = true; state = "disabled"
        proxyClient?.connectionPool?.evictAll()
        if (registered) { broadcasts.unregisterReceiver(receiver); registered = false }
        if (bound) { context.unbindService(binding); bound = false }
        service = null
    }
}
