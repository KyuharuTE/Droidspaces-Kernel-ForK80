package com.droidspaces.kpmanager.ui

import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Tune
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.AssistChip
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.viewmodel.compose.viewModel
import com.droidspaces.kpmanager.kpm.Kpm

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MainScreen(vm: MainViewModel = viewModel()) {
    val state by vm.state.collectAsState()
    val snackbar = remember { SnackbarHostState() }

    var showSettings by rememberSaveable { mutableStateOf(false) }
    var unloadTarget by remember { mutableStateOf<Kpm?>(null) }
    var controlTarget by remember { mutableStateOf<Kpm?>(null) }

    // One-shot messages. Cleared after showing so a rotation does not repeat it.
    LaunchedEffect(state.message) {
        state.message?.let { text ->
            snackbar.showSnackbar(text)
            vm.dismissMessage()
        }
    }

    val picker = rememberLauncherForActivityResult(
        ActivityResultContracts.OpenDocument(),
    ) { uri: Uri? ->
        if (uri != null) vm.load(uri)
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("KPM Manager") },
                actions = {
                    IconButton(
                        onClick = { vm.refresh() },
                        enabled = state.connected && !state.busy,
                    ) {
                        Icon(Icons.Default.Refresh, contentDescription = "Refresh")
                    }
                    IconButton(onClick = { showSettings = true }) {
                        Icon(Icons.Default.Settings, contentDescription = "Settings")
                    }
                },
            )
        },
        snackbarHost = { SnackbarHost(snackbar) },
        floatingActionButton = {
            if (state.connected) {
                Button(
                    onClick = { picker.launch(arrayOf("*/*")) },
                    enabled = !state.busy,
                ) {
                    Icon(Icons.Default.Add, contentDescription = null)
                    Spacer(Modifier.size(8.dp))
                    Text("Load .kpm")
                }
            }
        },
    ) { padding ->
        Column(
            Modifier
                .fillMaxSize()
                .padding(padding)
                .padding(horizontal = 16.dp),
        ) {
            StatusStrip(state, onRetry = { vm.connect() })

            if (!state.connected) {
                ConnectionCard(
                    state = state,
                    onKeyChange = vm::onSuperKeyChange,
                    onConnect = vm::saveSuperKey,
                )
            } else {
                Spacer(Modifier.height(12.dp))
                if (state.modules.isEmpty() && !state.busy) {
                    EmptyState()
                } else {
                    LazyColumn(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        items(state.modules, key = { it.name }) { module ->
                            ModuleCard(
                                module = module,
                                enabled = !state.busy,
                                onUnload = { unloadTarget = module },
                                onControl = { controlTarget = module },
                            )
                        }
                        item { Spacer(Modifier.height(88.dp)) }
                    }
                }
            }
        }
    }

    if (showSettings) {
        SettingsDialog(
            state = state,
            onKeyChange = vm::onSuperKeyChange,
            onSave = {
                vm.saveSuperKey()
                showSettings = false
            },
            onDismiss = { showSettings = false },
        )
    }

    unloadTarget?.let { target ->
        AlertDialog(
            onDismissRequest = { unloadTarget = null },
            title = { Text("Unload ${target.name}?") },
            text = { Text("The module's exit callback runs and its hooks are removed.") },
            confirmButton = {
                TextButton(onClick = {
                    vm.unload(target.name)
                    unloadTarget = null
                }) { Text("Unload") }
            },
            dismissButton = {
                TextButton(onClick = { unloadTarget = null }) { Text("Cancel") }
            },
        )
    }

    controlTarget?.let { target ->
        ControlDialog(
            module = target,
            onSend = { args ->
                vm.control(target.name, args)
                controlTarget = null
            },
            onDismiss = { controlTarget = null },
        )
    }
}

@Composable
private fun StatusStrip(state: UiState, onRetry: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().padding(vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        when {
            state.connecting -> {
                CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp)
                Text("Connecting...", style = MaterialTheme.typography.bodyMedium)
            }
            state.connected -> AssistChip(
                onClick = onRetry,
                label = { Text("KernelPatch connected · ${state.modules.size} module(s)") },
            )
            else -> AssistChip(
                onClick = onRetry,
                label = { Text("Not connected") },
            )
        }
        if (state.busy) {
            CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp)
        }
    }
}

@Composable
private fun ConnectionCard(
    state: UiState,
    onKeyChange: (String) -> Unit,
    onConnect: () -> Unit,
) {
    Card(Modifier.fillMaxWidth().padding(top = 8.dp)) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text("Superkey", style = MaterialTheme.typography.titleMedium)
            Text(
                "The key the kernel image was patched with. It is stored on this " +
                    "device and sent to the kernel on every call.",
                style = MaterialTheme.typography.bodySmall,
            )
            OutlinedTextField(
                value = state.superKey,
                onValueChange = onKeyChange,
                singleLine = true,
                label = { Text("Superkey") },
                modifier = Modifier.fillMaxWidth(),
            )
            Button(onClick = onConnect, enabled = !state.connecting) {
                Text("Connect")
            }
        }
    }
}

@Composable
private fun EmptyState() {
    Column(
        Modifier.fillMaxSize().padding(top = 64.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text("No KPMs loaded", style = MaterialTheme.typography.titleMedium)
        Spacer(Modifier.height(8.dp))
        Text(
            "Load a .kpm built for this kernel's kallsyms.",
            style = MaterialTheme.typography.bodySmall,
        )
    }
}

@Composable
private fun ModuleCard(
    module: Kpm,
    enabled: Boolean,
    onUnload: () -> Unit,
    onControl: () -> Unit,
) {
    Card(
        Modifier.fillMaxWidth(),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceVariant),
    ) {
        Column(Modifier.padding(12.dp)) {
            Row(
                Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Column(Modifier.weight(1f)) {
                    Text(module.name, style = MaterialTheme.typography.titleSmall)
                    val sub = listOfNotNull(module.version, module.author).joinToString(" · ")
                    if (sub.isNotEmpty()) {
                        Text(
                            sub,
                            style = MaterialTheme.typography.bodySmall,
                            fontFamily = FontFamily.Monospace,
                        )
                    }
                }
                IconButton(onClick = onControl, enabled = enabled) {
                    Icon(Icons.Default.Tune, contentDescription = "Control")
                }
                IconButton(onClick = onUnload, enabled = enabled) {
                    Icon(Icons.Default.Delete, contentDescription = "Unload")
                }
            }
            module.description?.let {
                Spacer(Modifier.height(4.dp))
                Text(
                    it,
                    style = MaterialTheme.typography.bodySmall,
                    maxLines = 3,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
    }
}

@Composable
private fun SettingsDialog(
    state: UiState,
    onKeyChange: (String) -> Unit,
    onSave: () -> Unit,
    onDismiss: () -> Unit,
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Superkey") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(
                    "Must match the key used when patching the kernel image " +
                        "(scripts/kpm-patch-image.sh reads it from SUPERKEY).",
                    style = MaterialTheme.typography.bodySmall,
                )
                OutlinedTextField(
                    value = state.superKey,
                    onValueChange = onKeyChange,
                    singleLine = true,
                    label = { Text("Superkey") },
                    modifier = Modifier.fillMaxWidth(),
                )
            }
        },
        confirmButton = { TextButton(onClick = onSave) { Text("Save and connect") } },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}

@Composable
private fun ControlDialog(
    module: Kpm,
    onSend: (String) -> Unit,
    onDismiss: () -> Unit,
) {
    var args by rememberSaveable { mutableStateOf("") }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Control ${module.name}") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(
                    "Passed to the module's ctl0 callback as a plain string.",
                    style = MaterialTheme.typography.bodySmall,
                )
                OutlinedTextField(
                    value = args,
                    onValueChange = { args = it },
                    singleLine = true,
                    label = { Text("Arguments") },
                    modifier = Modifier.fillMaxWidth(),
                )
            }
        },
        confirmButton = { TextButton(onClick = { onSend(args) }) { Text("Send") } },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}
