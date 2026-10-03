package com.hangzhouchuda.huahuoai

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class NativeAudioImportContractTest {
    @Test
    fun acceptsSupportedAudioFormatsAndPreservesUnicodeNames() {
        val cases = listOf(
            Triple("中文录音.mp3", "audio/mpeg", "audio/mpeg"),
            Triple("meeting.m4a", "audio/x-m4a", "audio/mp4"),
            Triple("capture.mp4", "audio/mp4", "audio/mp4"),
            Triple("voice.wav", "audio/x-wav", "audio/wav"),
            Triple("memo.opus", "audio/ogg", "audio/opus"),
        )

        cases.forEach { (name, declaredMime, expectedMime) ->
            val resolved = NativeAudioImportContract.resolve(name, declaredMime)
            assertEquals(name, resolved?.displayName)
            assertEquals(expectedMime, resolved?.mimeType)
        }
    }

    @Test
    fun recoversMissingExtensionFromRecognizedAudioMime() {
        val resolved = NativeAudioImportContract.resolve("采访录音", "audio/mpeg")

        assertEquals("采访录音.mp3", resolved?.displayName)
        assertEquals("mp3", resolved?.extension)
    }

    @Test
    fun rejectsMimeExtensionConflictsAndNonAudioMime() {
        assertNull(NativeAudioImportContract.resolve("voice.mp3", "audio/wav"))
        assertNull(NativeAudioImportContract.resolve("voice.wav", "text/plain"))
        assertNull(NativeAudioImportContract.resolve("voice.exe", "audio/mpeg"))
    }

    @Test
    fun rejectsUnsafeBlankAndOverlongDisplayNames() {
        assertNull(NativeAudioImportContract.resolve("", "audio/mpeg"))
        assertNull(NativeAudioImportContract.resolve("../voice.mp3", "audio/mpeg"))
        assertNull(NativeAudioImportContract.resolve("folder\\voice.mp3", "audio/mpeg"))
        assertNull(NativeAudioImportContract.resolve("bad\u0000.mp3", "audio/mpeg"))
        assertNull(NativeAudioImportContract.resolve("a".repeat(241), "audio/mpeg"))
    }
}
