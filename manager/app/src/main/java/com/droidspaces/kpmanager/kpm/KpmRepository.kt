package com.droidspaces.kpmanager.kpm

import android.content.Context
import com.droidspaces.kpmanager.shell.RootShell

/**
 * Everything that talks to KernelPatch, in one place.
 *
 * KernelPatch exposes no device node and no ioctl: each call is the same
 * multiplexed syscall, wrapped by kpctl. Listing modules is the interesting one,
 * because the kernel returns bare names as a newline separated blob and the
 * per-module metadata has to be fetched per name.
 */
class KpmRepository(context: Context) {

    private val shell = RootShell(context.applicationContext)

    /** Cheap connectivity check: does a root shell work, and is the superkey right. */
    fun connect(superKey: String): KpmOpResult {
        val root = shell.hasRoot()
        if (!root) return KpmOpResult.Failure("No root shell. Droidspaces and KPM both need root.")
        val hello = shell.kpctl(superKey, "hello")
        if (hello.exitCode < 0) return KpmOpResult.Failure(hello.error)
        return if (hello.ok) {
            KpmOpResult.Success("Connected. KernelPatch ${hello.payload}")
        } else {
            KpmOpResult.Failure(
                "KernelPatch did not accept the superkey: ${hello.error}\n" +
                    "If this kernel was not patched with KernelPatch, no superkey will work.",
            )
        }
    }

    /** Names of loaded modules, in kernel order. */
    fun listNames(superKey: String): List<String> {
        val r = shell.kpctl(superKey, "list")
        if (!r.ok) return emptyList()
        // The payload is the newline separated name list, taken from the block
        // that follows the "OK list" header.
        return r.stdout
            .substringAfter("OK list", "")
            .lineSequence()
            .map { it.trim() }
            .filter { it.isNotEmpty() }
            .toList()
    }

    /**
     * Full module list. One syscall per module for the metadata, so this is
     * deliberately the only place that fans out.
     */
    fun list(superKey: String): List<Kpm> = listNames(superKey).map { name ->
        val info = shell.kpctl(superKey, "info", name)
        if (info.ok) Kpm.fromInfo(name, info.stdout.substringAfter("OK info", "")) else Kpm(name)
    }

    fun load(superKey: String, path: String, args: String): KpmOpResult {
        val r = shell.kpctl(superKey, "load", path, args)
        return if (r.ok) {
            KpmOpResult.Success("Loaded $path")
        } else {
            KpmOpResult.Failure("Load failed: ${r.error}")
        }
    }

    fun unload(superKey: String, name: String): KpmOpResult {
        val r = shell.kpctl(superKey, "unload", name)
        return if (r.ok) {
            KpmOpResult.Success("Unloaded $name")
        } else {
            KpmOpResult.Failure("Unload failed: ${r.error}")
        }
    }

    fun control(superKey: String, name: String, ctlArgs: String): KpmOpResult {
        val r = shell.kpctl(superKey, "control", name, ctlArgs)
        return if (r.ok) {
            KpmOpResult.Success(r.payload.ifBlank { "ok" })
        } else {
            KpmOpResult.Failure("Control failed: ${r.error}")
        }
    }

    /**
     * Copy a user-picked content URI into app-private storage so the kernel can
     * open it.
     *
     * The kernel resolves the path itself with filp_open under kernel creds, so
     * where the file lives does not matter to it, but the app cannot hand over a
     * content:// URI. Copying also means the .kpm survives the source being
     * deleted mid-load.
     */
    fun stageModule(context: Context, uri: android.net.Uri): java.io.File {
        val dir = java.io.File(context.filesDir, "kpm").apply { mkdirs() }
        val name = queryDisplayName(context, uri) ?: "module.kpm"
        val safe = name.replace(Regex("[^A-Za-z0-9._-]"), "_").takeLast(120)
        val out = java.io.File(dir, safe.ifBlank { "module.kpm" })
        context.contentResolver.openInputStream(uri)?.use { input ->
            out.outputStream().use { output -> input.copyTo(output) }
        } ?: throw java.io.IOException("cannot open $uri")
        return out
    }

    private fun queryDisplayName(context: Context, uri: android.net.Uri): String? {
        val projection = arrayOf(android.provider.OpenableColumns.DISPLAY_NAME)
        return context.contentResolver.query(uri, projection, null, null, null)?.use { cursor ->
            if (cursor.moveToFirst()) cursor.getString(0) else null
        }
    }
}
