package com.hangzhouchuda.huahuoai

import java.nio.file.Files
import java.util.concurrent.CountDownLatch
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class RecordingExportContractTest {
    @Test
    fun pcmCaptureTerminationRequiresTheWriterThreadToExit() {
        val completed = Thread {}
        completed.start()
        assertTrue(awaitPcmCaptureThreadTermination(completed, 1_000))

        val release = CountDownLatch(1)
        val blocked = Thread { release.await() }
        blocked.start()
        try {
            assertFalse(awaitPcmCaptureThreadTermination(blocked, 10))
        } finally {
            release.countDown()
        }
        assertTrue(awaitPcmCaptureThreadTermination(blocked, 1_000))
    }

    @Test
    fun pcmEarlyQueueFailsExplicitlyWithoutEvictingTheOldestFrame() {
        val queue = PcmEarlyFrameQueue(capacityFrames = 2)
        val first = byteArrayOf(1)
        val second = byteArrayOf(2)

        assertTrue(queue.append(first))
        assertTrue(queue.append(second))
        assertEquals(2, queue.size)
        assertFalse(queue.append(byteArrayOf(3)))
        assertTrue(queue.overflowed)
        assertEquals(0, queue.size)
        assertEquals(3, queue.droppedFrameCount)
        assertFalse(queue.append(byteArrayOf(4)))
        assertEquals(4, queue.droppedFrameCount)

        queue.reset()
        assertFalse(queue.overflowed)
        assertEquals(0, queue.droppedFrameCount)
        assertTrue(queue.append(first))
        assertEquals(first.toList(), queue.removeFirstOrNull()?.toList())
    }

    @Test
    fun pcmDrainPacerHandles375And1125FramesWithoutBursting() {
        listOf(375, 1_125).forEach { frameCount ->
            val queue = PcmEarlyFrameQueue(capacityFrames = frameCount)
            val pacer = PcmFrameDrainPacer()
            repeat(frameCount) { index ->
                assertTrue(queue.append(byteArrayOf((index and 0xff).toByte())))
            }

            var tick = 0
            var delivered = 0
            var dartQueuedFrames = 0
            var maximumDartQueuedFrames = 0
            while (!queue.isEmpty) {
                val token = requireNotNull(
                    pacer.request(
                        hasListener = true,
                        hasFrames = !queue.isEmpty,
                        overflowed = queue.overflowed,
                    ),
                )
                assertNull(
                    pacer.request(
                        hasListener = true,
                        hasFrames = true,
                        overflowed = false,
                    ),
                )
                assertTrue(pacer.beginDelivery(token))
                assertNotNull(queue.removeFirstOrNull())
                delivered += 1
                dartQueuedFrames += 1
                maximumDartQueuedFrames = maxOf(maximumDartQueuedFrames, dartQueuedFrames)

                val dartIsCatchingUp = dartQueuedFrames > 25
                val regularOutboundTick = tick % 2 == 1
                if (dartIsCatchingUp || regularOutboundTick) {
                    dartQueuedFrames -= 1
                }
                if (tick % 2 == 1) {
                    assertTrue(queue.append(byteArrayOf(0x7f)))
                }
                tick += 1
                assertTrue(tick < frameCount * 3)
            }

            assertTrue(delivered > frameCount)
            assertTrue(maximumDartQueuedFrames < 160)
            assertEquals(20L, PcmFrameDrainPacer.INTERVAL_MILLIS)
        }
    }

    @Test
    fun pcmDrainPacerCancellationInvalidatesPendingTick() {
        val pacer = PcmFrameDrainPacer()
        val token = requireNotNull(
            pacer.request(
                hasListener = true,
                hasFrames = true,
                overflowed = false,
            ),
        )

        pacer.cancel()

        assertFalse(pacer.beginDelivery(token))
        assertFalse(pacer.scheduled)
    }

    @Test
    fun resolveMapsOpaqueReferenceToNarrowInternalPath() {
        val resolved = RecordingExportContract.resolve(
            "app-private-export://recordings/cache/export-a19/Meeting_01.m4a",
        )

        assertEquals(
            "recordings/temporary/export/cache/export-a19/Meeting_01.m4a",
            resolved?.relativePath,
        )
        assertEquals("Meeting_01.m4a", resolved?.fileName)
        assertEquals("audio/mp4", resolved?.mimeType)
    }

    @Test
    fun resolveMapsAccountScopedReferenceToItsIsolatedPath() {
        val scope = "u-0123456789abcdef0123456789abcdef"
        val resolved = RecordingExportContract.resolve(
            "app-private-export://recordings/users/$scope/cache/" +
                "export-a19/Meeting_01.m4a",
        )

        assertEquals(
            "recordings/users/$scope/temporary/export/cache/" +
                "export-a19/Meeting_01.m4a",
            resolved?.relativePath,
        )
        assertEquals(
            "recordings/users/$scope/temporary/export",
            resolved?.exportRootRelativePath,
        )
        assertNull(
            RecordingExportContract.resolve(
                "app-private-export://recordings/users/user@example.com/cache/" +
                    "export-a19/Meeting_01.m4a",
            ),
        )
    }

    @Test
    fun resolveDerivesSupportedAudioMimeTypes() {
        val expected = mapOf(
            "mp3" to "audio/mpeg",
            "m4a" to "audio/mp4",
            "mp4" to "audio/mp4",
            "wav" to "audio/wav",
            "opus" to "audio/opus",
        )

        expected.forEach { (extension, mimeType) ->
            val resolved = RecordingExportContract.resolve(
                "app-private-export://recordings/cache/export-1/audio.$extension",
            )
            assertEquals(mimeType, resolved?.mimeType)
        }
    }

    @Test
    fun resolveRejectsTraversalAndNonOpaqueReferences() {
        val invalid = listOf(
            "/data/user/0/app/files/recording.m4a",
            "file:///data/user/0/app/files/recording.m4a",
            "app-private-export://recordings/cache/export-1/../recording.m4a",
            "app-private-export://recordings/cache/export-1/%2e%2e%2frecording.m4a",
            "app-private-export://recordings/cache/export-1/recording.m4a?copy=1",
            "app-private-export://recordings/cache/export-1/recording.m4a#copy",
            "app-private-export://recordings/cache/export-1/recording.aac",
            "app-private-export://other/cache/export-1/recording.m4a",
        )

        invalid.forEach { assertNull(RecordingExportContract.resolve(it)) }
    }

    @Test
    fun preferredDisplayNameAllowsUnicodeButRejectsUnsafeOrMismatchedNames() {
        val fallback = "recording.m4a"

        assertEquals(
            "用户重命名.m4a",
            RecordingExportContract.preferredDisplayName(" 用户重命名.m4a ", fallback),
        )
        assertEquals(
            fallback,
            RecordingExportContract.preferredDisplayName("../private.m4a", fallback),
        )
        assertEquals(
            fallback,
            RecordingExportContract.preferredDisplayName("recording.wav", fallback),
        )
        assertEquals(
            fallback,
            RecordingExportContract.preferredDisplayName("bad\u0000name.m4a", fallback),
        )
    }

    @Test
    fun resolveSourceFileClassifiesReadyMissingAndEmptyFiles() {
        val root = Files.createTempDirectory("huahuo-export-contract").toFile()
        try {
            val location = requireNotNull(
                RecordingExportContract.resolve(
                    "app-private-export://recordings/cache/export-1/recording.m4a",
                ),
            )
            val source = root.resolve(location.relativePath)
            source.parentFile.mkdirs()

            assertEquals(
                RecordingExportSourceError.MISSING,
                RecordingExportContract.resolveSourceFile(root, location).error,
            )
            source.createNewFile()
            assertEquals(
                RecordingExportSourceError.EMPTY,
                RecordingExportContract.resolveSourceFile(root, location).error,
            )
            source.writeBytes(byteArrayOf(1, 2, 3))
            val ready = RecordingExportContract.resolveSourceFile(root, location)
            assertEquals(source.canonicalFile, ready.sourceFile)
            assertNull(ready.error)
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun resolveSourceFileFindsAccountScopedPreparedBytes() {
        val root = Files.createTempDirectory("huahuo-scoped-export-contract").toFile()
        try {
            val scope = "u-0123456789abcdef0123456789abcdef"
            val location = requireNotNull(
                RecordingExportContract.resolve(
                    "app-private-export://recordings/users/$scope/cache/" +
                        "export-1/recording.m4a",
                ),
            )
            val source = root.resolve(location.relativePath)
            source.parentFile.mkdirs()
            source.writeBytes(byteArrayOf(1, 2, 3))

            val ready = RecordingExportContract.resolveSourceFile(root, location)
            assertEquals(source.canonicalFile, ready.sourceFile)
            assertNull(ready.error)
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun resolveSourceFileRejectsSymbolicLinkSubstitution() {
        val root = Files.createTempDirectory("huahuo-export-contract").toFile()
        try {
            val location = requireNotNull(
                RecordingExportContract.resolve(
                    "app-private-export://recordings/cache/export-1/recording.m4a",
                ),
            )
            val target = root.resolve("outside.m4a").apply { writeBytes(byteArrayOf(1)) }
            val source = root.resolve(location.relativePath)
            source.parentFile.mkdirs()
            Files.createSymbolicLink(source.toPath(), target.toPath())

            val resolved = RecordingExportContract.resolveSourceFile(root, location)
            assertNull(resolved.sourceFile)
            assertEquals(RecordingExportSourceError.UNSAFE, resolved.error)
        } finally {
            root.deleteRecursively()
        }
    }
}
