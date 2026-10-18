package dev.projectuai.relay.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import dev.projectuai.relay.update.UpdateCoordinator
import java.text.DateFormat
import java.util.Date

@Composable
fun UpdateCard(updates: UpdateCoordinator, onInstall: () -> Unit, onAllowInstall: () -> Unit) {
    val state by updates.state.collectAsStateWithLifecycle()
    val automatic by updates.automatic.collectAsStateWithLifecycle()
    val lastChecked by updates.lastChecked.collectAsStateWithLifecycle()
    val install by updates.install.collectAsStateWithLifecycle()
    val installAllowed by updates.installAllowed.collectAsStateWithLifecycle()
    val checking = state.phase == "checking" || state.phase == "downloading"
    val installing = install.phase == "preparing" || install.phase == "confirming" || install.phase == "replacing"
    val pending = install.phase == "confirming" || install.phase == "confirmation_ready" || install.phase == "interrupted"
    Card(Modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Text("App updates", style = MaterialTheme.typography.titleMedium)
            Text("Installed ${updates.currentVersion}", style = MaterialTheme.typography.bodyMedium)
            state.version?.let { Text("Available $it", style = MaterialTheme.typography.bodyMedium) }
            Text(state.detail, style = MaterialTheme.typography.bodySmall)
            if (state.phase == "downloading") {
                if (state.totalBytes > 0) {
                    LinearProgressIndicator(progress = { (state.downloadedBytes.toFloat() / state.totalBytes).coerceIn(0f, 1f) }, modifier = Modifier.fillMaxWidth())
                    Text("${state.downloadedBytes / 1024} / ${state.totalBytes / 1024} KiB", style = MaterialTheme.typography.bodySmall)
                } else LinearProgressIndicator(Modifier.fillMaxWidth())
            }
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
                Text("Download updates automatically", Modifier.weight(1f), style = MaterialTheme.typography.bodyMedium)
                Switch(checked = automatic, onCheckedChange = updates::automaticDownloads)
            }
            Text("Checks run at startup and every 15 minutes while the app or relay is running. Android asks you to confirm installation.",
                style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            if (lastChecked > 0) Text("Last checked ${DateFormat.getDateTimeInstance(DateFormat.SHORT, DateFormat.SHORT).format(Date(lastChecked))}",
                style = MaterialTheme.typography.bodySmall)
            OutlinedButton(onClick = updates::checkNow, enabled = !checking && !installing) {
                Text(if (state.phase == "available") "Download update" else "Check now")
            }
            if (state.phase == "ready") {
                if (!installAllowed) {
                    Button(onClick = onAllowInstall, enabled = !installing && !pending) { Text("Allow app updates") }
                } else {
                    Button(onClick = onInstall, enabled = !installing && !pending) { Text("Install update") }
                }
                Text("Install waits for active requests and retained replies. Cancelling Android's installer keeps the current app and downloaded update.",
                    style = MaterialTheme.typography.bodySmall)
            }
            if (install.phase == "confirmation_ready") Button(onClick = onInstall) { Text("Continue installation") }
            if (pending) OutlinedButton(onClick = updates::resumeRelay) { Text("Resume relay") }
            if (install.detail.isNotBlank()) Text(install.detail, style = MaterialTheme.typography.bodySmall)
        }
    }
}
