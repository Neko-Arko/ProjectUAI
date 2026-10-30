package dev.projectuai.relay.ui

import android.content.Context
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import dev.projectuai.relay.data.RelaySettings
import dev.projectuai.relay.service.RelayService

@Composable
internal fun SettingsCard(settings: RelaySettings, serviceToken: String, place: Long, context: Context,
    running: Boolean, busy: Boolean, updatePending: Boolean, kilo: dev.projectuai.relay.protocol.KiloCapability) {
    var expanded by rememberSaveable { mutableStateOf(false) }
    var portText by rememberSaveable { mutableStateOf(settings.port.toString()) }
    var appliedPort by remember { mutableStateOf(settings.port) }
    var autoStart by remember { mutableStateOf(settings.autoStart) }
    var kiloEnabled by remember { mutableStateOf(settings.kiloEnabled) }
    var pairingToken by remember(serviceToken) { mutableStateOf(settings.token) }
    var confirmReset by rememberSaveable { mutableStateOf(false) }
    val clipboard = LocalClipboardManager.current
    val newPort = portText.toIntOrNull()?.takeIf { it in 1..65535 }

    ExpandableCard("Connection settings", "Optional. The defaults work for most phones.", expanded, { expanded = !expanded }) {
        ToggleSetting("Start after phone restarts", "A manual Stop keeps the relay off until you start it again.", autoStart) {
            autoStart = it
            settings.autoStart = it
        }
        HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
        ToggleSetting("Kilo tunnel", "Automatically tries another connection after an anonymous Kilo quota response. Each outbound address still has an allowance. Stop the relay to change this setting.", kiloEnabled,
            enabled = !running && !busy && !updatePending) {
            kiloEnabled = it
            settings.kiloEnabled = it
        }
        if (running) Text(kilo.message, style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant)
        HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
        SectionTitle("Local connection")
        Text("Port $appliedPort on this phone. Use the same port in Project UAI.",
            style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        OutlinedTextField(
            value = portText, onValueChange = { portText = it.filter(Char::isDigit).take(5) },
            label = { Text("Port") }, modifier = Modifier.fillMaxWidth(), singleLine = true,
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
            isError = newPort == null,
            supportingText = {
                Text(if (newPort == null) "Enter a number from 1 to 65535."
                    else if (busy) "Finish active replies before changing the connection."
                    else if (updatePending) "Finish or cancel the update before changing the connection."
                    else if (running) "Applying a new port restarts the relay." else "Default: 8790")
            },
        )
        OutlinedButton(onClick = {
            val value = newPort ?: return@OutlinedButton
            settings.port = value
            appliedPort = value
            if (running) RelayService.restart(context)
        }, enabled = newPort != null && newPort != appliedPort && !busy && !updatePending,
            modifier = Modifier.fillMaxWidth()) { Text("Apply port") }

        HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
        SectionTitle("Saved pairing")
        Text(if (pairingToken.isEmpty()) "Roblox will pair automatically when it connects."
            else "Your connection is saved. You do not need to copy a token for normal setup.",
            style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        if (pairingToken.isNotEmpty()) {
            Fact("Private token", "Ends in ${pairingToken.takeLast(4)}")
            TextButton(onClick = { clipboard.setText(AnnotatedString(pairingToken)) }) { Text("Copy private token") }
            TextButton(onClick = { confirmReset = true }, enabled = !busy && !updatePending) { Text("Reset pairing") }
            if (busy) Text("Finish active replies before resetting pairing.", style = MaterialTheme.typography.bodySmall)
        }
        if (place > 0) Fact("Last Roblox place", place.toString())
    }

    if (confirmReset) AlertDialog(
        onDismissRequest = { confirmReset = false },
        title = { Text("Reset saved pairing?") },
        text = { Text("This removes the saved connection. Roblox will need to pair again automatically. " +
            if (running) "The relay will restart." else "Start the relay when you are ready to reconnect.") },
        confirmButton = {
            TextButton(onClick = {
                settings.rotateToken()
                pairingToken = ""
                confirmReset = false
                if (running) RelayService.restart(context)
            }, enabled = !busy && !updatePending) { Text("Reset pairing") }
        },
        dismissButton = { TextButton(onClick = { confirmReset = false }) { Text("Keep pairing") } },
    )
}

@Composable
internal fun ToggleSetting(title: String, detail: String, checked: Boolean, enabled: Boolean = true, onChange: (Boolean) -> Unit) {
    Row(Modifier.fillMaxWidth().heightIn(min = 48.dp).toggleable(value = checked, enabled = enabled, role = Role.Switch, onValueChange = onChange),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        Column(Modifier.weight(1f).padding(vertical = 4.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(title, style = MaterialTheme.typography.bodyMedium)
            Text(detail, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        Switch(checked = checked, enabled = enabled, onCheckedChange = null)
    }
}
