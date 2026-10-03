package com.hangzhouchuda.huahuoai

import java.nio.file.Files
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class KnowledgeExportContractTest {
    @Test
    fun resolveMapsMarkdownPdfAndZipToNarrowKnowledgePath() {
        val markdown = KnowledgeExportContract.resolve(
            "app-private-export://knowledge/cache/export-a19/knowledge.md",
        )
        val pdf = KnowledgeExportContract.resolve(
            "app-private-export://knowledge/cache/export-b20/knowledge.pdf",
        )
        val archive = KnowledgeExportContract.resolve(
            "app-private-export://knowledge/cache/export-c21/digital-twin.zip",
        )

        assertEquals(
            "HuahuoAI/TemporaryTransfers/knowledge/cache/export-a19/knowledge.md",
            markdown?.relativePath,
        )
        assertEquals("text/markdown", markdown?.mimeType)
        assertEquals("application/pdf", pdf?.mimeType)
        assertEquals("application/zip", archive?.mimeType)
    }

    @Test
    fun resolveRejectsAudioTraversalEncodingAndAbsoluteReferences() {
        val invalid = listOf(
            "/data/user/0/app/files/knowledge.pdf",
            "file:///data/user/0/app/files/knowledge.pdf",
            "app-private-export://recordings/cache/export-1/knowledge.pdf",
            "app-private-export://knowledge/cache/export-1/../knowledge.pdf",
            "app-private-export://knowledge/cache/export-1/%2e%2e.pdf",
            "app-private-export://knowledge/cache/export-1/knowledge.pdf?copy=1",
            "app-private-export://knowledge/cache/export-1/knowledge.pdf#copy",
            "app-private-export://knowledge/cache/export-1/audio.m4a",
        )

        invalid.forEach { assertNull(KnowledgeExportContract.resolve(it)) }
    }

    @Test
    fun validatesUnicodeDisplayMetadataAndRejectsPrivateShareText() {
        val location = requireNotNull(
            KnowledgeExportContract.resolve(
                "app-private-export://knowledge/cache/export-1/knowledge.pdf",
            ),
        )

        assertTrue(KnowledgeExportContract.isValidDisplayName("中文知识.pdf", location))
        assertFalse(KnowledgeExportContract.isValidDisplayName("../知识.pdf", location))
        assertFalse(KnowledgeExportContract.isValidDisplayName("知识.md", location))
        assertTrue(KnowledgeExportContract.isSafeShareText("标题\n\n来源：链接笔记"))
        assertFalse(KnowledgeExportContract.isSafeShareText("file:///private/note.md"))
        assertFalse(KnowledgeExportContract.isSafeShareText("/Users/run/note.md"))
        assertFalse(KnowledgeExportContract.isSafeShareText("app-private://note/1"))
    }

    @Test
    fun resolveSourceFileClassifiesReadyMissingAndEmptyFiles() {
        val root = Files.createTempDirectory("huahuo-knowledge-export").toFile()
        try {
            val location = requireNotNull(
                KnowledgeExportContract.resolve(
                    "app-private-export://knowledge/cache/export-1/knowledge.md",
                ),
            )
            val source = root.resolve(location.relativePath)
            source.parentFile.mkdirs()

            assertEquals(
                KnowledgeExportSourceError.MISSING,
                KnowledgeExportContract.resolveSourceFile(root, location).error,
            )
            source.createNewFile()
            assertEquals(
                KnowledgeExportSourceError.EMPTY,
                KnowledgeExportContract.resolveSourceFile(root, location).error,
            )
            source.writeText("# 知识")
            val ready = KnowledgeExportContract.resolveSourceFile(root, location)
            assertEquals(source.canonicalFile, ready.sourceFile)
            assertNull(ready.error)
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun resolveSourceFileRejectsSymbolicLinkSubstitution() {
        val root = Files.createTempDirectory("huahuo-knowledge-export").toFile()
        try {
            val location = requireNotNull(
                KnowledgeExportContract.resolve(
                    "app-private-export://knowledge/cache/export-1/knowledge.pdf",
                ),
            )
            val outside = root.resolve("outside.pdf").apply {
                writeBytes(byteArrayOf(1))
            }
            val source = root.resolve(location.relativePath)
            source.parentFile.mkdirs()
            Files.createSymbolicLink(source.toPath(), outside.toPath())

            val resolved = KnowledgeExportContract.resolveSourceFile(root, location)
            assertNull(resolved.sourceFile)
            assertEquals(KnowledgeExportSourceError.UNSAFE, resolved.error)
        } finally {
            root.deleteRecursively()
        }
    }
}
