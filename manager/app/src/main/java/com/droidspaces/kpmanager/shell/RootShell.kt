package com.droidspaces.kpmanager.shell

import android.content.Context
import java.io.File
import java.security.MessageDigest
import java.util.zip.ZipFile

/**
 * Root shell access plus the one-time extraction of the bundled kpctl binary.
 *
 * The executable may remain inside the APK instead of being extracted by the
 * installer. It is copied into app-private storage, chmod 700'd there, and invoked through `su`
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
                ?: stderr.trim().ifEmpty { stdout.trim().ifEmpty { "exit $exitCode" } }
    }

    /** True when a root shell can be obtained at all. */
    fun hasRoot(): Boolean {
        val r = exec("id -u", extractBinary = false)
        return r.ok && r.stdout.trim() == "0"
    }

    /**
     * Extract libkpctl.so from the APK into app-private storage and make it
     * executable. A digest comparison also detects same-size client updates.
     */
    @Synchronized
    fun ensureKpctl(): File {
        val dir = File(context.filesDir, "bin").apply {
            check(isDirectory || mkdirs()) { "cannot create client directory" }
        }
        val out = File(dir, "kpctl")
        val packaged = File(context.applicationInfo.nativeLibraryDir, "libkpctl.so")
        val bytes = if (packaged.isFile) {
            packaged.readBytes()
        } else {
            // Modern AGP packages native entries uncompressed without extracting
            // them. A CLI must then be read from the installed APK explicitly.
            val apks = listOf(context.applicationInfo.sourceDir) +
                context.applicationInfo.splitSourceDirs.orEmpty().toList()
            apks.firstNotNullOfOrNull { path ->
                ZipFile(path).use { zip ->
                    zip.getEntry("lib/arm64-v8a/libkpctl.so")?.let { entry ->
                        zip.getInputStream(entry).use { it.readBytes() }
                    }
                }
            } ?: error("libkpctl.so missing from installed APKs")
        }
        fun digest(data: ByteArray) = MessageDigest.getInstance("SHA-256").digest(data)
        if (!out.isFile || !digest(out.readBytes()).contentEquals(digest(bytes))) {
            val staged = File(dir, "kpctl.tmp")
            staged.writeBytes(bytes)
            check(staged.setExecutable(true, true)) { "cannot mark client executable" }
            check(staged.renameTo(out)) { "cannot replace client" }
        }
        check(out.canExecute() || out.setExecutable(true, true)) { "client is not executable" }
        return out
    }

    /**
     * Run kpctl with the given arguments through su.
     *
     * The key is written to stdin, so shell expansion cannot erase it and the
     * secret is absent from the su/kpctl command lines.
     */
    fun kpctl(superKey: String, vararg args: String): Result = try {
        require(superKey.isNotEmpty() && superKey.length <= 64 &&
            !superKey.contains('\n') && !superKey.contains('\r')) { "invalid superkey" }
        val binary = ensureKpctl()
        val quotedArgs = args.joinToString(" ") { quote(it) }
        exec("${quote(binary.absolutePath)} --key-stdin $quotedArgs",
            extractBinary = false, stdin = "$superKey\n")
    } catch (e: Exception) {
        Result(-1, "", "KPM client unavailable: ${e.message}")
    }

    /**
     * Run a command as root.
     *
     * Everything interpolated by callers is quoted, including file names the
     * user picked: a file name is not a trust boundary.
     */
    fun exec(command: String, extractBinary: Boolean = true, stdin: String = ""): Result {
        if (extractBinary) runCatching { ensureKpctl() }
        return try {
            val process = ProcessBuilder("su", "-c", command).redirectErrorStream(true).start()
            process.outputStream.bufferedWriter().use { it.write(stdin) }
            val output = process.inputStream.bufferedReader().use { it.readText() }
            Result(process.waitFor(), output, "")
        } catch (e: Exception) {
            Result(-1, "", "su not available: ${e.message}")
        }
    }

    companion object {
        /** POSIX single-quote escaping; both the key and paths reach a shell. */
        fun quote(value: String): String = "'" + value.replace("'", "'\\''") + "'"
    }
}
