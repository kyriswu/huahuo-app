package com.hangzhouchuda.huahuoai

import java.io.File

internal data class KnowledgeExportLocation(
    val relativePath: String,
    val fileName: String,
    val mimeType: String,
)

internal enum class KnowledgeExportSourceError {
    UNAVAILABLE,
    UNSAFE,
    MISSING,
    EMPTY,
}

internal data class KnowledgeExportSourceResolution(
    val sourceFile: File? = null,
    val error: KnowledgeExportSourceError? = null,
)

internal object KnowledgeExportContract {
    private val opaqueReference = Regex(
        "^app-private-export://knowledge/cache/" +
            "(export-[A-Za-z0-9_-]{1,80})/" +
            "([A-Za-z0-9][A-Za-z0-9._-]{0,95}\\.(md|pdf|zip))$",
        RegexOption.IGNORE_CASE,
    )
    private val privateLocator = Regex(
        "(?i)(?:(?:file|app-private(?:-export)?):/{1,3}|" +
            "/(?:Users|private/var|var/mobile|data/user|data/data)/|[A-Za-z]:\\\\)",
    )

    fun resolve(opaqueExportRef: String?): KnowledgeExportLocation? {
        val value = opaqueExportRef?.trim()?.takeIf { it == opaqueExportRef } ?: return null
        if ('%' in value || ".." in value) return null
        val match = opaqueReference.matchEntire(value) ?: return null
        val exportId = match.groupValues[1]
        val fileName = match.groupValues[2]
        val extension = match.groupValues[3].lowercase()
        return KnowledgeExportLocation(
            relativePath =
                "HuahuoAI/TemporaryTransfers/knowledge/cache/$exportId/$fileName",
            fileName = fileName,
            mimeType = mimeTypeForExtension(extension),
        )
    }

    fun isValidDisplayName(
        requestedDisplayName: String?,
        location: KnowledgeExportLocation,
    ): Boolean {
        val value = requestedDisplayName ?: return false
        if (value != value.trim() ||
            value.isEmpty() ||
            value.length > 128 ||
            value.startsWith('.') ||
            value.endsWith(".part", ignoreCase = true) ||
            value.any { it == '/' || it == '\\' || it.code < 32 || it.code == 127 }
        ) {
            return false
        }
        return value.substringAfterLast('.', "").lowercase() ==
            location.fileName.substringAfterLast('.', "").lowercase()
    }

    fun isSafeShareText(text: String?): Boolean {
        val value = text ?: return false
        return value == value.trim() &&
            value.isNotEmpty() &&
            value.length <= 12_000 &&
            !privateLocator.containsMatchIn(value)
    }

    fun resolveSourceFile(
        applicationSupportRoot: File,
        location: KnowledgeExportLocation,
    ): KnowledgeExportSourceResolution {
        return try {
            val canonicalFilesRoot = applicationSupportRoot.canonicalFile
            val absoluteExportRoot = File(
                canonicalFilesRoot,
                "HuahuoAI/TemporaryTransfers/knowledge",
            ).absoluteFile
            val canonicalExportRoot = absoluteExportRoot.canonicalFile
            val absoluteCandidate = File(canonicalFilesRoot, location.relativePath).absoluteFile
            val canonicalCandidate = absoluteCandidate.canonicalFile
            val expectedPrefix = "${canonicalExportRoot.path}${File.separator}"
            if (absoluteExportRoot.path != canonicalExportRoot.path ||
                absoluteCandidate.path != canonicalCandidate.path ||
                !canonicalCandidate.path.startsWith(expectedPrefix)
            ) {
                KnowledgeExportSourceResolution(error = KnowledgeExportSourceError.UNSAFE)
            } else if (!canonicalCandidate.exists() || !canonicalCandidate.isFile) {
                KnowledgeExportSourceResolution(error = KnowledgeExportSourceError.MISSING)
            } else if (canonicalCandidate.length() <= 0L) {
                KnowledgeExportSourceResolution(error = KnowledgeExportSourceError.EMPTY)
            } else {
                KnowledgeExportSourceResolution(sourceFile = canonicalCandidate)
            }
        } catch (_: Exception) {
            KnowledgeExportSourceResolution(error = KnowledgeExportSourceError.UNAVAILABLE)
        }
    }

    private fun mimeTypeForExtension(extension: String): String = when (extension) {
        "md" -> "text/markdown"
        "pdf" -> "application/pdf"
        "zip" -> "application/zip"
        else -> "application/octet-stream"
    }
}
