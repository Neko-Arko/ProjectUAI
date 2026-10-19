package dev.projectuai.relay.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.material3.Button
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
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
    var expanded by rememberSaveable { mutableStateOf(false) }
    val checking = state.phase == "checking" || state.phase == "downloading"
    val installing = install.phase == "preparing" || install.phase == "confirming" || install.phase == "replacing"
    val pending = install.phase == "confirming" || install.phase == "confirmation_ready" || install.phase == "interrupted"
    RelayCard {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                SectionTitle("App updates")
                Text("Installed v${updates.currentVersion}", style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            TextButton(onClick = { expanded = !expanded }, modifier = Modifier.semantics {
                contentDescription = if (expanded) "Hide update options" else "Show update options"
                stateDescription = if (expanded) "Expanded" else "Collapsed"
            }) { Text(if (expanded) "Less" else "Options") }
        }
        state.version?.let { version ->
            Text(if (state.phase == "ready") "Version $version is ready to install" else "Version $version",
                style = MaterialTheme.typography.titleSmall, color = MaterialTheme.colorScheme.primary)
        }
        Text(state.detail, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        if (state.phase == "downloading") {
            if (state.totalBytes > 0) {
                LinearProgressIndicator(progress = { (state.downloadedBytes.toFloat() / state.totalBytes).coerceIn(0f, 1f) }, modifier = Modifier.fillMaxWidth())
                Text("${state.downloadedBytes / 1024} / ${state.totalBytes / 1024} KB downloaded", style = MaterialTheme.typography.bodySmall)
            } else LinearProgressIndicator(Modifier.fillMaxWidth())
        }
        if (install.detail.isNotBlank()) Text(install.detail, style = MaterialTheme.typography.bodyMedium)
        if (state.phase == "ready" && !pending && !installing) {
            Button(onClick = if (installAllowed) onInstall else onAllowInstall,
                modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp)) {
                Text(if (installAllowed) "Install update" else "Allow app updates")
            }
            Text("Finish your current replies first. Android will ask you to confirm installation.",
                style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        if (install.phase == "confirmation_ready") Button(onClick = onInstall, modifier = Modifier.fillMaxWidth()) { Text("Continue installation") }
        if (pending) OutlinedButton(onClick = updates::resumeRelay, modifier = Modifier.fillMaxWidth()) { Text("Resume relay") }
        if (state.phase == "available") {
            OutlinedButton(onClick = updates::checkNow, enabled = !checking && !installing && !pending,
                modifier = Modifier.fillMaxWidth()) { Text("Download update") }
        }
        if (expanded) {
            HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
            ToggleSetting("Download updates automatically", "Checks every 15 minutes while the app is running. Installation always needs your confirmation.",
                automatic, updates::automaticDownloads)
            if (lastChecked > 0) Text("Last checked ${DateFormat.getDateTimeInstance(DateFormat.SHORT, DateFormat.SHORT).format(Date(lastChecked))}",
                style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            OutlinedButton(onClick = updates::checkNow, enabled = !checking && !installing && !pending,
                modifier = Modifier.fillMaxWidth()) { Text("Check for updates") }
        }
    }
}
