package com.droidspaces.kpmanager.ui

import android.app.Application
import android.net.Uri
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.droidspaces.kpmanager.kpm.Kpm
import com.droidspaces.kpmanager.kpm.KpmOpResult
import com.droidspaces.kpmanager.kpm.KpmRepository
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

data class UiState(
    val superKey: String = "",
    val connected: Boolean = false,
    val connecting: Boolean = false,
    val modules: List<Kpm> = emptyList(),
    val busy: Boolean = false,
    val message: String? = null,
    val isError: Boolean = false,
)

/**
 * All kernel traffic goes through here.
 *
 * Every operation shells out, so each one runs on Dispatchers.IO. The state is a
 * single object rather than several flows so the UI can never render a module
 * list from one moment beside a connection status from another.
 */
class MainViewModel(app: Application) : AndroidViewModel(app) {

    private val repo = KpmRepository(app)
    private val prefs = app.getSharedPreferences("kpmanager", Application.MODE_PRIVATE)

    private val _state = MutableStateFlow(UiState())
    val state: StateFlow<UiState> = _state.asStateFlow()

    init {
        // The key the image was patched with. Restored so the app reconnects
        // without the user pasting it every launch.
        val saved = prefs.getString(KEY_SUPERKEY, "").orEmpty()
        _state.update { it.copy(superKey = saved) }
        if (saved.isNotEmpty()) connect()
    }

    fun onSuperKeyChange(value: String) {
        _state.update { it.copy(superKey = value) }
    }

    fun saveSuperKey() {
        val key = _state.value.superKey.trim()
        if (key.isEmpty()) {
            setMessage("Enter the superkey the kernel image was patched with", error = true)
            return
        }
        prefs.edit().putString(KEY_SUPERKEY, key).apply()
        connect()
    }

    fun connect() {
        val key = _state.value.superKey.trim()
        if (key.isEmpty()) return
        viewModelScope.launch {
            _state.update { it.copy(connecting = true, message = null) }
            when (val result = withContext(Dispatchers.IO) { repo.connect(key) }) {
                is KpmOpResult.Success -> {
                    _state.update { it.copy(connected = true, connecting = false) }
                    refresh()
                }
                is KpmOpResult.Failure -> {
                    _state.update { it.copy(connected = false, connecting = false) }
                    setMessage(result.message, error = true)
                }
            }
        }
    }

    fun refresh() {
        val key = _state.value.superKey.trim()
        if (key.isEmpty()) return
        viewModelScope.launch {
            _state.update { it.copy(busy = true) }
            val modules = withContext(Dispatchers.IO) { repo.list(key) }
            _state.update { it.copy(modules = modules, busy = false) }
        }
    }

    fun load(uri: Uri, args: String = "") {
        val key = _state.value.superKey.trim()
        viewModelScope.launch {
            _state.update { it.copy(busy = true) }
            val result = withContext(Dispatchers.IO) {
                runCatching {
                    val file = repo.stageModule(getApplication(), uri)
                    // The kernel opens the path itself, so chmod it world
                    // readable: filp_open runs with kernel creds, but the file
                    // still has to be readable for that to succeed on some
                    // security models.
                    file.setReadable(true, false)
                    repo.load(key, file.absolutePath, args)
                }.getOrElse { KpmOpResult.Failure("Cannot stage module: ${it.message}") }
            }
            _state.update { it.copy(busy = false) }
            report(result)
            refresh()
        }
    }

    fun unload(name: String) {
        val key = _state.value.superKey.trim()
        viewModelScope.launch {
            _state.update { it.copy(busy = true) }
            val result = withContext(Dispatchers.IO) { repo.unload(key, name) }
            _state.update { it.copy(busy = false) }
            report(result)
            refresh()
        }
    }

    fun control(name: String, ctlArgs: String) {
        val key = _state.value.superKey.trim()
        viewModelScope.launch {
            _state.update { it.copy(busy = true) }
            val result = withContext(Dispatchers.IO) { repo.control(key, name, ctlArgs) }
            _state.update { it.copy(busy = false) }
            report(result)
        }
    }

    fun dismissMessage() = _state.update { it.copy(message = null) }

    private fun report(result: KpmOpResult) = when (result) {
        is KpmOpResult.Success -> setMessage(result.message, error = false)
        is KpmOpResult.Failure -> setMessage(result.message, error = true)
    }

    private fun setMessage(text: String, error: Boolean) =
        _state.update { it.copy(message = text, isError = error) }

    companion object {
        private const val KEY_SUPERKEY = "superkey"
    }
}
