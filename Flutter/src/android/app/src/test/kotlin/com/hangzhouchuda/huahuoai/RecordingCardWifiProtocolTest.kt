package com.hangzhouchuda.huahuoai

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class RecordingCardWifiProtocolTest {
    @Test
    fun observedStatusFrameHasExpectedLayoutAndRoundTrips() {
        val frame = RecordingCardWifiProtocol.encode(0x20, 0, byteArrayOf(0))

        assertEquals(41, frame.size)
        assertArrayEquals("XnoteWifiHead  ".toByteArray(), frame.copyOfRange(0, 15))
        assertEquals(0x20, frame[15].toInt() and 0xff)
        assertEquals(1, frame[23].toInt() and 0xff)
        assertArrayEquals("XnoteWifiTail   ".toByteArray(), frame.copyOfRange(25, 41))

        val packet = RecordingCardWifiProtocol.decode(frame)
        assertEquals(0x20, packet.command)
        assertEquals(0, packet.sequence)
        assertArrayEquals(byteArrayOf(0), packet.payload)
    }

    @Test
    fun splitAndCoalescedFramesRetainSequenceIncludingWrap() {
        val first = RecordingCardWifiProtocol.encode(0x0b, 0xffff, byteArrayOf(1, 2, 3))
        val second = RecordingCardWifiProtocol.encode(0x0b, 0, byteArrayOf(4, 5))
        val decoder = RecordingCardWifiStreamDecoder(allowOmittedDataCrc = false)

        assertEquals(emptyList<RecordingCardWifiPacket>(), decoder.push(first.copyOfRange(0, 17)))
        val packets = decoder.push(first.copyOfRange(17, first.size) + second)

        assertEquals(2, packets.size)
        assertEquals(0xffff, packets[0].sequence)
        assertEquals(0, packets[1].sequence)
        assertArrayEquals(byteArrayOf(4, 5), packets[1].payload)
        assertEquals(0, decoder.pendingBytes)
    }

    @Test
    fun omittedCrcRequiresExplicitFirmwareCompatibility() {
        val frame = RecordingCardWifiProtocol.encode(0x0a, 4, byteArrayOf(0, 1, 2)).also {
            it[18] = 0
            it[19] = 0
        }

        assertThrows(RecordingCardWifiProtocolException::class.java) {
            RecordingCardWifiProtocol.decode(frame, allowOmittedDataCrc = false)
        }
        val packet = RecordingCardWifiProtocol.decode(frame, allowOmittedDataCrc = true)
        assertArrayEquals(byteArrayOf(0, 1, 2), packet.payload)

        frame[18] = 0x12
        frame[19] = 0x34
        assertThrows(RecordingCardWifiProtocolException::class.java) {
            RecordingCardWifiProtocol.decode(frame, allowOmittedDataCrc = true)
        }
    }

    @Test
    fun malformedEnvelopeFieldsFailClosed() {
        val valid = RecordingCardWifiProtocol.encode(0x0b, 1, byteArrayOf(9))
        val badHeader = valid.copyOf().also { it[0] = 'Y'.code.toByte() }
        val badTail = valid.copyOf().also { it[it.lastIndex] = 0 }
        val badLength = valid.copyOf().also { it[20] = 0x7f }

        assertThrows(RecordingCardWifiProtocolException::class.java) {
            RecordingCardWifiProtocol.decode(badHeader)
        }
        assertThrows(RecordingCardWifiProtocolException::class.java) {
            RecordingCardWifiProtocol.decode(badTail)
        }
        assertThrows(RecordingCardWifiProtocolException::class.java) {
            RecordingCardWifiProtocol.decode(badLength)
        }
    }

    @Test
    fun pendingInputIsBounded() {
        val decoder = RecordingCardWifiStreamDecoder(
            allowOmittedDataCrc = false,
            maximumPendingBytes = 20,
        )

        assertThrows(RecordingCardWifiProtocolException::class.java) {
            decoder.push(ByteArray(21))
        }
    }

    @Test
    fun sequenceGuardAcceptsBaselineAndWrapButRejectsGapOrDuplicate() {
        RecordingCardWifiSequenceGuard().apply {
            accept(0xfffe)
            accept(0xffff)
            accept(0)
            accept(1)
        }

        assertThrows(RecordingCardWifiProtocolException::class.java) {
            RecordingCardWifiSequenceGuard().apply {
                accept(5)
                accept(7)
            }
        }
        assertThrows(RecordingCardWifiProtocolException::class.java) {
            RecordingCardWifiSequenceGuard().apply {
                accept(5)
                accept(5)
            }
        }
    }

    @Test
    fun oneSessionSequenceGuardSpansFilesAndRebaselinesTailSeek() {
        val sessionGuard = RecordingCardWifiSequenceGuard()

        // Ordinary files share one session baseline. Firmware may restart the
        // sequence for a bounded tail seek, whose first packet rebaselines it.
        listOf(0xfffd, 0xfffe).forEach(sessionGuard::accept)
        sessionGuard.reset()
        listOf(7, 8, 9).forEach(sessionGuard::accept)

        assertThrows(RecordingCardWifiProtocolException::class.java) {
            sessionGuard.accept(11)
        }
    }

    @Test
    fun payloadBudgetRejectsOverrunWithoutAdvancingAcceptedBytes() {
        val budget = RecordingCardWifiPayloadBudget(8)
        budget.accept(5)

        assertThrows(RecordingCardWifiProtocolException::class.java) {
            budget.accept(4)
        }
        assertEquals(5L, budget.acceptedBytes)
        budget.accept(3)
        assertEquals(8L, budget.acceptedBytes)
    }

    @Test
    fun quietStopBoundaryIsRestrictedToExactHealthyFirmwareProfile() {
        fun accepted(
            main: String? = "1.0.6",
            wifi: String? = "1.0.2",
            wrote: Boolean = true,
            healthy: Boolean = true,
            queued: Int = 0,
            pending: Int = 0,
        ): Boolean = RecordingCardWifiCompatibility.acceptsQuietStopBoundary(
            mainFirmware = main,
            wifiFirmware = wifi,
            stopWriteSucceeded = wrote,
            connectionHealthy = healthy,
            queuedPackets = queued,
            pendingBytes = pending,
        )

        assertEquals(true, accepted())
        assertEquals(false, accepted(main = "1.1.0"))
        assertEquals(false, accepted(wifi = "1.0.3"))
        assertEquals(false, accepted(wrote = false))
        assertEquals(false, accepted(healthy = false))
        assertEquals(false, accepted(queued = 1))
        assertEquals(false, accepted(pending = 1))
    }

    @Test
    fun boundaryModeUsesQuietWithoutStopOnlyForVerifiedIntermediateFiles() {
        fun mode(
            verified: Boolean = true,
            fileIndex: Int? = 0,
            fileCount: Int? = 3,
        ): RecordingCardWifiBoundaryMode = recordingCardWifiBoundaryMode(
            allowQuietBoundary = verified,
            fileIndex = fileIndex,
            fileCount = fileCount,
        )

        val first = mode(fileIndex = 0, fileCount = 3)
        val middle = mode(fileIndex = 1, fileCount = 3)
        assertEquals(RecordingCardWifiBoundaryMode.INTER_FILE_QUIET, first)
        assertEquals(RecordingCardWifiBoundaryMode.INTER_FILE_QUIET, middle)
        assertFalse(first.requiresStopRequest)
        assertFalse(middle.requiresStopRequest)

        listOf(
            mode(fileIndex = 2, fileCount = 3),
            mode(fileIndex = 0, fileCount = 1),
            mode(fileIndex = null, fileCount = 3),
            mode(fileIndex = 0, fileCount = null),
            mode(fileIndex = -1, fileCount = 3),
            mode(fileIndex = 3, fileCount = 3),
            mode(fileIndex = 4, fileCount = 3),
            mode(verified = false, fileIndex = 0, fileCount = 3),
        ).forEach { decision ->
            assertEquals(RecordingCardWifiBoundaryMode.REQUEST_STOP, decision)
            assertTrue(decision.requiresStopRequest)
        }
    }

    @Test
    fun earlyEndWaitsForGraceBeforeDeclaringIncomplete() {
        assertEquals(
            RecordingCardWifiEndDecision.COMPLETE,
            recordingCardWifiEndDecision(8_000L, 8_000L, graceExpired = false),
        )
        assertEquals(
            RecordingCardWifiEndDecision.AWAIT_TRAILING_DATA,
            recordingCardWifiEndDecision(7_500L, 8_000L, graceExpired = false),
        )
        assertEquals(
            RecordingCardWifiEndDecision.FAIL_INCOMPLETE,
            recordingCardWifiEndDecision(7_500L, 8_000L, graceExpired = true),
        )
        assertEquals(
            RecordingCardWifiEndDecision.FAIL_INCOMPLETE,
            recordingCardWifiEndDecision(8_001L, 8_000L, graceExpired = false),
        )
    }

    @Test
    fun fileRequestCarriesFourByteBigEndianSeekOffset() {
        val payload = requireNotNull(
            recordingCardFileRequestPayload("REC001.MP3", seekOffset = 0x0102_0304L),
        )

        assertEquals(18, payload.size)
        assertArrayEquals("REC001.MP3".toByteArray(), payload.copyOfRange(0, 10))
        assertTrue(payload.copyOfRange(10, 14).all { it == 0.toByte() })
        assertArrayEquals(
            byteArrayOf(0x01, 0x02, 0x03, 0x04),
            payload.copyOfRange(14, 18),
        )
        assertNull(recordingCardFileRequestPayload("A".repeat(15)))
        assertNull(recordingCardFileRequestPayload("录音.MP3"))
        assertNull(recordingCardFileRequestPayload("REC001.MP3", seekOffset = -1L))
        assertNull(recordingCardFileRequestPayload("REC001.MP3", seekOffset = 0x1_0000_0000L))
    }

    @Test
    fun tailSeekRequiresAcceptedPrefixAndOneVerifiedFinalFrame() {
        assertEquals(
            4_040L,
            recordingCardWifiTailResumeOffset(
                profileAllowed = true,
                receivedBytes = 4_040L,
                targetBytes = 4_924L,
                alreadyAttempted = false,
            ),
        )
        assertEquals(
            6_333_280L,
            recordingCardWifiTailResumeOffset(
                profileAllowed = true,
                receivedBytes = 6_333_280L,
                targetBytes = 6_333_578L,
                alreadyAttempted = false,
            ),
        )
        assertEquals(
            6_333_280L,
            recordingCardWifiTailResumeOffset(true, 6_333_280L, 6_333_281L, false),
        )
        assertEquals(
            4_040L,
            recordingCardWifiTailResumeOffset(true, 4_040L, 8_080L, false),
        )
        assertNull(recordingCardWifiTailResumeOffset(false, 4_040L, 4_924L, false))
        assertNull(recordingCardWifiTailResumeOffset(true, 4_040L, 4_924L, true))
        assertNull(recordingCardWifiTailResumeOffset(true, 0L, 3_000L, false))
        assertNull(recordingCardWifiTailResumeOffset(true, 4_039L, 4_337L, false))
        assertNull(recordingCardWifiTailResumeOffset(true, 100L, 4_100L, false))
        assertNull(recordingCardWifiTailResumeOffset(true, 100L, 4_140L, false))
        assertNull(recordingCardWifiTailResumeOffset(true, 6_333_280L, 6_333_280L, false))
        assertNull(recordingCardWifiTailResumeOffset(true, 6_333_280L, 6_337_321L, false))
        assertNull(
            recordingCardWifiTailResumeOffset(
                true,
                0x1_0000_0000L,
                0x1_0000_0001L,
                false,
            ),
        )
        assertTrue(recordingCardWifiTailPayloadMatches(4_000L, 4_000))
        assertFalse(recordingCardWifiTailPayloadMatches(4_000L, 3_999))
        assertTrue(recordingCardWifiTailPayloadMatches(4_040L, 4_040))
    }

    @Test
    fun wifiRateSamplerUsesQuarterSecondSamplesAndIosEwma() {
        val sampler = RecordingCardWifiRateSampler()
        sampler.reset(nowMs = 1_000L)

        assertNull(sampler.observe(nowMs = 1_249L, receivedBytes = 1_000L))
        assertEquals(4_000.0, requireNotNull(sampler.observe(1_250L, 1_000L)), 0.001)
        assertEquals(5_400.0, requireNotNull(sampler.observe(1_500L, 3_000L)), 0.001)
        assertEquals(1L, sampler.estimatedRemainingSeconds(3_000L, 8_400L))
        assertEquals(2L, sampler.estimatedRemainingSeconds(3_000L, 8_401L))

        sampler.reset(nowMs = 2_000L, receivedBytes = 3_000L)
        assertNull(sampler.bytesPerSecond)
        assertNull(sampler.estimatedRemainingSeconds(3_000L, 8_401L))
    }
}
