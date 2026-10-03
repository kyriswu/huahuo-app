package com.hangzhouchuda.huahuoai

import org.junit.Assert.assertEquals
import org.junit.Test

class RecordingCardFileDirectoryTest {
    @Test
    fun fileSizeResolutionPrefersProtocolBigEndian() {
        assertEquals(
            1_228_060L to "trusted",
            resolveRecordingCardDeviceFileSize(482_152_960L, 1_228_060L),
        )
        assertEquals(
            6_291_968L to "trusted",
            resolveRecordingCardDeviceFileSize(155_648L, 6_291_968L),
        )
        assertEquals(null, resolveRecordingCardDeviceFileSize(9_820L, 0L))
        assertEquals(null, resolveRecordingCardDeviceFileSize(0L, 0L))

        listOf(
            1L,
            4_040L,
            12_120L,
            65_535L,
            65_536L,
            155_648L,
            1_228_060L,
            6_291_968L,
            1024L * 1024L * 1024L,
        ).forEach { expected ->
            assertEquals(
                expected to "trusted",
                resolveRecordingCardDeviceFileSize(
                    Integer.toUnsignedLong(Integer.reverseBytes(expected.toInt())),
                    expected,
                ),
            )
        }
    }

    @Test
    fun wifiStatusOnlyResponsesAreDistinct() {
        assertEquals(
            RecordingCardWifiStatusOnlyResponse.ACCEPTED,
            recordingCardWifiStatusOnlyResponse(byteArrayOf(0x00)),
        )
        assertEquals(
            RecordingCardWifiStatusOnlyResponse.REJECTED,
            recordingCardWifiStatusOnlyResponse(byteArrayOf(0x01)),
        )
        assertEquals(
            RecordingCardWifiStatusOnlyResponse.INCOMPLETE,
            recordingCardWifiStatusOnlyResponse(byteArrayOf(0x02)),
        )
        assertEquals(
            RecordingCardWifiStatusOnlyResponse.NOT_STATUS,
            recordingCardWifiStatusOnlyResponse(byteArrayOf(0x03)),
        )
        assertEquals(
            RecordingCardWifiStatusOnlyResponse.NOT_STATUS,
            recordingCardWifiStatusOnlyResponse(byteArrayOf(0x00, 0x01)),
        )
    }

    @Test
    fun pendingRowsRemainInvisibleAndAbandonedScanPreservesCommittedFiles() {
        val original = row("old-file")
        val directory = RecordingCardFileDirectory(listOf(original))

        val failedScan = directory.beginScan()
        failedScan.add(row("partial-file"))

        assertEquals(listOf(original), directory.snapshot())

        val nextScan = directory.beginScan()
        assertEquals(0, nextScan.size)
        assertEquals(listOf(original), directory.snapshot())
    }

    @Test
    fun completionAtomicallyReplacesCommittedFiles() {
        val oldFile = row("old-file")
        val directory = RecordingCardFileDirectory(listOf(oldFile))
        val scan = directory.beginScan()
        val first = row("first-file")
        val second = row("second-file")

        scan.add(first)
        scan.add(second)
        assertEquals(listOf(oldFile), directory.snapshot())

        assertEquals(listOf(first, second), directory.commit(scan))
        assertEquals(listOf(first, second), directory.snapshot())
    }

    @Test
    fun successfulEmptyScanCommitsEmptyDirectory() {
        val directory = RecordingCardFileDirectory(listOf(row("old-file")))

        directory.commit(directory.beginScan())

        assertEquals(emptyList<Map<String, Any>>(), directory.snapshot())
    }

    @Test
    fun committedRowsDoNotAliasCallerOwnedMapsAndDeleteUsesNewSnapshot() {
        val callerOwned = mutableMapOf<String, Any>("deviceFileId" to "first-file")
        val directory = RecordingCardFileDirectory(listOf(callerOwned))
        callerOwned["deviceFileId"] = "changed-after-construction"

        assertEquals(listOf(row("first-file")), directory.snapshot())

        directory.remove("first-file")

        assertEquals(emptyList<Map<String, Any>>(), directory.snapshot())
    }

    private fun row(id: String): Map<String, Any> = mapOf("deviceFileId" to id)
}
