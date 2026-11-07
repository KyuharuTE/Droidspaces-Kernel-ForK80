package com.droidspaces.kpmanager.shell

import android.content.Context
import java.io.File
import java.io.IOException

/**
 * Root shell access plus the one-time extraction of the bundled kpctl binary.
 *
 * The binary cannot be executed from the APK: Android refuses exec on files in
 * read-only storage, and the native library directory is read-only. It is copied
 * into app-private storage, chmod 700'd there, and always invoked through `su`
 * so it runs with a root UID instead of the app's restricted seccomp profile.
 */
class RootShell(private val context: Context) {

    data class Result(val exitCode: Int, val stdout: String, val stderr: String) {
        val ok: Boolean get() = exitCode == 0

        /** Payload of the first "OK ..." line, or the trimmed stdout. */
        val payload: String
            get() = stdout.lineSequence()
                .firstOrNull { it.startsWith("OK") }
                ?.removePrefix("OK")
                ?.trim()
                ?: stdout.trim()

        /** "ERR code message" for display, or stderr when there is no ERR line. */
        val error: String
            get() = stdout.lineSequence().firstOrNull { it.startsWith("ERR") }
                ?: stderr.trim().ifEmpty { "exit $exitCode" }
    }

    /** True when a root shell can be obtained at all. */
    fun hasRoot(): Boolean {
        val r = exec("id -u", extractBinary = false)
        return r.ok && r.stdout.trim() == "0"
    }

    /**
     * Extract libkpctl.so from the APK into app-private storage and make it
     * executable. Re-extracts when the packaged size differs, so an app update
     * always carries the matching binary.
     */
    fun ensureKpctl(): File {
        val dir = File(context.filesDir, "bin").apply { mkdirs() }
        val out = File(dir, "kpctl")

        val packaged = context.applicationInfo.nativeLibraryDir?.let { File(it, "libkpctl.so") }
        requireNotNull(packaged) { "native library dir unavailable" }
        check(packaged.isFile) { "libkpctl.so missing from the APK; check abiFilters" }

        if (!out.isFile || out.length() != packaged.length()) {
            packaged.inputStream().use { input ->
                out.outputStream().use { output -> input.copyTo(output) }
            }
        }
        if (!out.canExecute()) {
            check(out.setExecutable(true, false)) { "cannot mark ${out.name} executable" }
        }
        return out
    }

    /**
     * Run kpctl with the given arguments through su.
     *
     * The superkey is passed in an environment variable rather than argv: on
     * Android any process can read another process's command line. The binary
     * still has to place it in a syscall argument, which is unavoidable here.
     */
    fun kpctl(superKey: String, vararg args: String): Result {
        val binary = ensureKpctl()
        val quotedArgs = args.joinToString(" ") { quote(it) }
        val command = "SUPERKEY=${quote(superKey)} '${binary.absolutePath}' " +
            "\"\$SUPERKEY\" $quotedArgs"
        return exec(command, extractBinary = false)
    }

    /**
     * Run a command as root.
     *
     * Everything interpolated by callers is quoted, including file names the
     * user picked: a file name is not a trust boundary.
     */
    fun exec(command: String, extractBinary: Boolean = true): Result {
        if (extractBinary) runCatching { ensureKpctl() }
        return try {
            val process = ProcessBuilder("su", "-c", command).start()
            val stdout = process.inputStream.bufferedReader().readText()
            val stderr = process.errorStream.bufferedReader().readText()
            Result(process.waitFor(), stdout, stderr)
        } catch (e: IOException) {
            Result(-1, "", "su not available: ${e.message}")
        }
    }

    companion object {
        /** POSIX single-quote escaping; both the key and paths reach a shell. */
        fun quote(value: String): String = "'" + value.replace("'", "'\\''") + "'"
    }
}
