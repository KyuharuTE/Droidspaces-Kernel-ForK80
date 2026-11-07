package com.droidspaces.kpmanager.kpm

/**
 * One loaded KPM, as reported by the kernel.
 *
 * `info` returns the module's own key=value metadata, so the fields are parsed
 * leniently: a module is free to declare only some of them.
 */
data class Kpm(
    val name: String,
    val version: String? = null,
    val license: String? = null,
    val author: String? = null,
    val description: String? = null,
) {
    companion object {
        /**
         * Parse the `OK info` payload. Lines are `key=value`; unknown keys are
         * ignored rather than treated as an error, because the metadata contract
         * belongs to KPM authors, not to this app.
         */
        fun fromInfo(name: String, payload: String): Kpm {
            val map = payload.lineSequence()
                .mapNotNull { line ->
                    val i = line.indexOf('=')
                    if (i <= 0) null else line.substring(0, i).trim() to line.substring(i + 1).trim()
                }
                .toMap()
            return Kpm(
                name = map["name"]?.ifBlank { null } ?: name,
                version = map["version"],
                license = map["license"],
                author = map["author"],
                description = map["description"],
            )
        }
    }
}

/** Result of a shell round trip, kept separate so the UI can show failures. */
sealed interface KpmOpResult {
    data class Success(val message: String) : KpmOpResult
    data class Failure(val message: String) : KpmOpResult
}
