package com.hangzhouchuda.huahuoai

import java.nio.charset.StandardCharsets
import java.nio.file.Files
import java.util.UUID
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class RecordingCardBindingProtocolTest {
    private val requested = ByteArray(16) { it.toByte() }
    private val legacy = "HHFW920TEST00010".toByteArray()

    @Test
    fun connectionReuseRequiresRequestedFingerprintAndSerial() {
        assertTrue(recordingCardCanReuseConnection("card-a", "card-a", "SP63A03003", "SP63A03003"))
        assertFalse(recordingCardCanReuseConnection("card-b", "card-a", "SP63A03003", "SP63A03003"))
        assertFalse(recordingCardCanReuseConnection("card-a", "card-a", "SP63A03004", "SP63A03003"))
    }

    @Test
    fun notificationSetupRequiresEveryCurrentAcknowledgementInOrder() {
        val setup = RecordingCardNotificationSetup()
        val control = UUID(0, 1)
        val realtime = UUID(0, 2)
        val offline = UUID(0, 3)
        assertFalse(setup.isComplete)
        assertFalse(setup.acknowledge(control))
        setup.begin(listOf(control, realtime, offline))
        assertEquals(control, setup.next)
        assertFalse(setup.acknowledge(offline))
        assertTrue(setup.acknowledge(control))
        assertFalse(setup.acknowledge(control))
        assertEquals(realtime, setup.next)
        assertFalse(setup.isComplete)
        assertTrue(setup.acknowledge(realtime))
        assertFalse(setup.acknowledge(realtime))
        assertFalse(setup.isComplete)
        assertTrue(setup.acknowledge(offline))
        assertTrue(setup.isComplete)
        assertNull(setup.next)
        assertFalse(setup.acknowledge(offline))
    }

    @Test
    fun notificationSetupResetCannotRetainReadiness() {
        val setup = RecordingCardNotificationSetup()
        val first = UUID(0, 1)
        val retry = UUID(0, 2)
        setup.begin(listOf(first))
        assertTrue(setup.acknowledge(first))
        assertTrue(setup.isComplete)
        setup.reset()
        assertFalse(setup.isComplete)
        assertFalse(setup.acknowledge(first))
        setup.begin(listOf(retry))
        assertFalse(setup.acknowledge(first))
        assertEquals(retry, setup.next)
        assertTrue(setup.acknowledge(retry))
        assertTrue(setup.isComplete)
    }

    @Test
    fun bindingAcknowledgementDistinguishesRejectionFromMalformedReply() {
        assertNull(recordingCardBindingAcknowledgementFailure(byteArrayOf(0)))
        assertEquals(
            "RECORDING_CARD_BINDING_REJECTED",
            recordingCardBindingAcknowledgementFailure(byteArrayOf(1))?.code,
        )
        for (payload in listOf(byteArrayOf(), byteArrayOf(2), byteArrayOf(-1), byteArrayOf(0, 0), byteArrayOf(1, 0))) {
            assertEquals(
                "RECORDING_CARD_BINDING_ACK_MALFORMED",
                recordingCardBindingAcknowledgementFailure(payload)?.code,
            )
        }
    }

    @Test
    fun handshakeGuardAllowsOnlyOneSerialWindowAndClosesItAtDispatch() {
        val handshake = RecordingCardHandshakeGuard()
        assertFalse(handshake.dispatchedBinding(99000L))
        assertTrue(handshake.begin())
        assertFalse(handshake.begin())
        assertNull(handshake.bindingDeadlineMillis)
        handshake.receivedSerial(100000L)
        handshake.receivedSerial(101000L)
        assertEquals(105000L, handshake.bindingDeadlineMillis)
        assertFalse(handshake.bindingWindowExpired(104999L))
        assertTrue(handshake.dispatchedBinding(104999L))
        assertEquals(true, handshake.bindingDispatchMetDeadline)
        assertNull(handshake.bindingDeadlineMillis)
        handshake.receivedSerial(106000L)
        assertNull(handshake.bindingDeadlineMillis)
        assertFalse(handshake.bindingWindowExpired(200000L))
        assertFalse(handshake.dispatchedBinding(200000L))
        assertFalse(handshake.begin())
    }

    @Test
    fun handshakeGuardTreatsDeadlineAsSlaAndResetsForReconnect() {
        val handshake = RecordingCardHandshakeGuard()
        assertTrue(handshake.begin())
        handshake.receivedSerial(100000L)
        assertTrue(handshake.bindingWindowExpired(105000L))
        assertTrue(handshake.dispatchedBinding(105000L))
        assertEquals(false, handshake.bindingDispatchMetDeadline)
        handshake.reset()
        assertFalse(handshake.inProgress)
        assertNull(handshake.bindingDeadlineMillis)
        assertNull(handshake.bindingDispatchMetDeadline)
        handshake.receivedSerial(110000L)
        assertNull(handshake.bindingDeadlineMillis)
        assertTrue(handshake.begin())
        handshake.receivedSerial(120000L)
        assertEquals(125000L, handshake.bindingDeadlineMillis)
        assertTrue(handshake.dispatchedBinding(121000L))
    }

    @Test
    fun bindingInfoReadAllowsExactlyOneHandshakeRetry() {
        assertTrue(
            recordingCardCanRetryBindingInfo(
                handshakeInProgress = true,
                unbindInProgress = false,
                dispatchCount = 1,
            ),
        )
        assertFalse(recordingCardCanRetryBindingInfo(true, false, 0))
        assertFalse(recordingCardCanRetryBindingInfo(true, false, 2))
        assertFalse(recordingCardCanRetryBindingInfo(false, false, 1))
        assertFalse(recordingCardCanRetryBindingInfo(true, true, 1))
    }

    @Test
    fun commandOwnershipIncludesRequestAndTransportGeneration() {
        val current = RecordingCardCommandOwnership(requestId = 12L, transportGeneration = 4L)

        assertEquals(current, RecordingCardCommandOwnership(12L, 4L))
        assertFalse(current == RecordingCardCommandOwnership(13L, 4L))
        assertFalse(current == RecordingCardCommandOwnership(12L, 5L))
    }

    @Test
    fun abandonedDispatchedCommandRetiresOnlyItsCurrentTransport() {
        val current = RecordingCardCommandOwnership(requestId = 12L, transportGeneration = 4L)

        assertTrue(recordingCardAbandonedCommandRequiresTransportRetirement(current, 4L, 1))
        assertFalse(recordingCardAbandonedCommandRequiresTransportRetirement(current, 4L, 0))
        assertFalse(recordingCardAbandonedCommandRequiresTransportRetirement(current, 5L, 1))
    }

    @Test
    fun bleCaptureRejectsDataFromEveryOtherTransportGeneration() {
        assertTrue(recordingCardBleCaptureOwnsTransport(7L, 7L))
        assertFalse(recordingCardBleCaptureOwnsTransport(7L, 8L))
        assertFalse(recordingCardBleCaptureOwnsTransport(null, 8L))
    }

    @Test
    fun bleSilenceBarrierExtendsForOrphanedDataAndRejectsStaleTimers() {
        val barrier = RecordingCardBleSilenceBarrier(quietPeriodMs = 500L)
        val firstGeneration = barrier.begin(nowMs = 1_000L)

        assertEquals(500L, barrier.remainingDelayMs(firstGeneration, 1_000L))
        assertFalse(barrier.completeIfQuiet(firstGeneration, 1_499L))
        assertEquals(firstGeneration, barrier.observeOrphanedData(1_400L))
        assertEquals(500L, barrier.remainingDelayMs(firstGeneration, 1_400L))
        assertFalse(barrier.completeIfQuiet(firstGeneration, 1_899L))
        assertTrue(barrier.completeIfQuiet(firstGeneration, 1_900L))
        assertFalse(barrier.active)

        val secondGeneration = barrier.begin(nowMs = 2_000L)
        assertFalse(barrier.completeIfQuiet(firstGeneration, 2_500L))
        assertTrue(barrier.completeIfQuiet(secondGeneration, 2_500L))
    }

    @Test
    fun firstWifiEnableFailureAlwaysAllowsOneResetRecovery() {
        listOf(
            "RECORDING_CARD_COMMAND_REJECTED",
            "RECORDING_CARD_COMMAND_TIMEOUT",
            "RECORDING_CARD_WRITE_FAILED",
        ).forEach { errorCode ->
            assertTrue(errorCode, recordingCardCanRecoverWifiEnableWithReset(true))
        }
        assertFalse(recordingCardCanRecoverWifiEnableWithReset(false))
    }

    @Test
    fun timedOutWifiEnableKeepsGattOnlyAfterOwnedResetTakesItsSlot() {
        val timedOut = RecordingCardCommandOwnership(requestId = 7L, transportGeneration = 11L)
        val reset = RecordingCardCommandOwnership(requestId = 8L, transportGeneration = 11L)

        assertTrue(
            recordingCardReplacementCommandOwnsTimedOutTransport(
                allowReplacementTakeover = true,
                timedOutOwnership = timedOut,
                replacementOwnership = reset,
                activeTransportGeneration = 11L,
            ),
        )
        assertFalse(
            recordingCardReplacementCommandOwnsTimedOutTransport(
                allowReplacementTakeover = false,
                timedOutOwnership = timedOut,
                replacementOwnership = reset,
                activeTransportGeneration = 11L,
            ),
        )
        assertFalse(
            recordingCardReplacementCommandOwnsTimedOutTransport(
                allowReplacementTakeover = true,
                timedOutOwnership = timedOut,
                replacementOwnership = timedOut,
                activeTransportGeneration = 11L,
            ),
        )
        assertFalse(
            recordingCardReplacementCommandOwnsTimedOutTransport(
                allowReplacementTakeover = true,
                timedOutOwnership = timedOut,
                replacementOwnership = reset.copy(transportGeneration = 12L),
                activeTransportGeneration = 11L,
            ),
        )
        assertFalse(
            recordingCardReplacementCommandOwnsTimedOutTransport(
                allowReplacementTakeover = true,
                timedOutOwnership = timedOut,
                replacementOwnership = null,
                activeTransportGeneration = 11L,
            ),
        )
    }

    @Test
    fun wifiHandoffRequiresOwnedWifiRouteWithoutEndpointProbe() {
        assertTrue(recordingCardWifiHandoffRouteReady(true, true, true))
        assertFalse(recordingCardWifiHandoffRouteReady(false, true, true))
        assertFalse(recordingCardWifiHandoffRouteReady(true, false, true))
        assertFalse(recordingCardWifiHandoffRouteReady(true, true, false))
    }

    @Test
    fun verifiedPartCommitReplacesAtomicallyAndReusesMatchingFinal() {
        val directory = Files.createTempDirectory("recording-card-commit-").toFile()
        try {
            val finalFile = directory.resolve("card-00000000000000000000000000000000.mp3")
            val partFile = directory.resolve("${finalFile.name}.part")
            val fresh = "verified recording bytes".toByteArray()
            finalFile.writeBytes("stale".toByteArray())
            partFile.writeBytes(fresh)
            val contentHash = recordingCardFileSha256(partFile)

            assertFalse(recordingCardCommittedFileMatches(finalFile, fresh.size.toLong(), contentHash))
            assertEquals(
                RecordingCardPrivateFileCommitResult.MOVED,
                recordingCardCommitVerifiedPart(
                    partFile,
                    finalFile,
                    fresh.size.toLong(),
                    contentHash,
                ),
            )
            assertArrayEquals(fresh, finalFile.readBytes())
            assertFalse(partFile.exists())

            partFile.writeBytes(fresh)
            assertEquals(
                RecordingCardPrivateFileCommitResult.REUSED,
                recordingCardCommitVerifiedPart(
                    partFile,
                    finalFile,
                    fresh.size.toLong(),
                    contentHash,
                ),
            )
            assertArrayEquals(fresh, finalFile.readBytes())
            assertFalse(partFile.exists())
        } finally {
            directory.deleteRecursively()
        }
    }

    @Test
    fun verifiedPartCommitRejectsSameLengthHashMismatchBeforeRename() {
        val directory = Files.createTempDirectory("recording-card-hash-mismatch-").toFile()
        try {
            val finalFile = directory.resolve("card-00000000000000000000000000000000.mp3")
            val partFile = directory.resolve("${finalFile.name}.part")
            val expectedFile = directory.resolve("expected.mp3")
            val expected = "verified recording bytes".toByteArray()
            val corrupt = expected.copyOf().also { it[0] = (it[0].toInt() xor 0x01).toByte() }
            val existing = ByteArray(expected.size) { 0x55 }
            expectedFile.writeBytes(expected)
            partFile.writeBytes(corrupt)
            finalFile.writeBytes(existing)

            assertThrows(java.io.IOException::class.java) {
                recordingCardCommitVerifiedPart(
                    partFile,
                    finalFile,
                    expected.size.toLong(),
                    recordingCardFileSha256(expectedFile),
                )
            }
            assertArrayEquals(existing, finalFile.readBytes())
            assertArrayEquals(corrupt, partFile.readBytes())
        } finally {
            directory.deleteRecursively()
        }
    }

    @Test
    fun committedDownloadRecoveryRequiresAnExactPersistedSize() {
        val clean = RecordingCardCommittedDownloadRecoveryDecision.CLEAN_AND_REDOWNLOAD
        val recover = RecordingCardCommittedDownloadRecoveryDecision.RECOVER

        assertEquals(clean, recordingCardCommittedDownloadRecoveryDecision(false, null, 4_096L))
        assertEquals(clean, recordingCardCommittedDownloadRecoveryDecision(true, 4_096L, null))
        assertEquals(clean, recordingCardCommittedDownloadRecoveryDecision(true, 4_095L, 4_096L))
        assertEquals(clean, recordingCardCommittedDownloadRecoveryDecision(true, 0L, 0L))
        assertEquals(recover, recordingCardCommittedDownloadRecoveryDecision(true, 4_096L, 4_096L))
    }

    @Test
    fun controlDecoderAcceptsV1AndV2AcrossSplitAndCoalescedNotifications() {
        val first = recordingCardEncodeControlFrame(0x01, byteArrayOf(1, 2), version = 0x01)
        val second = recordingCardEncodeControlFrame(0x02, byteArrayOf(3), version = 0x02)
        val decoder = RecordingCardControlFrameDecoder()

        val partial = decoder.push(first.copyOfRange(0, 4))
        assertEquals(emptyList<RecordingCardPacket>(), partial.packets)
        assertTrue(requireNotNull(partial.awaitingBytes) > 0)

        val completed = decoder.push(first.copyOfRange(4, first.size) + second)
        assertEquals(listOf(0x01, 0x02), completed.packets.map { it.command })
        assertArrayEquals(byteArrayOf(1, 2), completed.packets[0].payload)
        assertArrayEquals(byteArrayOf(3), completed.packets[1].payload)
        assertEquals(0, completed.bufferedByteCount)
    }

    @Test
    fun controlDecoderResynchronizesBytewiseAfterVersionAndCrcFaults() {
        val unsupported = recordingCardEncodeControlFrame(0x01, byteArrayOf(7), version = 0x03)
        val badCrc = recordingCardEncodeControlFrame(0x02, byteArrayOf(8)).also {
            it[it.lastIndex] = (it.last().toInt() xor 0x01).toByte()
        }
        val valid = recordingCardEncodeControlFrame(0x03, byteArrayOf(9))
        val batch = RecordingCardControlFrameDecoder().push(unsupported + badCrc + valid)

        assertEquals(listOf(0x03), batch.packets.map { it.command })
        assertTrue(batch.issues.contains(RecordingCardControlFrameDecodeIssue.UNSUPPORTED_VERSION))
        assertTrue(batch.issues.contains(RecordingCardControlFrameDecodeIssue.CRC_MISMATCH))
        assertEquals(0, batch.bufferedByteCount)
    }

    @Test
    fun controlDecoderBoundsIncompleteInput() {
        val decoder = RecordingCardControlFrameDecoder(maximumBufferedBytes = 16)
        val incomplete = byteArrayOf(
            0xd2.toByte(),
            0x2d,
            0x01,
            0x02,
            0xff.toByte(),
        ) + ByteArray(20)

        val batch = decoder.push(incomplete)

        assertTrue(batch.issues.contains(RecordingCardControlFrameDecodeIssue.BUFFER_TRIMMED))
        assertEquals(16, batch.bufferedByteCount)
    }

    @Test
    fun recordingClockPreservesEventAnchorsAcrossReadsAndPauses() {
        val clock = RecordingCardRecordingClock()
        clock.observe("recording", "first.m4a", 1000L)
        clock.observe("recording", "first.m4a", 11000L)
        assertEquals(1000L, clock.startedAtMillis)
        clock.observe("paused", "first.m4a", 16000L)
        assertEquals(15L, clock.durationSeconds)
        assertNull(clock.startedAtMillis)
        clock.observe("recording", "first.m4a", 41000L)
        assertEquals(15L, clock.durationSeconds)
        assertEquals(41000L, clock.startedAtMillis)
        clock.observe("paused", "first.m4a", 48000L)
        assertEquals(22L, clock.durationSeconds)
        clock.observe("recording", "second.m4a", 61000L)
        assertEquals(0L, clock.durationSeconds)
        assertEquals(61000L, clock.startedAtMillis)
        clock.observe("idle", null, 81000L)
        assertEquals(0L, clock.durationSeconds)
        assertNull(clock.startedAtMillis)
    }

    @Test
    fun bluetoothPermissionProfilesFollowAndroidPlatformBoundaries() {
        assertEquals(
            RecordingCardBluetoothPermissionProfile.NONE,
            recordingCardBluetoothPermissionProfile(22),
        )
        assertEquals(
            RecordingCardBluetoothPermissionProfile.LEGACY_LOCATION,
            recordingCardBluetoothPermissionProfile(23),
        )
        assertEquals(
            RecordingCardBluetoothPermissionProfile.LEGACY_LOCATION,
            recordingCardBluetoothPermissionProfile(30),
        )
        assertEquals(
            RecordingCardBluetoothPermissionProfile.NEARBY_DEVICES,
            recordingCardBluetoothPermissionProfile(31),
        )
    }

    @Test
    fun bluetoothPermissionStatusDistinguishesFirstUseDenialAndBlocking() {
        assertEquals(
            "granted",
            recordingCardBluetoothPermissionStatus(
                granted = true,
                requestAttempted = false,
                shouldShowRationale = false,
            ),
        )
        assertEquals(
            "not_determined",
            recordingCardBluetoothPermissionStatus(
                granted = false,
                requestAttempted = false,
                shouldShowRationale = false,
            ),
        )
        assertEquals(
            "denied",
            recordingCardBluetoothPermissionStatus(
                granted = false,
                requestAttempted = true,
                shouldShowRationale = true,
            ),
        )
        assertEquals(
            "blocked",
            recordingCardBluetoothPermissionStatus(
                granted = false,
                requestAttempted = true,
                shouldShowRationale = false,
            ),
        )
    }

    @Test
    fun onlyOneInitialTransientGattRetryIsAllowed() {
        assertTrue(recordingCardShouldRetryInitialGattFailure(133, 0))
        assertTrue(recordingCardShouldRetryInitialGattFailure(8, 0))
        assertFalse(recordingCardShouldRetryInitialGattFailure(133, 1))
        assertFalse(recordingCardShouldRetryInitialGattFailure(5, 0))
    }

    @Test
    fun currentAndLegacyBindingsResolveToTheActualDeviceToken() {
        val current = resolveRecordingCardUnbindToken(requested, requested, legacy)
        val historical = resolveRecordingCardUnbindToken(
            legacy + byteArrayOf(0x55),
            requested,
            legacy,
        )

        assertEquals(RecordingCardUnbindTokenStatus.TOKEN, current.status)
        assertArrayEquals(requested, current.token)
        assertEquals(RecordingCardUnbindTokenStatus.TOKEN, historical.status)
        assertArrayEquals(legacy, historical.token)
    }

    @Test
    fun connectBindingAcceptsAllZeroFirmwareShapesAndExistingTokens() {
        assertArrayEquals(
            requested,
            compatibleRecordingCardBindingToken(byteArrayOf(0), requested, legacy),
        )
        assertArrayEquals(
            requested,
            compatibleRecordingCardBindingToken(ByteArray(16), requested, legacy),
        )
        assertArrayEquals(
            requested,
            compatibleRecordingCardBindingToken(requested, requested, legacy),
        )
        assertArrayEquals(
            legacy,
            compatibleRecordingCardBindingToken(legacy, requested, legacy),
        )
        assertNull(compatibleRecordingCardBindingToken(byteArrayOf(), requested, legacy))
        assertNull(compatibleRecordingCardBindingToken(byteArrayOf(1), requested, legacy))
        assertArrayEquals(
            ByteArray(16) { 0x7f },
            compatibleRecordingCardBindingToken(
                ByteArray(16) { 0x7f },
                requested,
                legacy,
            ),
        )
    }

    @Test
    fun oneByteZeroIsAlreadyUnboundWhileMalformedAndConflictFailClosed() {
        assertEquals(
            RecordingCardUnbindTokenStatus.ALREADY_UNBOUND,
            resolveRecordingCardUnbindToken(byteArrayOf(0), requested, legacy).status,
        )
        assertEquals(
            RecordingCardUnbindTokenStatus.MALFORMED,
            resolveRecordingCardUnbindToken(byteArrayOf(), requested, legacy).status,
        )
        assertEquals(
            RecordingCardUnbindTokenStatus.MALFORMED,
            resolveRecordingCardUnbindToken(byteArrayOf(1), requested, legacy).status,
        )
        assertEquals(
            RecordingCardUnbindTokenStatus.CONFLICT,
            resolveRecordingCardUnbindToken(ByteArray(16) { 0x7f }, requested, legacy).status,
        )
    }

    @Test
    fun unbindPayloadAndAcknowledgementAreStrict() {
        assertArrayEquals(
            ByteArray(17),
            recordingCardUnbindPayload(false),
        )
        assertArrayEquals(
            ByteArray(16).plus(byteArrayOf(0x01)),
            recordingCardUnbindPayload(true),
        )
        assertTrue(recordingCardUnbindAckAccepted(byteArrayOf(0)))
        assertTrue(recordingCardUnbindAckAccepted(byteArrayOf(0, 2)))
        assertFalse(recordingCardUnbindAckAccepted(byteArrayOf()))
        assertFalse(recordingCardUnbindAckAccepted(byteArrayOf(1)))
    }

    @Test
    fun unbindDisconnectCompletesOnlyAfterCommandDispatch() {
        assertTrue(recordingCardUnbindDisconnectCompletesOperation(true, true))
        assertFalse(recordingCardUnbindDisconnectCompletesOperation(true, false))
        assertFalse(recordingCardUnbindDisconnectCompletesOperation(false, true))
    }

    @Test
    fun forceScanAlwaysBypassesCachedDevice() {
        assertTrue(recordingCardShouldReuseCachedDevice(false, true))
        assertFalse(recordingCardShouldReuseCachedDevice(true, true))
        assertFalse(recordingCardShouldReuseCachedDevice(false, false))
    }

    @Test
    fun android6Through11RequireLegacyLocationForBleDiscovery() {
        assertFalse(recordingCardBleRequiresLegacyLocation(22))
        assertTrue(recordingCardBleRequiresLegacyLocation(23))
        assertTrue(recordingCardBleRequiresLegacyLocation(30))
        assertFalse(recordingCardBleRequiresLegacyLocation(31))
    }

    @Test
    fun manufacturerQualifiedDiscoverySeparatesCandidateAndCompleteIdentity() {
        val validPayload = ByteArray(RECORDING_CARD_MANUFACTURER_MAC_BYTES) +
            "SP63A03003".toByteArray()

        assertEquals(0x375c, RECORDING_CARD_MANUFACTURER_COMPANY_ID)
        assertTrue(
            recordingCardHasCompatibleManufacturerData(
                RECORDING_CARD_MANUFACTURER_COMPANY_ID,
                validPayload,
            ),
        )
        assertFalse(recordingCardHasCompatibleManufacturerData(0x5c37, validPayload))
        assertFalse(recordingCardHasCompatibleManufacturerData(0x004c, validPayload))
        assertTrue(
            recordingCardHasCompatibleManufacturerData(
                RECORDING_CARD_MANUFACTURER_COMPANY_ID,
                ByteArray(RECORDING_CARD_MANUFACTURER_MINIMUM_PAYLOAD_BYTES),
            ),
        )
        assertEquals(7, RECORDING_CARD_MANUFACTURER_MINIMUM_PAYLOAD_BYTES)
        assertEquals(6, RECORDING_CARD_MANUFACTURER_MINIMUM_SERIAL_BYTES)
        assertEquals(64, RECORDING_CARD_MANUFACTURER_MAXIMUM_SERIAL_BYTES)
        assertFalse(
            recordingCardHasCompatibleManufacturerData(
                RECORDING_CARD_MANUFACTURER_COMPANY_ID,
                null,
            ),
        )
        assertEquals(
            "SP63A03003",
            recordingCardManufacturerSerialNumber(
                RECORDING_CARD_MANUFACTURER_COMPANY_ID,
                validPayload,
            ),
        )
        val paddedSerial = ByteArray(RECORDING_CARD_MANUFACTURER_MAC_BYTES + 10)
        "SN1234".toByteArray().copyInto(
            paddedSerial,
            destinationOffset = RECORDING_CARD_MANUFACTURER_MAC_BYTES,
        )
        assertEquals(
            "SN1234",
            recordingCardManufacturerSerialNumber(
                RECORDING_CARD_MANUFACTURER_COMPANY_ID,
                paddedSerial,
            ),
        )
        assertNull(
            recordingCardManufacturerSerialNumber(
                RECORDING_CARD_MANUFACTURER_COMPANY_ID,
                ByteArray(RECORDING_CARD_MANUFACTURER_MINIMUM_PAYLOAD_BYTES),
            ),
        )
        assertNull(
            recordingCardManufacturerSerialNumber(
                RECORDING_CARD_MANUFACTURER_COMPANY_ID,
                ByteArray(RECORDING_CARD_MANUFACTURER_MAC_BYTES) +
                    "SN123".toByteArray(),
            ),
        )
        assertEquals(
            "SP63A030043",
            recordingCardManufacturerSerialNumber(
                RECORDING_CARD_MANUFACTURER_COMPANY_ID,
                ByteArray(RECORDING_CARD_MANUFACTURER_MAC_BYTES) +
                    "SP63A030043".toByteArray(),
            ),
        )
        assertEquals(
            "A".repeat(64),
            recordingCardManufacturerSerialNumber(
                RECORDING_CARD_MANUFACTURER_COMPANY_ID,
                ByteArray(RECORDING_CARD_MANUFACTURER_MAC_BYTES) +
                    "A".repeat(64).toByteArray(),
            ),
        )
        assertNull(
            recordingCardManufacturerSerialNumber(
                RECORDING_CARD_MANUFACTURER_COMPANY_ID,
                ByteArray(RECORDING_CARD_MANUFACTURER_MAC_BYTES) +
                    "A".repeat(65).toByteArray(),
            ),
        )
        val unsafeSerial = validPayload.copyOf().also {
            it[RECORDING_CARD_MANUFACTURER_MAC_BYTES + 2] = '\n'.code.toByte()
        }
        assertNull(
            recordingCardManufacturerSerialNumber(
                RECORDING_CARD_MANUFACTURER_COMPANY_ID,
                unsafeSerial,
            ),
        )
        assertNull(
            recordingCardManufacturerSerialNumber(
                RECORDING_CARD_MANUFACTURER_COMPANY_ID,
                ByteArray(RECORDING_CARD_MANUFACTURER_MAC_BYTES) +
                    "SN_123".toByteArray(),
            ),
        )
        assertFalse(
            recordingCardHasCompatibleManufacturerData(
                RECORDING_CARD_MANUFACTURER_COMPANY_ID,
                ByteArray(RECORDING_CARD_MANUFACTURER_MINIMUM_PAYLOAD_BYTES - 1),
            ),
        )

        val diagnostic = recordingCardManufacturerAdvertisementDiagnostic(
            RECORDING_CARD_MANUFACTURER_COMPANY_ID,
            validPayload,
        )
        assertEquals(
            "manufacturer eligibility=eligible identity=selectable payloadLength=16",
            diagnostic,
        )
        assertFalse(diagnostic.contains("SP63A03003"))
    }

    @Test
    fun repeatedDiscoveryMergesRicherFieldsWithoutPublishingRssiOnlyChanges() {
        val initial = recordingCardMergedDiscoveredRow(
            current = null,
            advertisedName = null,
            fallbackName = "FW920",
            defaultName = "Huahuo Recording Card",
            fingerprint = "android-card-test",
            rssi = -70,
            isConnectable = false,
            serialNumber = null,
            lastSeenAt = "first",
        )
        assertTrue(recordingCardDiscoveryRowHasMeaningfulChange(null, initial))
        assertEquals("FW920", initial["displayName"])
        assertNull(initial["serialNumber"])
        assertEquals(false, initial["isConnectable"])

        val enriched = recordingCardMergedDiscoveredRow(
            current = initial,
            advertisedName = "会议录音卡",
            fallbackName = "FW920",
            defaultName = "Huahuo Recording Card",
            fingerprint = "android-card-test",
            rssi = -58,
            isConnectable = true,
            serialNumber = "SP63A03003",
            lastSeenAt = "second",
        )
        assertTrue(recordingCardDiscoveryRowHasMeaningfulChange(initial, enriched))
        assertEquals("会议录音卡", enriched["displayName"])
        assertEquals("SP63A03003", enriched["serialNumber"])

        val sparse = recordingCardMergedDiscoveredRow(
            current = enriched,
            advertisedName = null,
            fallbackName = "stale-system-name",
            defaultName = "Huahuo Recording Card",
            fingerprint = "android-card-test",
            rssi = 127,
            isConnectable = false,
            serialNumber = null,
            lastSeenAt = "third",
        )
        assertTrue(recordingCardDiscoveryRowHasMeaningfulChange(enriched, sparse))
        assertEquals("会议录音卡", sparse["displayName"])
        assertEquals("SP63A03003", sparse["serialNumber"])
        assertEquals(false, sparse["isConnectable"])
        assertEquals(-58, sparse["rssi"])
        assertEquals("third", sparse["lastSeenAt"])

        val recovered = recordingCardMergedDiscoveredRow(
            current = sparse,
            advertisedName = null,
            fallbackName = null,
            defaultName = "Huahuo Recording Card",
            fingerprint = "android-card-test",
            rssi = 127,
            isConnectable = true,
            serialNumber = null,
            lastSeenAt = "fourth",
        )
        assertTrue(recordingCardDiscoveryRowHasMeaningfulChange(sparse, recovered))
        assertEquals(true, recovered["isConnectable"])

        val signalOnly = recordingCardMergedDiscoveredRow(
            current = recovered,
            advertisedName = null,
            fallbackName = null,
            defaultName = "Huahuo Recording Card",
            fingerprint = "android-card-test",
            rssi = -49,
            isConnectable = true,
            serialNumber = null,
            lastSeenAt = "fifth",
        )
        assertFalse(recordingCardDiscoveryRowHasMeaningfulChange(recovered, signalOnly))
        assertEquals(-49, signalOnly["rssi"])
        assertEquals("fifth", signalOnly["lastSeenAt"])
    }

    @Test
    fun discoveryRowRequiresValidatedIdentityAndTransportConnectability() {
        assertFalse(recordingCardDiscoveryRowIsConnectable(false, true))
        assertFalse(recordingCardDiscoveryRowIsConnectable(true, false))
        assertTrue(recordingCardDiscoveryRowIsConnectable(true, null))
        assertTrue(recordingCardDiscoveryRowIsConnectable(true, true))
    }

    @Test
    fun provisionalCandidateOnlyConnectsForAnAlreadyAuthorizedSelection() {
        assertFalse(
            recordingCardDiscoveryCanStartConnection(
                hasPendingConnect = false,
                requestedFingerprint = null,
                observedFingerprint = "android-card-test",
                requestedExpectedSerialNumber = null,
                observedSerialNumber = "SP63A03003",
            ),
        )
        assertFalse(
            recordingCardDiscoveryCanStartConnection(
                hasPendingConnect = true,
                requestedFingerprint = null,
                observedFingerprint = "android-card-test",
                requestedExpectedSerialNumber = null,
                observedSerialNumber = null,
            ),
        )
        assertTrue(
            recordingCardDiscoveryCanStartConnection(
                hasPendingConnect = true,
                requestedFingerprint = "android-card-test",
                observedFingerprint = "android-card-test",
                requestedExpectedSerialNumber = "SP63A03003",
                observedSerialNumber = null,
            ),
        )
        assertFalse(
            recordingCardDiscoveryCanStartConnection(
                hasPendingConnect = true,
                requestedFingerprint = "another-card",
                observedFingerprint = "android-card-test",
                requestedExpectedSerialNumber = "SP63A03003",
                observedSerialNumber = "SP63A03003",
            ),
        )
    }

    @Test
    fun expectedSerialUsesAccountNormalizationBeforeFirmwareBinding() {
        assertTrue(recordingCardSerialMatchesExpected("sp63-a03003", "SP63A03003"))
        assertTrue(recordingCardSerialMatchesExpected(null, "SP63A03003"))
        assertFalse(recordingCardSerialMatchesExpected("SP63A03003", "SP63A03004"))
        assertFalse(recordingCardSerialMatchesExpected("bad_sn", "bad_sn"))
    }

    @Test
    fun gattCallbackOwnershipUsesObjectIdentity() {
        val active = Any()
        val replacement = Any()

        assertTrue(recordingCardOwnsGattCallback(active, active))
        assertFalse(recordingCardOwnsGattCallback(active, replacement))
        assertFalse(recordingCardOwnsGattCallback(null, active))
    }

    @Test
    fun gattLossAfterConnectionSettlesTheActiveSession() {
        assertEquals(
            RecordingCardGattDisconnectDisposition.CONNECTION_SETUP_FAILED,
            recordingCardGattDisconnectDisposition(
                hasPendingConnect = true,
                wifiBleDisconnectExpected = false,
                wifiSessionActive = false,
            ),
        )
        assertEquals(
            RecordingCardGattDisconnectDisposition.ACTIVE_SESSION_INTERRUPTED,
            recordingCardGattDisconnectDisposition(
                hasPendingConnect = false,
                wifiBleDisconnectExpected = false,
                wifiSessionActive = false,
            ),
        )
        assertEquals(
            RecordingCardGattDisconnectDisposition.EXPECTED_WIFI_HANDOFF,
            recordingCardGattDisconnectDisposition(
                hasPendingConnect = false,
                wifiBleDisconnectExpected = true,
                wifiSessionActive = false,
            ),
        )
    }

    @Test
    fun expectedGattLossPreservesOnlyACompletedWifiHandoff() {
        assertTrue(
            recordingCardPreservesPreparedWifiHandoff(
                preserveRequested = true,
                handoffReady = true,
                preparationInFlight = false,
            ),
        )
        assertFalse(
            recordingCardPreservesPreparedWifiHandoff(
                preserveRequested = false,
                handoffReady = true,
                preparationInFlight = false,
            ),
        )
        assertFalse(
            recordingCardPreservesPreparedWifiHandoff(
                preserveRequested = true,
                handoffReady = false,
                preparationInFlight = false,
            ),
        )
        assertFalse(
            recordingCardPreservesPreparedWifiHandoff(
                preserveRequested = true,
                handoffReady = true,
                preparationInFlight = true,
            ),
        )
    }

    @Test
    fun wifiCredentialLeaseBelongsToCurrentGattTransportAndCard() {
        assertTrue(
            recordingCardWifiCredentialLeaseIsReusable(
                observedTransportGeneration = 9L,
                currentTransportGeneration = 9L,
                observedFingerprint = "card-a",
                currentFingerprint = "card-a",
            ),
        )
        assertFalse(
            recordingCardWifiCredentialLeaseIsReusable(
                observedTransportGeneration = 8L,
                currentTransportGeneration = 9L,
                observedFingerprint = "card-a",
                currentFingerprint = "card-a",
            ),
        )
        assertFalse(
            recordingCardWifiCredentialLeaseIsReusable(
                observedTransportGeneration = 9L,
                currentTransportGeneration = 9L,
                observedFingerprint = "card-b",
                currentFingerprint = "card-a",
            ),
        )
    }

    @Test
    fun wifiPreparationFailureDisablesAcknowledgedOrPossiblyEnabledWritableHotspot() {
        assertTrue(
            recordingCardWifiShouldDisableHotspot(
                hotspotEnableAcknowledged = true,
                hotspotEnableMayHaveBeenDispatched = false,
                handoffReady = false,
                bleWritable = true,
            ),
        )
        assertTrue(
            recordingCardWifiShouldDisableHotspot(
                hotspotEnableAcknowledged = false,
                hotspotEnableMayHaveBeenDispatched = true,
                handoffReady = false,
                bleWritable = true,
            ),
        )
        assertFalse(
            recordingCardWifiShouldDisableHotspot(
                hotspotEnableAcknowledged = true,
                hotspotEnableMayHaveBeenDispatched = false,
                handoffReady = false,
                bleWritable = false,
            ),
        )
        assertFalse(
            recordingCardWifiShouldDisableHotspot(
                hotspotEnableAcknowledged = false,
                hotspotEnableMayHaveBeenDispatched = false,
                handoffReady = false,
                bleWritable = true,
            ),
        )
        assertFalse(
            recordingCardWifiShouldDisableHotspot(
                hotspotEnableAcknowledged = true,
                hotspotEnableMayHaveBeenDispatched = true,
                handoffReady = true,
                bleWritable = true,
            ),
        )
        assertTrue(
            recordingCardWifiShouldDisableHotspot(
                hotspotEnableAcknowledged = false,
                hotspotEnableMayHaveBeenDispatched = false,
                handoffReady = true,
                bleWritable = true,
                terminalShutdownRequested = true,
            ),
        )
        assertFalse(
            recordingCardWifiShouldDisableHotspot(
                hotspotEnableAcknowledged = false,
                hotspotEnableMayHaveBeenDispatched = false,
                handoffReady = true,
                bleWritable = false,
                terminalShutdownRequested = true,
            ),
        )
    }

    @Test
    fun wifiHotspotDisableBarrierRequiresCommandAndMinimumDelayAndCanBeForced() {
        val barrier = RecordingCardWifiHotspotDisableBarrier()
        val firstGeneration = barrier.begin()

        assertTrue(barrier.active)
        assertThrows(IllegalStateException::class.java) { barrier.begin() }
        assertFalse(barrier.settleCommand(firstGeneration + 1L))
        assertTrue(barrier.active)
        assertFalse(barrier.settleCommand(firstGeneration))
        assertTrue(barrier.active)
        assertFalse(barrier.elapseMinimumDelay(firstGeneration + 1L))
        assertTrue(barrier.active)
        assertTrue(barrier.elapseMinimumDelay(firstGeneration))
        assertFalse(barrier.active)
        assertFalse(barrier.settleCommand(firstGeneration))

        val secondGeneration = barrier.begin()
        assertFalse(barrier.elapseMinimumDelay(firstGeneration))
        assertTrue(barrier.active)
        assertFalse(barrier.elapseMinimumDelay(secondGeneration))
        assertTrue(barrier.active)
        assertTrue(barrier.settleCommand(secondGeneration))
        assertFalse(barrier.active)

        val thirdGeneration = barrier.begin()
        assertFalse(barrier.settleCommand(thirdGeneration))
        assertTrue(barrier.forceSettle())
        assertFalse(barrier.active)
        assertFalse(barrier.forceSettle())
        assertTrue(thirdGeneration != secondGeneration)
    }

    @Test
    fun wifiCredentialReceptionRejectsLateAttemptButAcceptsActivePreparation() {
        assertFalse(
            recordingCardShouldAcceptWifiCredentials(
                preparationInFlight = false,
                unsolicitedGateOpen = false,
            ),
        )
        assertTrue(
            recordingCardShouldAcceptWifiCredentials(
                preparationInFlight = true,
                unsolicitedGateOpen = false,
            ),
        )
        assertTrue(
            recordingCardShouldAcceptWifiCredentials(
                preparationInFlight = false,
                unsolicitedGateOpen = true,
            ),
        )
    }

    @Test
    fun wifiAttemptCannotReplaceAnyRetainedHandoffOwner() {
        fun canBegin(
            attemptOwned: Boolean = false,
            preparationInFlight: Boolean = false,
            hotspotDisableInFlight: Boolean = false,
            joinInFlight: Boolean = false,
            joinCallbackRetained: Boolean = false,
            joinNetworkRetained: Boolean = false,
            sessionRetained: Boolean = false,
            bleDisconnectExpected: Boolean = false,
            handoffReady: Boolean = false,
        ): Boolean = recordingCardWifiAttemptCanBegin(
            attemptOwned = attemptOwned,
            preparationInFlight = preparationInFlight,
            hotspotDisableInFlight = hotspotDisableInFlight,
            joinInFlight = joinInFlight,
            joinCallbackRetained = joinCallbackRetained,
            joinNetworkRetained = joinNetworkRetained,
            sessionRetained = sessionRetained,
            bleDisconnectExpected = bleDisconnectExpected,
            handoffReady = handoffReady,
        )

        assertTrue(canBegin())
        assertFalse(canBegin(attemptOwned = true))
        assertFalse(canBegin(preparationInFlight = true))
        assertFalse(canBegin(hotspotDisableInFlight = true))
        assertFalse(canBegin(joinInFlight = true))
        assertFalse(canBegin(joinCallbackRetained = true))
        assertFalse(canBegin(joinNetworkRetained = true))
        assertFalse(canBegin(sessionRetained = true))
        assertFalse(canBegin(bleDisconnectExpected = true))
        assertFalse(canBegin(handoffReady = true))

        assertTrue(
            recordingCardWifiAttemptIsActive(
                attemptOwned = true,
                preparationInFlight = false,
                hotspotDisableInFlight = false,
                joinInFlight = false,
                joinCallbackRetained = false,
                joinNetworkRetained = false,
                sessionActive = false,
                bleDisconnectExpected = false,
                handoffReady = false,
            ),
        )
        assertTrue(
            recordingCardWifiAttemptIsActive(
                attemptOwned = false,
                preparationInFlight = false,
                hotspotDisableInFlight = false,
                joinInFlight = false,
                joinCallbackRetained = true,
                joinNetworkRetained = true,
                sessionActive = false,
                bleDisconnectExpected = false,
                handoffReady = false,
            ),
        )
    }

    @Test
    fun wifiRecoverySettlementRequiresExactBoundedIdentityFields() {
        assertTrue(
            recordingCardWifiRecoverySettlementIsValid(
                batchId = "batch-a",
                attemptId = "attempt_a-1",
                safeDeviceFingerprint = "card-fingerprint-a",
            ),
        )
        assertFalse(
            recordingCardWifiRecoverySettlementIsValid(
                batchId = "",
                attemptId = "attempt-a",
                safeDeviceFingerprint = "card-a",
            ),
        )
        assertFalse(
            recordingCardWifiRecoverySettlementIsValid(
                batchId = "batch-a",
                attemptId = "attempt.with.dot",
                safeDeviceFingerprint = "card-a",
            ),
        )
        assertFalse(
            recordingCardWifiRecoverySettlementIsValid(
                batchId = "batch-a",
                attemptId = "attempt-a",
                safeDeviceFingerprint = "",
            ),
        )
        assertFalse(
            recordingCardWifiRecoverySettlementIsValid(
                batchId = "b".repeat(161),
                attemptId = "attempt-a",
                safeDeviceFingerprint = "card-a",
            ),
        )
        assertFalse(
            recordingCardWifiRecoverySettlementIsValid(
                batchId = "batch-a",
                attemptId = "a".repeat(129),
                safeDeviceFingerprint = "card-a",
            ),
        )
        assertFalse(
            recordingCardWifiRecoverySettlementIsValid(
                batchId = "batch-a",
                attemptId = "attempt-a",
                safeDeviceFingerprint = "f".repeat(161),
            ),
        )
    }

    @Test
    fun legacyPreparedWifiHandoffKeepsUnbindBusyWithoutScopedAttempt() {
        fun ownsTransport(
            joinInFlight: Boolean = false,
            joinCallbackRetained: Boolean = false,
            joinNetworkRetained: Boolean = false,
            bleDisconnectExpected: Boolean = false,
            handoffReady: Boolean = false,
        ): Boolean = recordingCardWifiOperationOwnsTransport(
            attemptOwned = false,
            preparationInFlight = false,
            hotspotDisableInFlight = false,
            joinInFlight = joinInFlight,
            joinCallbackRetained = joinCallbackRetained,
            joinNetworkRetained = joinNetworkRetained,
            sessionRetained = false,
            bleDisconnectExpected = bleDisconnectExpected,
            handoffReady = handoffReady,
        )

        assertFalse(ownsTransport())
        assertTrue(
            ownsTransport(
                bleDisconnectExpected = true,
                handoffReady = true,
            ),
        )
        assertTrue(ownsTransport(joinInFlight = true))
        assertTrue(ownsTransport(joinCallbackRetained = true))
        assertTrue(ownsTransport(joinNetworkRetained = true))
    }

    @Test
    fun wifiFailureCleanupRetainsHotspotFactsOnlyForAnOwnedAttempt() {
        assertFalse(recordingCardLegacyWifiOperationCanBegin(scopedAttemptOwned = true))
        assertTrue(recordingCardLegacyWifiOperationCanBegin(scopedAttemptOwned = false))
        assertTrue(
            recordingCardWifiCleanupRetainsHotspotFacts(
                RecordingCardWifiSessionCleanupMode.FAILURE_AWAITING_ATTEMPT_TEARDOWN,
                attemptOwned = true,
            ),
        )
        assertFalse(
            recordingCardWifiCleanupRetainsHotspotFacts(
                RecordingCardWifiSessionCleanupMode.FAILURE_AWAITING_ATTEMPT_TEARDOWN,
                attemptOwned = false,
            ),
        )
        assertFalse(
            recordingCardWifiCleanupRetainsHotspotFacts(
                RecordingCardWifiSessionCleanupMode.TERMINAL,
                attemptOwned = true,
            ),
        )
    }

    @Test
    fun forceScanWaitsForTheActiveTransportToDisconnect() {
        assertEquals(
            RecordingCardForceScanTransportAction.DISCONNECT_AND_WAIT,
            recordingCardForceScanTransportAction(hasActiveGatt = true),
        )
        assertEquals(
            RecordingCardForceScanTransportAction.START_SCAN,
            recordingCardForceScanTransportAction(hasActiveGatt = false),
        )
    }

    @Test
    fun gattSetupWaitsForMtuCallbackBeforeServiceDiscovery() {
        assertEquals(
            RecordingCardGattSetupAction.WAIT_FOR_MTU_CALLBACK,
            recordingCardGattSetupAction(true),
        )
        assertEquals(
            RecordingCardGattSetupAction.FAIL_MTU_REQUEST,
            recordingCardGattSetupAction(false),
        )
    }

    @Test
    fun connectionDeadlineDistinguishesSearchFromPostLinkSetup() {
        assertEquals(
            "RECORDING_CARD_NOT_FOUND",
            recordingCardConnectionDeadlineErrorCode("searching"),
        )
        assertEquals(
            "RECORDING_CARD_SETUP_TIMEOUT",
            recordingCardConnectionDeadlineErrorCode("connecting"),
        )
        assertEquals(
            "RECORDING_CARD_SETUP_TIMEOUT",
            recordingCardConnectionDeadlineErrorCode("connected"),
        )
    }

    @Test
    fun connectionDeadlineUsesTheSameBoundsAsIos() {
        assertEquals(
            RECORDING_CARD_DEFAULT_CONNECT_TIMEOUT_MS,
            recordingCardConnectTimeoutMillis(null),
        )
        assertEquals(
            RECORDING_CARD_MIN_CONNECT_TIMEOUT_MS,
            recordingCardConnectTimeoutMillis(1),
        )
        assertEquals(12_345L, recordingCardConnectTimeoutMillis(12_345))
        assertEquals(
            RECORDING_CARD_MAX_CONNECT_TIMEOUT_MS,
            recordingCardConnectTimeoutMillis(120_000),
        )
    }

    @Test
    fun bluetoothNamePayloadIsStrictlyBoundedAndZeroPadded() {
        val bluetoothName = "无限花火"
        val nameBytes = bluetoothName.toByteArray()
        val payload = requireNotNull(recordingCardBluetoothNamePayload(bluetoothName))

        assertEquals(RECORDING_CARD_BLUETOOTH_NAME_BYTES, payload.size)
        assertArrayEquals(nameBytes, payload.copyOfRange(0, nameBytes.size))
        assertTrue(
            payload
                .copyOfRange(nameBytes.size, RECORDING_CARD_BLUETOOTH_NAME_BYTES)
                .all { it == 0.toByte() },
        )
        assertEquals(null, recordingCardBluetoothNamePayload(null))
        assertEquals(null, recordingCardBluetoothNamePayload(""))
        assertEquals(null, recordingCardBluetoothNamePayload("name\u0000suffix"))
        assertEquals(null, recordingCardBluetoothNamePayload("name\nnext"))
        assertEquals(null, recordingCardBluetoothNamePayload("中".repeat(11)))
        assertEquals(
            RECORDING_CARD_BLUETOOTH_NAME_BYTES,
            recordingCardBluetoothNamePayload("A".repeat(32))?.size,
        )
    }

    @Test
    fun bluetoothNameResponseRequiresTheExactDocumentedStatusByte() {
        assertEquals(
            RecordingCardBluetoothNameResponse.SUCCESS,
            recordingCardBluetoothNameResponse(byteArrayOf(0)),
        )
        assertEquals(
            RecordingCardBluetoothNameResponse.REJECTED,
            recordingCardBluetoothNameResponse(byteArrayOf(1)),
        )
        assertEquals(
            RecordingCardBluetoothNameResponse.INVALID,
            recordingCardBluetoothNameResponse(byteArrayOf()),
        )
        assertEquals(
            RecordingCardBluetoothNameResponse.INVALID,
            recordingCardBluetoothNameResponse(byteArrayOf(2)),
        )
        assertEquals(
            RecordingCardBluetoothNameResponse.INVALID,
            recordingCardBluetoothNameResponse(byteArrayOf(0, 0)),
        )
    }

    @Test
    fun accountClaimIsDeterministicAndRejectsUnsafeSerialPayloads() {
        val serial = "FW920-20260724-0001".toByteArray()
        val padded = byteArrayOf(0) + serial + byteArrayOf(0, 0, 0x20)

        assertEquals(
            "55f58e97debb944edf4c9b6d38d8359ebfd6e046d9eb2ec9145527e7883865c3",
            recordingCardOpaqueAccountClaim(serial),
        )
        assertEquals(
            recordingCardOpaqueAccountClaim(serial),
            recordingCardOpaqueAccountClaim(padded),
        )
        assertNull(recordingCardOpaqueAccountClaim(byteArrayOf()))
        assertNull(recordingCardOpaqueAccountClaim("short".toByteArray()))
        assertNull(
            recordingCardOpaqueAccountClaim(
                "FW920\nUNSAFE".toByteArray(),
            ),
        )
        assertNull(recordingCardOpaqueAccountClaim(ByteArray(65) { 'A'.code.toByte() }))
    }

    @Test
    fun recordingStateMappingsRemainCommandSpecificAndFailClosed() {
        assertEquals("idle", recordingCardStateFromDeviceInfo(0x00))
        assertEquals("recording", recordingCardStateFromDeviceInfo(0x01))
        assertEquals("paused", recordingCardStateFromDeviceInfo(0x02))
        assertNull(recordingCardStateFromDeviceInfo(0x7f))
        assertNull(recordingCardStateFromDeviceInfo(null))

        assertEquals("recording", recordingCardStateFromRecordingInfo(0x00))
        assertEquals("idle", recordingCardStateFromRecordingInfo(0x01))
        assertEquals("paused", recordingCardStateFromRecordingInfo(0x02))
        assertNull(recordingCardStateFromRecordingInfo(0x7f))
        assertNull(recordingCardStateFromRecordingInfo(null))
    }

    @Test
    fun unsolicitedPhysicalControlsPublishOnlyAcceptedNonPendingStates() {
        assertEquals(
            "recording",
            recordingCardUnsolicitedRecordingState(0x06, byteArrayOf(0x00), false),
        )
        assertEquals(
            "paused",
            recordingCardUnsolicitedRecordingState(0x08, byteArrayOf(0x00), false),
        )
        assertEquals(
            "recording",
            recordingCardUnsolicitedRecordingState(0x09, byteArrayOf(0x00), false),
        )
        assertEquals(
            "idle",
            recordingCardUnsolicitedRecordingState(0x07, byteArrayOf(0x00), false),
        )
        assertNull(
            recordingCardUnsolicitedRecordingState(0x06, byteArrayOf(0x00), true),
        )
        assertNull(
            recordingCardUnsolicitedRecordingState(0x07, byteArrayOf(0x01), false),
        )
        assertNull(recordingCardUnsolicitedRecordingState(0x08, byteArrayOf(), false))
    }

    @Test
    fun recordingInfoKeepsFilenameSizeAndTypeInSeparateFixedFields() {
        val filename = "25090512000001".toByteArray(StandardCharsets.US_ASCII)
        val payload = byteArrayOf(0x00) + filename +
            byteArrayOf(0x00, 0x00, 0x10, 0x00, 0x01)

        val parsed = recordingCardRecordingInfoPayload(payload)

        assertEquals("recording", parsed?.state)
        assertEquals("25090512000001", parsed?.fileName)
        assertEquals(4_096L, parsed?.sizeBytes)
        assertEquals(1, parsed?.recordingType)
        assertNull(parsed?.needsSync)
    }

    @Test
    fun recordingCommandPayloadSeparatesStopMetadataAndAllowsCompactAck() {
        val filename = "REC001.WAV".toByteArray(StandardCharsets.US_ASCII) + ByteArray(4)
        val stopPayload = byteArrayOf(0x00) + filename +
            byteArrayOf(0x00, 0x01, 0x00, 0x00, 0x02, 0x01)

        val stopped = recordingCardRecordingCommandPayload(0x07, stopPayload)
        val compactStart = recordingCardRecordingCommandPayload(0x06, byteArrayOf(0x00))

        assertEquals("idle", stopped?.state)
        assertEquals("REC001.WAV", stopped?.fileName)
        assertEquals(65_536L, stopped?.sizeBytes)
        assertEquals(2, stopped?.recordingType)
        assertEquals(true, stopped?.needsSync)
        assertEquals("recording", compactStart?.state)
        assertNull(compactStart?.fileName)
        assertNull(compactStart?.sizeBytes)
        assertNull(recordingCardRecordingCommandPayload(0x06, byteArrayOf(0x01)))
    }

    @Test
    fun deviceStatusNotificationNeverClaimsRecordingStateDirectly() {
        assertNull(
            recordingCardUnsolicitedRecordingState(
                0x0f,
                byteArrayOf(0x00, 0x64),
                false,
            ),
        )
        assertNull(
            recordingCardUnsolicitedRecordingState(
                0x0f,
                ByteArray(20).also { it[1] = 69.toByte() },
                false,
            ),
        )
    }
}
