package dev.projectuai.relay

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import dev.projectuai.relay.ui.RelayScreen
import dev.projectuai.relay.ui.RelayTheme

class MainActivity : ComponentActivity() {
    private val installer = registerForActivityResult(ActivityResultContracts.StartActivityForResult()) {
        (application as RelayApp).updates.installerReturned()
    }
    private val installationPermission = registerForActivityResult(ActivityResultContracts.StartActivityForResult()) {
        (application as RelayApp).updates.permissionReturned()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1)
        }
        val app = application as RelayApp
        setContent {
            RelayTheme {
                RelayScreen(app.settings, app.log, app.updates,
                    onInstall = { app.updates.requestInstall(this, installer::launch) },
                    onAllowInstall = { app.updates.allowInstallation(this, installationPermission::launch) })
            }
        }
    }

    override fun onResume() {
        super.onResume()
        (application as RelayApp).updates.refreshInstallPermission()
    }
}
