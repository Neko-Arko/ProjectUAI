package dev.projectuai.relay.ui

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.PowerManager
import android.provider.Settings
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Switch
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import dev.projectuai.relay.RelayLog
import dev.projectuai.relay.data.RelaySettings
import dev.projectuai.relay.service.RelayService
import dev.projectuai.relay.service.RelayState
import dev.projectuai.relay.protocol.ActivitySnapshot
import dev.projectuai.relay.protocol.JobActivity
import dev.projectuai.relay.protocol.JobState
import dev.projectuai.relay.update.UpdateCoordinator
import kotlinx.coroutines.delay

@Composable
fun RelayTheme(content: @Composable () -> Unit) {
    MaterialTheme(colorScheme = darkColorScheme(primary = Color(0xFFB5D595))) {
        Surface(Modifier.fillMaxSize(), content = content)
    }
}

@Composable
fun RelayScreen(settings: RelaySettings, log: RelayLog, updates: UpdateCoordinator, onInstall: () -> Unit, onAllowInstall: () -> Unit) {
    val context = LocalContext.current
    val state by RelayService.state.collectAsStateWithLifecycle()
    val token by RelayService.token.collectAsStateWithLifecycle()
    val place by RelayService.place.collectAsStateWithLifecycle()
    val lastClientAt by RelayService.lastClientAt.collectAsStateWithLifecycle()
    val activity by RelayService.activity.collectAsStateWithLifecycle()
    var now by remember { mutableStateOf(System.currentTimeMillis()) }
    LaunchedEffect(Unit) {
        while (true) { now = System.currentTimeMillis(); delay(1000) }
    }
    val running = state as? RelayState.Running

    Column(
        modifier = Modifier.fillMaxSize().windowInsetsPadding(WindowInsets.safeDrawing)
            .verticalScroll(rememberScrollState()).padding(20.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Text("UAI Relay", style = MaterialTheme.typography.headlineSmall)
        Text(
            "Keeps a local relay alive on this phone so long model replies survive the executor's HTTP limit. " +
                "The Project UAI script finds it automatically; no token copying.",
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )

        StatusCard(running, token, place, settings, lastClientAt, now)

        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Button(onClick = { RelayService.start(context, userInitiated = true) }, enabled = running == null) { Text("Start") }
            OutlinedButton(onClick = { RelayService.kill(context) }, enabled = running != null) { Text("Stop") }
        }

        ActivityCard(activity, now)
        UpdateCard(updates, onInstall, onAllowInstall)
        SettingsCard(settings, context, running != null)
        DiagnosticsCard(log)
    }
}

@Composable
private fun StatusCard(running: RelayState.Running?, token: String, place: Long, settings: RelaySettings, lastClientAt: Long, now: Long) {
    val clipboard = LocalClipboardManager.current
    Card(Modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(if (running != null) "Running" else "Stopped", style = MaterialTheme.typography.titleMedium)
            Fact("Port", "127.0.0.1:${running?.port ?: settings.port}")
            val contactAge = if (lastClientAt > 0) (now - lastClientAt).coerceAtLeast(0) / 1000 else -1
            Fact("Roblox", when {
                running == null -> "Start the relay first"
                contactAge < 0 -> "Waiting for the script"
                contactAge <= 45 -> "Connected"
                else -> "Last seen ${contactAge}s ago"
            })
            if (running != null && contactAge < 0) {
                Text("Run Project UAI in Roblox, then open Cowork and tap Scan now if this stays waiting.",
                    style = MaterialTheme.typography.bodySmall)
            }
            Fact("Pairing", if (token.isEmpty()) "Not paired" else "Saved on this phone")
            if (token.isNotEmpty()) {
                Fact("Token", mask(token))
                TextButton(onClick = { clipboard.setText(AnnotatedString(token)) }) { Text("Copy token") }
            }
            if (place > 0) Fact("Place", place.toString())
        }
    }
}

@Composable
private fun ActivityCard(activity: ActivitySnapshot, now: Long) {
    Card(Modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text("Requests", style = MaterialTheme.typography.titleMedium)
            Fact("Active", activity.activeJobs.toString())
            Fact("Accepted", activity.acceptedJobs.toString())
            Fact("Responses received", activity.completedJobs.toString())
            Fact("Failed / cancelled", "${activity.failedJobs} / ${activity.cancelledJobs}")
            if (activity.acceptedJobs == 0) {
                Text("No inference has reached this app yet. Send a message in Project UAI after Roblox connects.",
                    style = MaterialTheme.typography.bodySmall)
            }
            activity.recent.take(4).forEach { job ->
                HorizontalDivider()
                Text(job.provider, style = MaterialTheme.typography.titleSmall)
                Text(jobSummary(job), style = MaterialTheme.typography.bodyMedium)
                val elapsed = ((if (job.finishedAt > 0) job.finishedAt else now) - job.startedAt).coerceAtLeast(0) / 1000
                Text("${elapsed}s · ${job.receivedBytes / 1024} KiB received", style = MaterialTheme.typography.bodySmall)
            }
        }
    }
}

private fun jobSummary(job: JobActivity): String = when (job.state) {
    JobState.RUNNING -> if (job.receivedBytes > 0) "Receiving the provider response" else "Waiting for the provider"
    JobState.COMPLETED -> if (job.status in 200..299) "Response received" else "Provider returned HTTP ${job.status}; see Roblox for details"
    JobState.CANCELLED -> if (job.errorCode == "client_disconnected") "Roblox stopped polling; provider request cancelled" else "Cancelled"
    else -> when (job.errorCode) {
        "dns" -> "Provider address could not be found"
        "connection" -> "Could not connect to the provider"
        "tls" -> "Secure connection failed"
        "timeout" -> "Connection or explicit request deadline expired"
        "response_limit" -> "Provider response exceeded the size limit"
        else -> "Provider connection failed; the request was not repeated"
    }
}

@Composable
private fun SettingsCard(settings: RelaySettings, context: Context, running: Boolean) {
    var portText by remember { mutableStateOf(settings.port.toString()) }
    var autoStart by remember { mutableStateOf(settings.autoStart) }
    var exempt by remember { mutableStateOf(isIgnoringBattery(context)) }

    Card(Modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Text("Settings", style = MaterialTheme.typography.titleMedium)

            OutlinedTextField(
                value = portText,
                onValueChange = { portText = it.filter(Char::isDigit) },
                label = { Text("Port") },
                singleLine = true,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
            )
            TextButton(onClick = {
                val value = portText.toIntOrNull()?.takeIf { it in 1..65535 } ?: return@TextButton
                if (value != settings.port) {
                    settings.port = value
                    if (running) RelayService.restart(context)
                }
            }) { Text("Apply port") }

            HorizontalDivider()

            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically) {
                Text("Start on boot")
                Switch(checked = autoStart, onCheckedChange = { autoStart = it; settings.autoStart = it })
            }

            TextButton(onClick = {
                settings.rotateToken()
                if (running) RelayService.restart(context)
            }) { Text("Rotate token") }

            HorizontalDivider()

            Fact("Battery exemption", if (exempt) "Granted" else "Not granted")
            TextButton(onClick = {
                runCatching {
                    context.startActivity(
                        Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, Uri.parse("package:${context.packageName}")),
                    )
                }
                exempt = isIgnoringBattery(context)
            }) { Text("Request battery exemption") }

            TextButton(onClick = {
                runCatching {
                    context.startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:${context.packageName}")))
                }
            }) { Text("Open app settings (OEM autostart)") }

            Text(
                "On Xiaomi, Samsung, Oppo and vivo phones, also allow auto-start in the vendor settings, " +
                    "or the system may stop the relay while Roblox is in front.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

@Composable
private fun DiagnosticsCard(log: RelayLog) {
    val lines by log.lines.collectAsStateWithLifecycle()
    Card(Modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically) {
                Text("Diagnostics", style = MaterialTheme.typography.titleMedium)
            }
            if (lines.isEmpty()) {
                Text("No events yet.", style = MaterialTheme.typography.bodySmall)
            } else {
                lines.forEach {
                    Text(it, fontFamily = FontFamily.Monospace, style = MaterialTheme.typography.bodySmall)
                }
            }
        }
    }
}

@Composable
private fun Fact(label: String, value: String) {
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
        Text(label, color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.bodyMedium)
        Text(value, style = MaterialTheme.typography.bodyMedium)
    }
}

private fun mask(token: String): String =
    if (token.length <= 10) token else token.take(6) + "…" + token.takeLast(4)

private fun isIgnoringBattery(context: Context): Boolean =
    context.getSystemService(PowerManager::class.java)?.isIgnoringBatteryOptimizations(context.packageName) == true
