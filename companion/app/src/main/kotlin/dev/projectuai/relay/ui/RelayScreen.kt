package dev.projectuai.relay.ui

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.PowerManager
import android.provider.Settings
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import dev.projectuai.relay.RelayLog
import dev.projectuai.relay.data.RelaySettings
import dev.projectuai.relay.protocol.ActivitySnapshot
import dev.projectuai.relay.protocol.JobActivity
import dev.projectuai.relay.protocol.JobState
import dev.projectuai.relay.service.RelayService
import dev.projectuai.relay.service.RelayState
import dev.projectuai.relay.update.UpdateCoordinator
import kotlinx.coroutines.delay

@Composable
fun RelayTheme(content: @Composable () -> Unit) {
    MaterialTheme(colorScheme = darkColorScheme(
        primary = Color(0xFFC5E2B7), onPrimary = Color(0xFF20331D),
        primaryContainer = Color(0xFF2D4230), onPrimaryContainer = Color(0xFFD9EBD1),
        background = Color(0xFF101411), onBackground = Color(0xFFF0F2E9),
        surface = Color(0xFF181F1A), onSurface = Color(0xFFF0F2E9),
        surfaceVariant = Color(0xFF27312A), onSurfaceVariant = Color(0xFFAEBBAD),
        outline = Color(0xFF647261), outlineVariant = Color(0xFF344137),
        error = Color(0xFFFFB4AB),
    )) {
        Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background, content = content)
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
    val install by updates.install.collectAsStateWithLifecycle()
    var now by remember { mutableStateOf(System.currentTimeMillis()) }
    LaunchedEffect(Unit) {
        while (true) { now = System.currentTimeMillis(); delay(1000) }
    }
    val running = state as? RelayState.Running
    val updatePending = settings.updateInstallPending || installationPausesRelay(install.phase)
    val presentation = relayPresentation(running != null, lastClientAt, now, updatePending)

    Column(
        modifier = Modifier.fillMaxSize().windowInsetsPadding(WindowInsets.safeDrawing)
            .verticalScroll(rememberScrollState()).padding(horizontal = 20.dp, vertical = 24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Column(Modifier.widthIn(max = 600.dp).fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(18.dp)) {
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                    Text("PROJECT UAI", color = MaterialTheme.colorScheme.primary,
                        style = MaterialTheme.typography.labelSmall, letterSpacing = 2.sp)
                    Text("Relay", style = MaterialTheme.typography.headlineMedium, fontWeight = FontWeight.SemiBold)
                }
                Surface(shape = CircleShape, color = MaterialTheme.colorScheme.surfaceVariant) {
                    Text("v${updates.currentVersion}", Modifier.padding(horizontal = 12.dp, vertical = 7.dp),
                        style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }

            ConnectionCard(presentation, running != null, updatePending,
                onToggle = {
                    if (running != null) RelayService.kill(context)
                    else RelayService.start(context, userInitiated = true)
                })

            if (!presentation.connected && !updatePending) GettingStartedCard(running != null)
            ActivityCard(activity, now)
            BatteryCard(context)
            UpdateCard(updates, onInstall, onAllowInstall)
            SettingsCard(settings, token, place, context, running != null, activity.activeJobs > 0, updatePending)
            DiagnosticsCard(log)

            Text("Made for Project UAI on your phone.", Modifier.align(Alignment.CenterHorizontally).padding(vertical = 8.dp),
                style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

@Composable
private fun ConnectionCard(presentation: RelayPresentation, running: Boolean, updatePending: Boolean, onToggle: () -> Unit) {
    val shape = RoundedCornerShape(28.dp)
    Column(
        Modifier.fillMaxWidth().background(Brush.verticalGradient(listOf(Color(0xFF263A2C), Color(0xFF1B281F))), shape)
            .border(1.dp, Color(0xFF41563F), shape).padding(24.dp),
        verticalArrangement = Arrangement.spacedBy(20.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Box(Modifier.size(7.dp).background(
                if (running && !updatePending) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant, CircleShape))
            Text("YOUR PHONE COMPANION", style = MaterialTheme.typography.labelSmall,
                letterSpacing = 1.4.sp, color = MaterialTheme.colorScheme.primary)
        }
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Text(presentation.title, Modifier.semantics { heading() }, fontSize = 32.sp, lineHeight = 37.sp,
                fontWeight = FontWeight.SemiBold, letterSpacing = (-0.8).sp)
            Text(presentation.detail, style = MaterialTheme.typography.bodyMedium,
                color = Color(0xFFC0CFBC), lineHeight = 22.sp)
        }
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Fact("Relay on this phone", presentation.relayLabel)
            Fact("Roblox", presentation.robloxLabel)
        }
        Button(
            onClick = onToggle, enabled = running || !updatePending,
            modifier = Modifier.fillMaxWidth().heightIn(min = 54.dp), shape = RoundedCornerShape(16.dp),
            colors = if (running) ButtonDefaults.buttonColors(containerColor = Color(0xFF3A4C38), contentColor = Color(0xFFECF4E6))
                else ButtonDefaults.buttonColors(),
        ) { Text(if (running) "Stop relay" else "Start relay", style = MaterialTheme.typography.titleSmall) }
        if (running) Text("Stopping ends active replies and keeps the relay off until you start it again.",
            style = MaterialTheme.typography.bodySmall, color = Color(0xFFAEBEAA))
    }
}

@Composable
private fun GettingStartedCard(running: Boolean) {
    RelayCard {
        SectionTitle("Three steps. Then you're ready.")
        SetupStep("1", "Start the relay", if (running) "Done. Leave it running on this phone." else "Tap Start relay above.", running)
        SetupStep("2", "Open Project UAI in Roblox", "Run the script. Connection is automatic.")
        SetupStep("3", "Send a message", "Use your chat in Roblox. Replies come back there.")
        Text("Still waiting? In Project UAI, open Cowork, set Relay to Auto, then tap Scan now.",
            style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@Composable
private fun SetupStep(number: String, title: String, detail: String, done: Boolean = false) {
    Row(horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.Top) {
        Surface(shape = CircleShape, color = if (done) MaterialTheme.colorScheme.primaryContainer else MaterialTheme.colorScheme.surfaceVariant) {
            Box(Modifier.size(30.dp), contentAlignment = Alignment.Center) {
                Text(number, style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.primary)
            }
        }
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Text(title, style = MaterialTheme.typography.titleSmall)
            Text(detail, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

@Composable
private fun ActivityCard(activity: ActivitySnapshot, now: Long) {
    var expanded by rememberSaveable { mutableStateOf(false) }
    val largeText = LocalDensity.current.fontScale >= 1.2f
    RelayCard {
        SectionTitle("Your messages")
        if (largeText) {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Fact("In progress", activity.activeJobs.toString())
                Fact("Responses", activity.completedJobs.toString())
                Fact("Failed", activity.failedJobs.toString())
            }
        } else {
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                ActivityTotal(activity.activeJobs, "In progress", Modifier.weight(1f))
                ActivityTotal(activity.completedJobs, "Responses", Modifier.weight(1f))
                ActivityTotal(activity.failedJobs, "Failed", Modifier.weight(1f))
            }
        }
        val latest = activity.recent.firstOrNull()
        if (activity.activeJobs > 0) {
            Text("Working on your reply. You can return to Roblox.", style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.primary)
        } else if (latest != null) {
            Text(jobSummary(latest), style = MaterialTheme.typography.bodyMedium)
        } else {
            Text("No messages received by the relay yet.", style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        if (activity.acceptedJobs > 0) {
            TextButton(onClick = { expanded = !expanded }) { Text(if (expanded) "Hide recent messages" else "Show recent messages") }
            if (expanded) {
                Text("${activity.acceptedJobs} accepted, ${activity.cancelledJobs} cancelled in this relay session.",
                    style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                activity.recent.take(4).forEach { job ->
                    HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
                    Column(verticalArrangement = Arrangement.spacedBy(5.dp)) {
                        Text(job.provider, style = MaterialTheme.typography.titleSmall)
                        Text(jobSummary(job), style = MaterialTheme.typography.bodyMedium)
                        val elapsed = ((if (job.finishedAt > 0) job.finishedAt else now) - job.startedAt).coerceAtLeast(0) / 1000
                        Text("${elapsed}s / ${job.receivedBytes / 1024} KB received", style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
            }
        }
    }
}

@Composable
private fun ActivityTotal(value: Int, label: String, modifier: Modifier) {
    Column(modifier, verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Text(value.toString(), style = MaterialTheme.typography.headlineMedium, fontWeight = FontWeight.Medium)
        Text(label, style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

private fun jobSummary(job: JobActivity): String = when (job.state) {
    JobState.RUNNING -> if (job.receivedBytes > 0) "Receiving your provider's response" else "Waiting for your provider to reply"
    JobState.COMPLETED -> if (job.status in 200..299) "Response received. Check your chat in Roblox."
        else "Your provider returned an error (${job.status}). Check your chat in Roblox."
    JobState.CANCELLED -> if (job.errorCode == "client_disconnected") "Roblox disconnected. Its request was cancelled." else "Request cancelled."
    else -> when (job.errorCode) {
        "dns" -> "Your provider's address could not be found."
        "connection" -> "Could not connect to your provider."
        "tls" -> "A secure connection to your provider could not be made."
        "timeout" -> "Your provider connection or request timed out."
        "response_limit" -> "Your provider's response was too large."
        else -> "The provider connection failed. Your message was not sent again."
    }
}

@Composable
private fun BatteryCard(context: Context) {
    val lifecycleOwner = LocalLifecycleOwner.current
    var exempt by remember { mutableStateOf(isIgnoringBattery(context)) }
    var expanded by rememberSaveable { mutableStateOf(false) }
    DisposableEffect(lifecycleOwner, context) {
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_RESUME) exempt = isIgnoringBattery(context)
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose { lifecycleOwner.lifecycle.removeObserver(observer) }
    }
    ExpandableCard("Keep replies running", if (exempt) "Battery access allowed" else "Allow background battery use", expanded, { expanded = !expanded }) {
        Text("Allow this app to run in the background so Android is less likely to stop a long reply while Roblox is open.",
            style = MaterialTheme.typography.bodyMedium)
        if (!exempt) OutlinedButton(onClick = {
            runCatching { context.startActivity(Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, Uri.parse("package:${context.packageName}"))) }
        }, modifier = Modifier.fillMaxWidth()) { Text("Allow background use") }
        Text("Some phones also need Auto-start or Unrestricted battery enabled in Android app settings.",
            style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        TextButton(onClick = {
            runCatching { context.startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:${context.packageName}"))) }
        }) { Text("Open Android app settings") }
    }
}

@Composable
private fun DiagnosticsCard(log: RelayLog) {
    val lines by log.lines.collectAsStateWithLifecycle()
    val clipboard = LocalClipboardManager.current
    var expanded by rememberSaveable { mutableStateOf(false) }
    ExpandableCard("Diagnostics", "Recent events for troubleshooting", expanded, { expanded = !expanded }) {
        Text("These events contain no message contents or provider keys.", style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant)
        if (lines.isEmpty()) Text("No events yet.", style = MaterialTheme.typography.bodySmall)
        else {
            TextButton(onClick = { clipboard.setText(AnnotatedString(lines.joinToString("\n"))) }) { Text("Copy diagnostics") }
            lines.asReversed().forEach { Text(it, fontFamily = FontFamily.Monospace, style = MaterialTheme.typography.bodySmall) }
        }
    }
}

@Composable
internal fun RelayCard(content: @Composable ColumnScope.() -> Unit) {
    Card(Modifier.fillMaxWidth(), shape = RoundedCornerShape(22.dp),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface)) {
        Column(Modifier.padding(20.dp), verticalArrangement = Arrangement.spacedBy(16.dp), content = content)
    }
}

@Composable
internal fun SectionTitle(text: String) {
    Text(text, Modifier.semantics { heading() }, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
}

@Composable
internal fun ExpandableCard(title: String, summary: String, expanded: Boolean, onToggle: () -> Unit, content: @Composable ColumnScope.() -> Unit) {
    RelayCard {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                SectionTitle(title)
                Text(summary, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            TextButton(onClick = onToggle, modifier = Modifier.semantics {
                contentDescription = "${if (expanded) "Hide" else "Open"} $title"
                stateDescription = if (expanded) "Expanded" else "Collapsed"
            }) { Text(if (expanded) "Hide" else "Open") }
        }
        if (expanded) {
            HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
            content()
        }
    }
}

@Composable
internal fun Fact(label: String, value: String) {
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        Text(label, Modifier.weight(1f), color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.bodyMedium)
        Text(value, Modifier.weight(1f), style = MaterialTheme.typography.bodyMedium)
    }
}

private fun isIgnoringBattery(context: Context): Boolean =
    context.getSystemService(PowerManager::class.java)?.isIgnoringBatteryOptimizations(context.packageName) == true
