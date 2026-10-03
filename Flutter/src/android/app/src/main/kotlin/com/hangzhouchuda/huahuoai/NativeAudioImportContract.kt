package com.hangzhouchuda.huahuoai

data class NativeAudioImportMetadata(
    val displayName: String,
    val extension: String,
    val mimeType: String,
)

object NativeAudioImportContract {
    private const val MAX_DISPLAY_NAME_LENGTH = 240

    private val canonicalMimeTypes = mapOf(
        "mp3" to "audio/mpeg",
        "m4a" to "audio/mp4",
        "mp4" to "audio/mp4",
        "wav" to "audio/wav",
        "opus" to "audio/opus",
    )

    private val recognizedMimeExtensions = mapOf(
        "audio/mpeg" to setOf("mp3"),
        "audio/mp3" to setOf("mp3"),
        "audio/mp4" to setOf("m4a", "mp4"),
        "audio/x-m4a" to setOf("m4a", "mp4"),
        "audio/wav" to setOf("wav"),
        "audio/x-wav" to setOf("wav"),
        "audio/opus" to setOf("opus"),
        "audio/ogg" to setOf("opus"),
    )

    fun resolve(displayName: String?, declaredMimeType: String?): NativeAudioImportMetadata? {
        val safeName = displayName?.trim()?.takeIf(::isSafeDisplayName) ?: return null
        val normalizedMime = declaredMimeType
            ?.trim()
            ?.lowercase()
            ?.substringBefore(';')
            ?.trim()
            ?.takeIf(String::isNotEmpty)

        val declaredExtension = safeName.substringAfterLast('.', "").lowercase()
        var extension = declaredExtension
        if (extension.isEmpty()) {
            val inferred = recognizedMimeExtensions[normalizedMime]?.firstOrNull() ?: return null
            extension = inferred
        }
        if (extension !in canonicalMimeTypes) return null

        val expectedExtensions = recognizedMimeExtensions[normalizedMime]
        if (expectedExtensions != null && extension !in expectedExtensions) return null
        if (normalizedMime != null &&
            normalizedMime != "application/octet-stream" &&
            !normalizedMime.startsWith("audio/")
        ) {
            return null
        }

        val normalizedName = if (safeName.substringAfterLast('.', "").lowercase() == extension) {
            safeName
        } else {
            "$safeName.$extension"
        }
        if (normalizedName.length > MAX_DISPLAY_NAME_LENGTH) return null
        return NativeAudioImportMetadata(
            displayName = normalizedName,
            extension = extension,
            mimeType = canonicalMimeTypes.getValue(extension),
        )
    }

    private fun isSafeDisplayName(value: String): Boolean {
        return value.isNotEmpty() &&
            value.length <= MAX_DISPLAY_NAME_LENGTH &&
            '/' !in value &&
            '\\' !in value &&
            value.none(Char::isISOControl) &&
            value != "." &&
            value != ".."
    }
}
