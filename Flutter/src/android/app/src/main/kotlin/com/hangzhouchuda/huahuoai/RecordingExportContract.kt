package com.hangzhouchuda.huahuoai

import java.io.File

internal data class RecordingExportLocation(
    val relativePath: String,
    val exportRootRelativePath: String,
    val fileName: String,
    val mimeType: String,
)

internal enum class RecordingExportSourceError {
    UNAVAILABLE,
    UNSAFE,
    MISSING,
    EMPTY,
}

internal data class RecordingExportSourceResolution(
    val sourceFile: File? = null,
    val error: RecordingExportSourceError? = null,
)

internal object RecordingExportContract {
    private val opaqueReference = Regex(
        "^app-private-export://recordings/cache/" +
            "(export-[A-Za-z0-9_-]{1,80})/" +
            "([A-Za-z0-9][A-Za-z0-9._-]{0,95}\\.(mp3|m4a|mp4|wav|opus))$",
        RegexOption.IGNORE_CASE,
    )
    private val scopedOpaqueReference = Regex(
        "^app-private-export://recordings/users/" +
            "(u-[a-f0-9]{32})/cache/" +
            "(export-[A-Za-z0-9_-]{1,80})/" +
            "([A-Za-z0-9][A-Za-z0-9._-]{0,95}\\.(mp3|m4a|mp4|wav|opus))$",
    )

    fun resolve(opaqueExportRef: String?): RecordingExportLocation? {
        val value = opaqueExportRef?.trim()?.takeIf { it == opaqueExportRef } ?: return null
        val scopedMatch = scopedOpaqueReference.matchEntire(value)
        val legacyMatch = if (scopedMatch == null) opaqueReference.matchEntire(value) else null
        val accountScope = scopedMatch?.groupValues?.get(1)
        val exportId = scopedMatch?.groupValues?.get(2) ?: legacyMatch?.groupValues?.get(1)
            ?: return null
        val fileName = scopedMatch?.groupValues?.get(3) ?: legacyMatch?.groupValues?.get(2)
            ?: return null
        val extension = scopedMatch?.groupValues?.get(4) ?: legacyMatch?.groupValues?.get(3)
            ?: return null
        val exportRoot = if (accountScope == null) {
            "recordings/temporary/export"
        } else {
            "recordings/users/$accountScope/temporary/export"
        }
        return RecordingExportLocation(
            relativePath = "$exportRoot/cache/$exportId/$fileName",
            exportRootRelativePath = exportRoot,
            fileName = fileName,
            mimeType = mimeTypeForExtension(extension.lowercase()),
        )
    }

    fun preferredDisplayName(
        requestedDisplayName: String?,
        fallbackFileName: String,
    ): String {
        val requested = requestedDisplayName?.trim().orEmpty()
        if (requested.isEmpty() ||
            requested.length > 80 ||
            requested.any { it == '/' || it == '\\' || it.code < 32 || it.code == 127 }
        ) {
            return fallbackFileName
        }
        val requestedExtension = requested.substringAfterLast('.', "").lowercase()
        val fallbackExtension = fallbackFileName.substringAfterLast('.', "").lowercase()
        return if (requestedExtension == fallbackExtension && requestedExtension in audioExtensions) {
            requested
        } else {
            fallbackFileName
        }
    }

    fun resolveSourceFile(
        applicationSupportRoot: File,
        location: RecordingExportLocation,
    ): RecordingExportSourceResolution {
        return try {
            val canonicalFilesRoot = applicationSupportRoot.canonicalFile
            val absoluteExportRoot = File(
                canonicalFilesRoot,
                location.exportRootRelativePath,
            ).absoluteFile
            val canonicalExportRoot = absoluteExportRoot.canonicalFile
            val absoluteCandidate = File(canonicalFilesRoot, location.relativePath).absoluteFile
            val canonicalCandidate = absoluteCandidate.canonicalFile
            val expectedPrefix = "${canonicalExportRoot.path}${File.separator}"
            if (absoluteExportRoot.path != canonicalExportRoot.path ||
                absoluteCandidate.path != canonicalCandidate.path ||
                !canonicalCandidate.path.startsWith(expectedPrefix)
            ) {
                RecordingExportSourceResolution(error = RecordingExportSourceError.UNSAFE)
            } else if (!canonicalCandidate.exists() || !canonicalCandidate.isFile) {
                RecordingExportSourceResolution(error = RecordingExportSourceError.MISSING)
            } else if (canonicalCandidate.length() <= 0L) {
                RecordingExportSourceResolution(error = RecordingExportSourceError.EMPTY)
            } else {
                RecordingExportSourceResolution(sourceFile = canonicalCandidate)
            }
        } catch (_: Exception) {
            RecordingExportSourceResolution(error = RecordingExportSourceError.UNAVAILABLE)
        }
    }

    private fun mimeTypeForExtension(extension: String): String = when (extension) {
        "mp3" -> "audio/mpeg"
        "m4a", "mp4" -> "audio/mp4"
        "wav" -> "audio/wav"
        "opus" -> "audio/opus"
        else -> "application/octet-stream"
    }

    private val audioExtensions = setOf("mp3", "m4a", "mp4", "wav", "opus")
}
