package com.hangzhouchuda.huahuoai

import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothProfile
import android.bluetooth.BluetoothStatusCodes
import android.bluetooth.le.BluetoothLeScanner
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanResult
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ApplicationInfo
import android.location.LocationManager
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.wifi.WifiNetworkSpecifier
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Socket
import java.net.SocketTimeoutException
import java.nio.charset.StandardCharsets
import java.nio.file.AtomicMoveNotSupportedException
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.security.MessageDigest
import java.util.ArrayDeque
import java.util.UUID

internal data class RecordingCardCommandOwnership(
    val requestId: Long,
    val transportGeneration: Long,
)

internal fun recordingCardAbandonedCommandRequiresTransportRetirement(
    ownership: RecordingCardCommandOwnership,
    activeTransportGeneration: Long,
    dispatchCount: Int,
): Boolean = dispatchCount > 0 && ownership.transportGeneration == activeTransportGeneration

internal fun recordingCardBleCaptureOwnsTransport(
    captureTransportGeneration: Long?,
    activeTransportGeneration: Long,
): Boolean = captureTransportGeneration != null &&
    captureTransportGeneration == activeTransportGeneration

internal class RecordingCardBleSilenceBarrier(
    private val quietPeriodMs: Long,
) {
    private var quietDeadlineMs: Long? = null

    var generation: Long = 0L
        private set

    val active: Boolean
        get() = quietDeadlineMs != null

    init {
        require(quietPeriodMs > 0L)
    }

    fun begin(nowMs: Long): Long {
        generation += 1L
        if (generation == 0L) generation += 1L
        quietDeadlineMs = deadlineAfter(nowMs)
        return generation
    }

    fun observeOrphanedData(nowMs: Long): Long? {
        if (!active) return null
        quietDeadlineMs = deadlineAfter(nowMs)
        return generation
    }

    fun remainingDelayMs(expectedGeneration: Long, nowMs: Long): Long? {
        if (expectedGeneration != generation) return null
        val deadline = quietDeadlineMs ?: return null
        return (deadline - nowMs).coerceAtLeast(0L)
    }

    fun completeIfQuiet(expectedGeneration: Long, nowMs: Long): Boolean {
        val remaining = remainingDelayMs(expectedGeneration, nowMs) ?: return false
        if (remaining > 0L) return false
        quietDeadlineMs = null
        return true
    }

    private fun deadlineAfter(nowMs: Long): Long =
        if (nowMs > Long.MAX_VALUE - quietPeriodMs) Long.MAX_VALUE else nowMs + quietPeriodMs
}

internal fun recordingCardCanRecoverWifiEnableWithReset(
    allowResetRecovery: Boolean,
): Boolean = allowResetRecovery

internal fun recordingCardReplacementCommandOwnsTimedOutTransport(
    allowReplacementTakeover: Boolean,
    timedOutOwnership: RecordingCardCommandOwnership,
    replacementOwnership: RecordingCardCommandOwnership?,
    activeTransportGeneration: Long,
): Boolean = allowReplacementTakeover &&
    timedOutOwnership.transportGeneration == activeTransportGeneration &&
    replacementOwnership != null &&
    replacementOwnership != timedOutOwnership &&
    replacementOwnership.transportGeneration == activeTransportGeneration

internal fun recordingCardWifiHandoffRouteReady(
    ownsRequestedNetwork: Boolean,
    hasWifiTransport: Boolean,
    routesRecorderEndpoint: Boolean,
): Boolean = ownsRequestedNetwork && hasWifiTransport && routesRecorderEndpoint

internal enum class RecordingCardPrivateFileCommitResult {
    MOVED,
    REUSED,
}

internal fun recordingCardFileSha256(file: File): String {
    val digest = MessageDigest.getInstance("SHA-256")
    file.inputStream().use { stream ->
        val buffer = ByteArray(64 * 1024)
        while (true) {
            val count = stream.read(buffer)
            if (count < 0) break
            if (count > 0) digest.update(buffer, 0, count)
        }
    }
    return digest.digest().joinToString("") { byte ->
        "%02x".format(byte.toInt() and 0xff)
    }
}

internal fun recordingCardCommittedFileMatches(
    file: File,
    expectedSize: Long,
    expectedContentHash: String,
): Boolean = file.isFile && file.length() == expectedSize &&
    runCatching { recordingCardFileSha256(file) == expectedContentHash }.getOrDefault(false)

internal fun recordingCardCommitVerifiedPart(
    partFile: File,
    finalFile: File,
    expectedSize: Long,
    expectedContentHash: String,
): RecordingCardPrivateFileCommitResult {
    val partParent = partFile.parentFile?.canonicalFile
    val finalParent = finalFile.parentFile?.canonicalFile
    if (partParent == null || partParent != finalParent ||
        partFile.name != "${finalFile.name}.part" || !partFile.isFile ||
        partFile.length() != expectedSize || expectedSize <= 0L ||
        !Regex("^[a-f0-9]{64}$").matches(expectedContentHash)
    ) {
        throw IOException("recording-card private file commit precondition failed")
    }
    if (runCatching {
            recordingCardFileSha256(partFile) == expectedContentHash
        }.getOrDefault(false).not()
    ) {
        throw IOException("recording-card private file commit hash mismatch")
    }
    if (recordingCardCommittedFileMatches(finalFile, expectedSize, expectedContentHash)) {
        if (!partFile.delete()) {
            throw IOException("recording-card idempotent part cleanup failed")
        }
        return RecordingCardPrivateFileCommitResult.REUSED
    }

    try {
        Files.move(
            partFile.toPath(),
            finalFile.toPath(),
            StandardCopyOption.ATOMIC_MOVE,
            StandardCopyOption.REPLACE_EXISTING,
        )
    } catch (_: AtomicMoveNotSupportedException) {
        Files.move(
            partFile.toPath(),
            finalFile.toPath(),
            StandardCopyOption.REPLACE_EXISTING,
        )
    } catch (_: UnsupportedOperationException) {
        Files.move(
            partFile.toPath(),
            finalFile.toPath(),
            StandardCopyOption.REPLACE_EXISTING,
        )
    }
    if (!finalFile.isFile || finalFile.length() != expectedSize) {
        throw IOException("recording-card private file commit verification failed")
    }
    return RecordingCardPrivateFileCommitResult.MOVED
}

internal enum class RecordingCardCommittedDownloadRecoveryDecision {
    RECOVER,
    CLEAN_AND_REDOWNLOAD,
}

internal fun recordingCardCommittedDownloadRecoveryDecision(
    finalFileExists: Boolean,
    finalFileSize: Long?,
    expectedSize: Long?,
): RecordingCardCommittedDownloadRecoveryDecision =
    if (finalFileExists && finalFileSize != null && finalFileSize > 0L &&
        expectedSize != null && expectedSize > 0L && finalFileSize == expectedSize
    ) {
        RecordingCardCommittedDownloadRecoveryDecision.RECOVER
    } else {
        RecordingCardCommittedDownloadRecoveryDecision.CLEAN_AND_REDOWNLOAD
    }

internal fun recordingCardCanRetryBindingInfo(
    handshakeInProgress: Boolean,
    unbindInProgress: Boolean,
    dispatchCount: Int,
): Boolean = handshakeInProgress && !unbindInProgress && dispatchCount == 1

internal data class RecordingCardPacket(
    val command: Int,
    val payload: ByteArray,
)

internal enum class RecordingCardControlFrameDecodeIssue {
    DISCARDED_NOISE,
    UNSUPPORTED_VERSION,
    CRC_MISMATCH,
    BUFFER_TRIMMED;

    val requestsBindingInfoRetry: Boolean
        get() = this != DISCARDED_NOISE
}

internal data class RecordingCardControlFrameDecodeBatch(
    val packets: List<RecordingCardPacket>,
    val issues: List<RecordingCardControlFrameDecodeIssue>,
    val awaitingBytes: Int?,
    val bufferedByteCount: Int,
)

internal class RecordingCardControlFrameDecoder(
    private val maximumBufferedBytes: Int = 1024,
) {
    private val buffer = mutableListOf<Byte>()

    init {
        require(maximumBufferedBytes >= 7)
    }

    fun reset() {
        buffer.clear()
    }

    fun push(value: ByteArray): RecordingCardControlFrameDecodeBatch {
        buffer.addAll(value.toList())
        val packets = mutableListOf<RecordingCardPacket>()
        val issues = mutableListOf<RecordingCardControlFrameDecodeIssue>()
        while (buffer.size >= 2) {
            val header = findHeader()
            if (header < 0) {
                if (buffer.size > 1) {
                    val possibleHeader = buffer.last()
                    buffer.clear()
                    buffer.add(possibleHeader)
                    issues += RecordingCardControlFrameDecodeIssue.DISCARDED_NOISE
                }
                break
            }
            if (header > 0) {
                repeat(header) { buffer.removeAt(0) }
                issues += RecordingCardControlFrameDecodeIssue.DISCARDED_NOISE
            }
            if (buffer.size < 5) break
            val version = buffer[2].toInt() and 0xff
            if (version != 0x01 && version != 0x02) {
                buffer.removeAt(0)
                issues += RecordingCardControlFrameDecodeIssue.UNSUPPORTED_VERSION
                continue
            }
            val length = buffer[4].toInt() and 0xff
            val frameLength = 5 + length + 2
            if (buffer.size < frameLength) break
            val frame = buffer.take(frameLength).toByteArray()
            val payloadEnd = 5 + length
            val expectedCrc = (frame[payloadEnd].toInt() and 0xff) or
                ((frame[payloadEnd + 1].toInt() and 0xff) shl 8)
            if (expectedCrc != recordingCardControlCrc16(frame, payloadEnd)) {
                buffer.removeAt(0)
                issues += RecordingCardControlFrameDecodeIssue.CRC_MISMATCH
                continue
            }
            repeat(frameLength) { buffer.removeAt(0) }
            packets += RecordingCardPacket(
                command = frame[3].toInt() and 0xff,
                payload = frame.copyOfRange(5, payloadEnd),
            )
        }
        if (buffer.size > maximumBufferedBytes) {
            val retained = buffer.takeLast(maximumBufferedBytes)
            buffer.clear()
            buffer.addAll(retained)
            issues += RecordingCardControlFrameDecodeIssue.BUFFER_TRIMMED
        }
        return RecordingCardControlFrameDecodeBatch(
            packets = packets,
            issues = issues,
            awaitingBytes = awaitingByteCount(),
            bufferedByteCount = buffer.size,
        )
    }

    private fun findHeader(): Int {
        for (index in 0 until buffer.size - 1) {
            if ((buffer[index].toInt() and 0xff) == 0xd2 &&
                (buffer[index + 1].toInt() and 0xff) == 0x2d
            ) {
                return index
            }
        }
        return -1
    }

    private fun awaitingByteCount(): Int? {
        if (buffer.size == 1) return if ((buffer[0].toInt() and 0xff) == 0xd2) 1 else null
        if (buffer.size < 2 || (buffer[0].toInt() and 0xff) != 0xd2 ||
            (buffer[1].toInt() and 0xff) != 0x2d
        ) return null
        if (buffer.size < 5) return 5 - buffer.size
        val version = buffer[2].toInt() and 0xff
        if (version != 0x01 && version != 0x02) return null
        val frameLength = 5 + (buffer[4].toInt() and 0xff) + 2
        return if (buffer.size < frameLength) frameLength - buffer.size else null
    }
}

internal fun recordingCardEncodeControlFrame(
    command: Int,
    payload: ByteArray,
    version: Int = 0x02,
): ByteArray {
    require(command in 0..0xff)
    require(version in 0..0xff)
    require(payload.size <= 0xff)
    val body = byteArrayOf(
        0xd2.toByte(),
        0x2d,
        version.toByte(),
        command.toByte(),
        payload.size.toByte(),
    ) + payload
    val crc = recordingCardControlCrc16(body, body.size)
    return body + byteArrayOf((crc and 0xff).toByte(), ((crc ushr 8) and 0xff).toByte())
}

private fun recordingCardControlCrc16(bytes: ByteArray, length: Int): Int {
    var crc = 0
    for (index in 0 until length) {
        crc = crc xor (bytes[index].toInt() and 0xff)
        repeat(8) {
            crc = if (crc and 1 == 1) (crc ushr 1) xor 0xa001 else crc ushr 1
        }
    }
    return crc and 0xffff
}

internal class RecordingCardHandshakeGuard {
    var inProgress = false
        private set
    var bindingDeadlineMillis: Long? = null
        private set
    var bindingDispatchMetDeadline: Boolean? = null
        private set
    private var serialReceived = false

    fun begin(): Boolean {
        if (inProgress) return false
        inProgress = true
        bindingDeadlineMillis = null
        bindingDispatchMetDeadline = null
        return true
    }

    fun receivedSerial(uptimeMillis: Long) {
        if (!inProgress || serialReceived) return
        serialReceived = true
        bindingDeadlineMillis = uptimeMillis + 5000L
    }

    fun bindingWindowExpired(uptimeMillis: Long): Boolean =
        bindingDeadlineMillis?.let { uptimeMillis >= it } ?: false

    fun dispatchedBinding(uptimeMillis: Long): Boolean {
        val deadline = bindingDeadlineMillis
        if (!inProgress || deadline == null) return false
        bindingDispatchMetDeadline = uptimeMillis < deadline
        bindingDeadlineMillis = null
        return true
    }

    fun reset() {
        inProgress = false
        bindingDeadlineMillis = null
        bindingDispatchMetDeadline = null
        serialReceived = false
    }
}

internal class RecordingCardHandshakeFailure(
    val code: String,
    val safeMessage: String,
) : Exception(safeMessage)

internal class RecordingCardNotificationSetup {
    private var required = emptyList<UUID>()
    private var completedCount = 0
    val next: UUID? get() = required.getOrNull(completedCount)
    val isComplete: Boolean get() = required.isNotEmpty() && next == null

    fun begin(characteristics: List<UUID>) {
        required = characteristics.toList()
        completedCount = 0
    }

    fun acknowledge(characteristic: UUID): Boolean {
        if (next != characteristic) return false
        completedCount += 1
        return true
    }

    fun reset() {
        required = emptyList()
        completedCount = 0
    }
}

internal fun recordingCardBindingAcknowledgementFailure(payload: ByteArray): RecordingCardHandshakeFailure? {
    if (payload.size == 1 && payload[0].toInt() == 0) return null
    return if (payload.size == 1 && payload[0].toInt() == 1) {
        RecordingCardHandshakeFailure(
            "RECORDING_CARD_BINDING_REJECTED",
            "Recording-card rejected this pairing request.",
        )
    } else {
        RecordingCardHandshakeFailure(
            "RECORDING_CARD_BINDING_ACK_MALFORMED",
            "Recording-card binding acknowledgement was malformed.",
        )
    }
}

internal enum class RecordingCardUnbindTokenStatus {
    TOKEN,
    ALREADY_UNBOUND,
    MALFORMED,
    CONFLICT,
}

internal data class RecordingCardUnbindTokenResolution(
    val status: RecordingCardUnbindTokenStatus,
    val token: ByteArray? = null,
)

internal fun resolveRecordingCardUnbindToken(
    existingPayload: ByteArray?,
    requestedToken: ByteArray,
    legacyToken: ByteArray,
): RecordingCardUnbindTokenResolution {
    val payload = existingPayload
    if (requestedToken.size != 16 ||
        legacyToken.size != 16 ||
        payload == null ||
        payload.isEmpty()
    ) {
        return RecordingCardUnbindTokenResolution(RecordingCardUnbindTokenStatus.MALFORMED)
    }
    if (payload.all { it.toInt() == 0 }) {
        return RecordingCardUnbindTokenResolution(RecordingCardUnbindTokenStatus.ALREADY_UNBOUND)
    }
    if (payload.size < 16) {
        return RecordingCardUnbindTokenResolution(RecordingCardUnbindTokenStatus.MALFORMED)
    }
    val actualToken = payload.copyOfRange(0, 16)
    if (actualToken.contentEquals(requestedToken) || actualToken.contentEquals(legacyToken)) {
        return RecordingCardUnbindTokenResolution(
            RecordingCardUnbindTokenStatus.TOKEN,
            actualToken,
        )
    }
    return RecordingCardUnbindTokenResolution(RecordingCardUnbindTokenStatus.CONFLICT)
}

internal fun recordingCardUnbindPayload(deleteDeviceFiles: Boolean): ByteArray =
    ByteArray(16).plus(byteArrayOf(if (deleteDeviceFiles) 0x01 else 0x00))

internal fun recordingCardUnbindAckAccepted(payload: ByteArray): Boolean =
    payload.firstOrNull()?.toInt()?.and(0xff) == 0

internal fun recordingCardUnbindDisconnectCompletesOperation(
    unbindInProgress: Boolean,
    commandDispatched: Boolean,
): Boolean = unbindInProgress && commandDispatched

internal fun compatibleRecordingCardBindingToken(
    existingPayload: ByteArray,
    requestedToken: ByteArray,
    legacyToken: ByteArray,
): ByteArray? {
    if (requestedToken.size != 16 || legacyToken.size != 16 || existingPayload.isEmpty()) {
        return null
    }
    if (existingPayload.all { it.toInt() == 0 }) return requestedToken
    if (existingPayload.size < 16) return null
    return existingPayload.copyOfRange(0, 16)
}

internal fun recordingCardSerialNumber(serialPayload: ByteArray): String? {
    var start = if (serialPayload.size > 1 && serialPayload.first().toInt() == 0) 1 else 0
    var end = serialPayload.size
    while (end > start &&
        (serialPayload[end - 1].toInt() == 0 || serialPayload[end - 1].toInt() == 0x20)
    ) {
        end--
    }
    if (end - start !in 6..64) return null
    val serial = serialPayload.copyOfRange(start, end)
    val valid = serial.all { byte ->
        val value = byte.toInt() and 0xff
        value in 'A'.code..'Z'.code ||
            value in 'a'.code..'z'.code ||
            value in '0'.code..'9'.code ||
            value == '.'.code || value == '_'.code ||
            value == ':'.code || value == '-'.code
    }
    if (!valid) return null
    return String(serial, StandardCharsets.UTF_8)
}

internal fun recordingCardNormalizedOwnershipSerial(value: String): String? {
    val normalized = StringBuilder()
    value.trim().forEach { character ->
        when {
            character in 'a'..'z' -> normalized.append(character.uppercaseChar())
            character in 'A'..'Z' || character in '0'..'9' -> normalized.append(character)
            character == '-' || character == ':' || character == ' ' || character == '\t' -> Unit
            else -> return null
        }
    }
    return normalized.toString().takeIf { it.length in 6..64 }
}

internal fun recordingCardSerialMatchesExpected(expected: String?, actual: String?): Boolean {
    if (expected == null) return true
    val expectedNormalized = recordingCardNormalizedOwnershipSerial(expected) ?: return false
    val actualNormalized = actual?.let(::recordingCardNormalizedOwnershipSerial) ?: return false
    return expectedNormalized == actualNormalized
}

internal fun recordingCardOpaqueAccountClaim(serialPayload: ByteArray): String? {
    val serial = recordingCardSerialNumber(serialPayload)?.toByteArray(StandardCharsets.UTF_8)
        ?: return null
    val digest = MessageDigest.getInstance("SHA-256")
    digest.update("huahuo-fw920-account-binding-v1:".toByteArray(StandardCharsets.UTF_8))
    return digest.digest(serial).joinToString("") { byte ->
        "%02x".format(byte.toInt() and 0xff)
    }
}

internal fun recordingCardCanReuseConnection(
    requestedFingerprint: String?,
    activeFingerprint: String?,
    expectedSerial: String?,
    actualSerial: String?,
): Boolean =
    (requestedFingerprint == null || requestedFingerprint == activeFingerprint) &&
        recordingCardSerialMatchesExpected(expectedSerial, actualSerial)

internal fun recordingCardShouldReuseCachedDevice(
    forceScan: Boolean,
    hasCachedDevice: Boolean,
): Boolean =
    !forceScan && hasCachedDevice

internal enum class RecordingCardForceScanTransportAction {
    START_SCAN,
    DISCONNECT_AND_WAIT,
}

internal fun recordingCardForceScanTransportAction(
    hasActiveGatt: Boolean,
): RecordingCardForceScanTransportAction =
    if (hasActiveGatt) {
        RecordingCardForceScanTransportAction.DISCONNECT_AND_WAIT
    } else {
        RecordingCardForceScanTransportAction.START_SCAN
    }

internal fun recordingCardStateFromDeviceInfo(value: Int?): String? = when (value) {
    0x00 -> "idle"
    0x01 -> "recording"
    0x02 -> "paused"
    else -> null
}

internal fun recordingCardStateFromRecordingInfo(value: Int?): String? = when (value) {
    0x00 -> "recording"
    0x01 -> "idle"
    0x02 -> "paused"
    else -> null
}

internal class RecordingCardRecordingClock {
    var state = "idle"
        private set
    var fileName: String? = null
        private set
    var startedAtMillis: Long? = null
        private set
    private var accumulatedMillis = 0L
    val durationSeconds: Long get() = accumulatedMillis.coerceAtLeast(0L) / 1000L

    fun observe(next: String, nextFileName: String?, atMillis: Long) {
        val changedFile = nextFileName != null && fileName != null && nextFileName != fileName
        when (next) {
            "idle" -> {
                accumulatedMillis = 0L
                startedAtMillis = null
                fileName = null
            }
            "recording" -> {
                if (state != "recording" || changedFile) {
                    if (state != "paused" || changedFile) accumulatedMillis = 0L
                    startedAtMillis = atMillis
                }
                fileName = nextFileName ?: fileName
            }
            "paused" -> {
                val started = startedAtMillis
                if (changedFile || state == "idle") {
                    accumulatedMillis = 0L
                } else if (state == "recording" && started != null) {
                    accumulatedMillis += (atMillis - started).coerceAtLeast(0L)
                }
                startedAtMillis = null
                fileName = nextFileName ?: fileName
            }
            else -> return
        }
        state = next
    }
}

internal data class RecordingCardRecordingPayload(
    val state: String,
    val fileName: String? = null,
    val sizeBytes: Long? = null,
    val recordingType: Int? = null,
    val needsSync: Boolean? = null,
)

private fun recordingCardProtocolFilename(payload: ByteArray, offset: Int): String? {
    val fieldEnd = offset + 14
    if (offset < 0 || payload.size < fieldEnd) return null
    val field = payload.copyOfRange(offset, fieldEnd)
    var start = 0
    var end = field.size
    while (start < end && (field[start].toInt() == 0 || field[start].toInt() == 0x20)) start++
    while (end > start && (field[end - 1].toInt() == 0 || field[end - 1].toInt() == 0x20)) end--
    if (start == end) return null
    val nameBytes = field.copyOfRange(start, end)
    val valid = nameBytes.all { byte ->
        val value = byte.toInt() and 0xff
        value in 'A'.code..'Z'.code ||
            value in 'a'.code..'z'.code ||
            value in '0'.code..'9'.code ||
            value == '.'.code || value == '_'.code || value == '-'.code
    }
    if (!valid) return null
    return String(nameBytes, StandardCharsets.US_ASCII).takeUnless { it.endsWith(".part") }
}

private fun recordingCardProtocolUInt32(payload: ByteArray, offset: Int): Long? {
    if (offset < 0 || payload.size < offset + 4) return null
    return ((payload[offset].toLong() and 0xff) shl 24) or
        ((payload[offset + 1].toLong() and 0xff) shl 16) or
        ((payload[offset + 2].toLong() and 0xff) shl 8) or
        (payload[offset + 3].toLong() and 0xff)
}

internal fun recordingCardRecordingInfoPayload(
    payload: ByteArray,
): RecordingCardRecordingPayload? {
    val state = recordingCardStateFromRecordingInfo(
        payload.firstOrNull()?.toInt()?.and(0xff),
    ) ?: return null
    if (state == "idle") return RecordingCardRecordingPayload(state = state)
    return RecordingCardRecordingPayload(
        state = state,
        fileName = recordingCardProtocolFilename(payload, 1),
        sizeBytes = recordingCardProtocolUInt32(payload, 15),
        recordingType = payload.getOrNull(19)?.toInt()?.and(0xff),
    )
}

internal fun recordingCardRecordingCommandPayload(
    command: Int,
    payload: ByteArray,
): RecordingCardRecordingPayload? {
    if (payload.firstOrNull()?.toInt()?.and(0xff) != 0x00) return null
    val state = when (command) {
        0x06, 0x09 -> "recording"
        0x08 -> "paused"
        0x07 -> "idle"
        else -> return null
    }
    val isStop = command == 0x07
    return RecordingCardRecordingPayload(
        state = state,
        fileName = recordingCardProtocolFilename(payload, 1),
        sizeBytes = if (isStop) recordingCardProtocolUInt32(payload, 15) else null,
        recordingType = payload.getOrNull(if (isStop) 19 else 15)?.toInt()?.and(0xff),
        needsSync = if (isStop) payload.getOrNull(20)?.toInt()?.and(0xff)?.let { it != 0 } else null,
    )
}

internal fun recordingCardUnsolicitedRecordingState(
    command: Int,
    payload: ByteArray,
    hasPendingCommand: Boolean,
): String? {
    if (hasPendingCommand) return null
    return recordingCardRecordingCommandPayload(command, payload)?.state
}

internal fun resolveRecordingCardDeviceFileSize(
    littleEndianSize: Long,
    bigEndianSize: Long,
): Pair<Long, String>? {
    val bigEndianIsValid = bigEndianSize > 0L && bigEndianSize <= 1024L * 1024L * 1024L
    return if (bigEndianIsValid) bigEndianSize to "trusted" else null
}

internal enum class RecordingCardWifiStatusOnlyResponse {
    ACCEPTED,
    REJECTED,
    INCOMPLETE,
    NOT_STATUS,
}

internal fun recordingCardWifiStatusOnlyResponse(
    payload: ByteArray,
): RecordingCardWifiStatusOnlyResponse {
    if (payload.size != 1) return RecordingCardWifiStatusOnlyResponse.NOT_STATUS
    return when (payload[0].toInt() and 0xff) {
        0x00 -> RecordingCardWifiStatusOnlyResponse.ACCEPTED
        0x01 -> RecordingCardWifiStatusOnlyResponse.REJECTED
        0x02 -> RecordingCardWifiStatusOnlyResponse.INCOMPLETE
        else -> RecordingCardWifiStatusOnlyResponse.NOT_STATUS
    }
}

// ScanRecord decodes the on-air little-endian bytes `5c 37` into key 0x375c.
internal const val RECORDING_CARD_MANUFACTURER_COMPANY_ID = 0x375c
internal const val RECORDING_CARD_MANUFACTURER_MAC_BYTES = 6
internal const val RECORDING_CARD_MANUFACTURER_MINIMUM_PAYLOAD_BYTES =
    RECORDING_CARD_MANUFACTURER_MAC_BYTES + 1
internal const val RECORDING_CARD_MANUFACTURER_MINIMUM_SERIAL_BYTES = 6
internal const val RECORDING_CARD_MANUFACTURER_MAXIMUM_SERIAL_BYTES = 64
internal const val RECORDING_CARD_BLUETOOTH_NAME_BYTES = 32
internal const val RECORDING_CARD_DEFAULT_CONNECT_TIMEOUT_MS = 15_000L
internal const val RECORDING_CARD_MIN_CONNECT_TIMEOUT_MS = 3_000L
internal const val RECORDING_CARD_MAX_CONNECT_TIMEOUT_MS = 60_000L

internal fun recordingCardHasCompatibleManufacturerData(
    companyId: Int,
    payload: ByteArray?,
): Boolean {
    return companyId == RECORDING_CARD_MANUFACTURER_COMPANY_ID &&
        payload != null &&
        payload.size >= RECORDING_CARD_MANUFACTURER_MINIMUM_PAYLOAD_BYTES
}

internal fun recordingCardManufacturerSerialNumber(
    companyId: Int,
    payload: ByteArray?,
): String? {
    if (companyId != RECORDING_CARD_MANUFACTURER_COMPANY_ID ||
        payload == null ||
        payload.size < RECORDING_CARD_MANUFACTURER_MINIMUM_PAYLOAD_BYTES
    ) {
        return null
    }
    var end = payload.size
    while (end > RECORDING_CARD_MANUFACTURER_MAC_BYTES &&
        (payload[end - 1].toInt() == 0 || payload[end - 1].toInt() == 0x20)
    ) {
        end--
    }
    val serialLength = end - RECORDING_CARD_MANUFACTURER_MAC_BYTES
    if (serialLength !in
        RECORDING_CARD_MANUFACTURER_MINIMUM_SERIAL_BYTES..RECORDING_CARD_MANUFACTURER_MAXIMUM_SERIAL_BYTES
    ) {
        return null
    }
    val serial = payload.copyOfRange(RECORDING_CARD_MANUFACTURER_MAC_BYTES, end)
    fun isAlphaNumeric(value: Int): Boolean =
        value in 'A'.code..'Z'.code ||
            value in 'a'.code..'z'.code ||
            value in '0'.code..'9'.code

    val first = serial.first().toInt() and 0xff
    val valid = serial.all { byte ->
        val value = byte.toInt() and 0xff
        isAlphaNumeric(value) || value == ':'.code || value == '-'.code
    }
    if (!isAlphaNumeric(first) || !valid) return null
    return String(serial, StandardCharsets.US_ASCII).takeIf {
        recordingCardNormalizedOwnershipSerial(it) != null
    }
}

internal fun recordingCardManufacturerAdvertisementDiagnostic(
    companyId: Int,
    payload: ByteArray?,
): String {
    val eligibility = when {
        payload == null -> "missing"
        companyId != RECORDING_CARD_MANUFACTURER_COMPANY_ID -> "companyIdMismatch"
        payload.size < RECORDING_CARD_MANUFACTURER_MINIMUM_PAYLOAD_BYTES -> "tooShort"
        else -> "eligible"
    }
    val identity = if (recordingCardManufacturerSerialNumber(companyId, payload) == null) {
        "provisional"
    } else {
        "selectable"
    }
    return "manufacturer eligibility=$eligibility identity=$identity payloadLength=${payload?.size ?: 0}"
}

internal fun recordingCardMergedDiscoveredRow(
    current: Map<String, Any>?,
    advertisedName: String?,
    fallbackName: String?,
    defaultName: String,
    fingerprint: String,
    rssi: Int,
    isConnectable: Boolean,
    serialNumber: String?,
    lastSeenAt: String,
): Map<String, Any> {
    fun nonBlank(value: String?): String? = value?.takeIf { it.isNotBlank() }

    val row = current?.toMutableMap() ?: linkedMapOf()
    row["displayName"] = nonBlank(advertisedName)
        ?: nonBlank(current?.get("displayName") as? String)
        ?: nonBlank(fallbackName)
        ?: defaultName
    row["safeDeviceFingerprint"] = fingerprint
    if (rssi in -127..40) {
        row["rssi"] = rssi
    }
    row["isConnectable"] = isConnectable
    row["lastSeenAt"] = lastSeenAt
    if (row["serialNumber"] !is String && serialNumber != null) {
        row["serialNumber"] = serialNumber
    }
    return row
}

internal fun recordingCardDiscoveryRowIsConnectable(
    hasValidatedIdentity: Boolean,
    transportConnectable: Boolean?,
): Boolean = hasValidatedIdentity && transportConnectable != false

internal fun recordingCardDiscoveryRowHasMeaningfulChange(
    current: Map<String, Any>?,
    next: Map<String, Any>,
): Boolean {
    if (current == null) return true
    return listOf(
        "displayName",
        "safeDeviceFingerprint",
        "isConnectable",
        "serialNumber",
    ).any { key -> current[key] != next[key] }
}

internal fun recordingCardDiscoveryCanStartConnection(
    hasPendingConnect: Boolean,
    requestedFingerprint: String?,
    observedFingerprint: String,
    requestedExpectedSerialNumber: String?,
    observedSerialNumber: String?,
): Boolean {
    if (!hasPendingConnect) return false
    if (requestedFingerprint != null && requestedFingerprint != observedFingerprint) {
        return false
    }
    return observedSerialNumber != null ||
        (requestedFingerprint != null && requestedExpectedSerialNumber != null)
}

internal fun recordingCardOwnsGattCallback(activeGatt: Any?, callbackGatt: Any?): Boolean =
    activeGatt === callbackGatt

internal enum class RecordingCardGattDisconnectDisposition {
    EXPECTED_WIFI_HANDOFF,
    CONNECTION_SETUP_FAILED,
    ACTIVE_SESSION_INTERRUPTED,
}

internal fun recordingCardGattDisconnectDisposition(
    hasPendingConnect: Boolean,
    wifiBleDisconnectExpected: Boolean,
    wifiSessionActive: Boolean,
): RecordingCardGattDisconnectDisposition = when {
    wifiBleDisconnectExpected || wifiSessionActive ->
        RecordingCardGattDisconnectDisposition.EXPECTED_WIFI_HANDOFF
    hasPendingConnect -> RecordingCardGattDisconnectDisposition.CONNECTION_SETUP_FAILED
    else -> RecordingCardGattDisconnectDisposition.ACTIVE_SESSION_INTERRUPTED
}

internal fun recordingCardPreservesPreparedWifiHandoff(
    preserveRequested: Boolean,
    handoffReady: Boolean,
    preparationInFlight: Boolean,
): Boolean = preserveRequested && handoffReady && !preparationInFlight

internal fun recordingCardWifiCredentialLeaseIsReusable(
    observedTransportGeneration: Long?,
    currentTransportGeneration: Long,
    observedFingerprint: String?,
    currentFingerprint: String?,
): Boolean = observedTransportGeneration == currentTransportGeneration &&
    !observedFingerprint.isNullOrBlank() &&
    observedFingerprint == currentFingerprint

internal fun recordingCardWifiShouldDisableHotspot(
    hotspotEnableAcknowledged: Boolean,
    hotspotEnableMayHaveBeenDispatched: Boolean,
    handoffReady: Boolean,
    bleWritable: Boolean,
    terminalShutdownRequested: Boolean = false,
): Boolean {
    val hotspotMayBeEnabled = hotspotEnableAcknowledged ||
        hotspotEnableMayHaveBeenDispatched || handoffReady
    return hotspotMayBeEnabled && bleWritable &&
        (!handoffReady || terminalShutdownRequested)
}

internal class RecordingCardWifiHotspotDisableBarrier {
    private var generation = 0L
    private var commandSettled = false
    private var minimumDelayElapsed = false

    var active = false
        private set

    fun begin(): Long {
        check(!active) { "Wi-Fi hotspot disable is already active." }
        generation += 1L
        if (generation == 0L) generation += 1L
        commandSettled = false
        minimumDelayElapsed = false
        active = true
        return generation
    }

    fun settleCommand(expectedGeneration: Long): Boolean {
        if (!active || expectedGeneration != generation) return false
        commandSettled = true
        return completeIfReady()
    }

    fun elapseMinimumDelay(expectedGeneration: Long): Boolean {
        if (!active || expectedGeneration != generation) return false
        minimumDelayElapsed = true
        return completeIfReady()
    }

    fun forceSettle(): Boolean {
        if (!active) return false
        active = false
        return true
    }

    private fun completeIfReady(): Boolean {
        if (!commandSettled || !minimumDelayElapsed) return false
        active = false
        return true
    }
}

internal fun recordingCardShouldAcceptWifiCredentials(
    preparationInFlight: Boolean,
    unsolicitedGateOpen: Boolean,
): Boolean = preparationInFlight || unsolicitedGateOpen

internal fun recordingCardWifiAttemptCanBegin(
    attemptOwned: Boolean,
    preparationInFlight: Boolean,
    hotspotDisableInFlight: Boolean,
    joinInFlight: Boolean,
    joinCallbackRetained: Boolean,
    joinNetworkRetained: Boolean,
    sessionRetained: Boolean,
    bleDisconnectExpected: Boolean,
    handoffReady: Boolean,
): Boolean = !recordingCardWifiAttemptIsActive(
    attemptOwned = attemptOwned,
    preparationInFlight = preparationInFlight,
    hotspotDisableInFlight = hotspotDisableInFlight,
    joinInFlight = joinInFlight,
    joinCallbackRetained = joinCallbackRetained,
    joinNetworkRetained = joinNetworkRetained,
    sessionActive = sessionRetained,
    bleDisconnectExpected = bleDisconnectExpected,
    handoffReady = handoffReady,
)

internal fun recordingCardWifiAttemptIsActive(
    attemptOwned: Boolean,
    preparationInFlight: Boolean,
    hotspotDisableInFlight: Boolean,
    joinInFlight: Boolean,
    joinCallbackRetained: Boolean,
    joinNetworkRetained: Boolean,
    sessionActive: Boolean,
    bleDisconnectExpected: Boolean,
    handoffReady: Boolean,
): Boolean = recordingCardWifiOperationOwnsTransport(
    attemptOwned = attemptOwned,
    preparationInFlight = preparationInFlight,
    hotspotDisableInFlight = hotspotDisableInFlight,
    joinInFlight = joinInFlight,
    joinCallbackRetained = joinCallbackRetained,
    joinNetworkRetained = joinNetworkRetained,
    sessionRetained = sessionActive,
    bleDisconnectExpected = bleDisconnectExpected,
    handoffReady = handoffReady,
)

internal fun recordingCardWifiOperationOwnsTransport(
    attemptOwned: Boolean,
    preparationInFlight: Boolean,
    hotspotDisableInFlight: Boolean,
    joinInFlight: Boolean,
    joinCallbackRetained: Boolean,
    joinNetworkRetained: Boolean,
    sessionRetained: Boolean,
    bleDisconnectExpected: Boolean,
    handoffReady: Boolean,
): Boolean = attemptOwned || preparationInFlight || hotspotDisableInFlight ||
    joinInFlight || joinCallbackRetained || joinNetworkRetained || sessionRetained ||
    bleDisconnectExpected || handoffReady

internal enum class RecordingCardWifiSessionCleanupMode {
    TERMINAL,
    FAILURE_AWAITING_ATTEMPT_TEARDOWN,
}

internal fun recordingCardWifiCleanupRetainsHotspotFacts(
    mode: RecordingCardWifiSessionCleanupMode,
    attemptOwned: Boolean,
): Boolean = mode ==
    RecordingCardWifiSessionCleanupMode.FAILURE_AWAITING_ATTEMPT_TEARDOWN && attemptOwned

internal fun recordingCardLegacyWifiOperationCanBegin(
    scopedAttemptOwned: Boolean,
): Boolean = !scopedAttemptOwned

internal fun recordingCardWifiRecoverySettlementIsValid(
    batchId: String?,
    attemptId: String?,
    safeDeviceFingerprint: String?,
): Boolean = batchId != null && batchId.isNotEmpty() && batchId.length <= 160 &&
    attemptId != null && Regex("^[a-zA-Z0-9_-]{1,128}$").matches(attemptId) &&
    safeDeviceFingerprint != null && safeDeviceFingerprint.isNotEmpty() &&
    safeDeviceFingerprint.length <= 160

internal enum class RecordingCardGattSetupAction {
    WAIT_FOR_MTU_CALLBACK,
    FAIL_MTU_REQUEST,
}

internal fun recordingCardGattSetupAction(mtuRequestQueued: Boolean): RecordingCardGattSetupAction =
    if (mtuRequestQueued) {
        RecordingCardGattSetupAction.WAIT_FOR_MTU_CALLBACK
    } else {
        RecordingCardGattSetupAction.FAIL_MTU_REQUEST
    }

internal fun recordingCardConnectionDeadlineErrorCode(connectionStage: String): String =
    if (connectionStage == "searching") {
        "RECORDING_CARD_NOT_FOUND"
    } else {
        "RECORDING_CARD_SETUP_TIMEOUT"
    }

/** Mirrors the iOS connection window and keeps malformed channel input bounded. */
internal fun recordingCardConnectTimeoutMillis(value: Any?): Long {
    val requested = (value as? Number)?.toLong()
        ?: RECORDING_CARD_DEFAULT_CONNECT_TIMEOUT_MS
    return requested.coerceIn(
        RECORDING_CARD_MIN_CONNECT_TIMEOUT_MS,
        RECORDING_CARD_MAX_CONNECT_TIMEOUT_MS,
    )
}

internal fun recordingCardBluetoothNamePayload(name: String?): ByteArray? {
    if (name.isNullOrBlank() || name.any { character ->
            character.code <= 0x1f || character.code in 0x7f..0x9f
        }
    ) {
        return null
    }
    val encoded = name.toByteArray(StandardCharsets.UTF_8)
    if (encoded.isEmpty() || encoded.size > RECORDING_CARD_BLUETOOTH_NAME_BYTES) return null
    return encoded.copyOf(RECORDING_CARD_BLUETOOTH_NAME_BYTES)
}

internal enum class RecordingCardBluetoothNameResponse {
    SUCCESS,
    REJECTED,
    INVALID,
}

internal fun recordingCardBluetoothNameResponse(
    payload: ByteArray,
): RecordingCardBluetoothNameResponse {
    if (payload.size != 1) return RecordingCardBluetoothNameResponse.INVALID
    return when (payload[0].toInt() and 0xff) {
        0x00 -> RecordingCardBluetoothNameResponse.SUCCESS
        0x01 -> RecordingCardBluetoothNameResponse.REJECTED
        else -> RecordingCardBluetoothNameResponse.INVALID
    }
}

internal class RecordingCardAndroidBridge(
    private val context: Context,
    messenger: BinaryMessenger,
) : EventChannel.StreamHandler {
    private val mainHandler = Handler(Looper.getMainLooper())
    private val bluetoothAccess = RecordingCardBluetoothAccess(context)
    private val methodChannel = MethodChannel(messenger, METHOD_CHANNEL)
    private val eventChannel = EventChannel(messenger, EVENT_CHANNEL)
    private val discoveredDevices = linkedMapOf<String, BluetoothDevice>()
    private val discoveredRows = linkedMapOf<String, Map<String, Any>>()
    private val manufacturerScanDiagnosticShapes = mutableSetOf<String>()
    private val pendingCommands = mutableMapOf<Int, PendingCommand>()
    private val commandTimeouts = mutableMapOf<Int, Runnable>()
    private val frameDecoder = RecordingCardControlFrameDecoder()
    private val fileDirectory = RecordingCardFileDirectory()

    private var eventSink: EventChannel.EventSink? = null
    private var scanner: BluetoothLeScanner? = null
    private var activeScanCallback: ScanCallback? = null
    private var scanGeneration = 0L
    private var transportGeneration = 0L
    private var commandRequestCounter = 0L
    private var scanResult: MethodChannel.Result? = null
    private var connectResult: MethodChannel.Result? = null
    private var unbindResult: MethodChannel.Result? = null
    private var unbindDisconnectExpected = false
    private var requestedFingerprint: String? = null
    private var requestedBindingToken: ByteArray? = null
    private var requestedExpectedSerialNumber: String? = null
    private var connectedSerialNumber: String? = null
    private var scanTimeout: Runnable? = null
    private var scanPreservesConnection = false
    private var connectDeadline: Runnable? = null
    private val handshake = RecordingCardHandshakeGuard()
    private var bindingSendDeadline: Runnable? = null
    private var bindingInfoRetry: Runnable? = null
    private var bindingInfoRetryDueAtMs: Long? = null
    private var handshakeCommand: Int? = null
    private var mtuDeadline: Runnable? = null
    private var mtuNegotiationCompleted = false
    private var serviceDiscoveryStarted = false
    private var gatt: BluetoothGatt? = null
    private var forceScanDisconnectGatt: BluetoothGatt? = null
    private var writeCharacteristic: BluetoothGattCharacteristic? = null
    private var controlCharacteristic: BluetoothGattCharacteristic? = null
    private var realtimeCharacteristic: BluetoothGattCharacteristic? = null
    private var offlineCharacteristic: BluetoothGattCharacteristic? = null
    private val notificationSetup = RecordingCardNotificationSetup()
    private var offlineCapture: OfflineCapture? = null
    private var offlineInactivityTimeout: Runnable? = null
    private val bleSilenceBarrier = RecordingCardBleSilenceBarrier(BLE_CAPTURE_SILENCE_MS)
    private var bleSilenceTimeout: Runnable? = null
    private var bleSilenceCompletion: (() -> Unit)? = null
    private var deviceName: String? = null
    private var safeFingerprint: String? = null
    private var connectionState = "disconnected"
    private var connectionStage = "idle"
    private var permissionProblem: String? = null
    private var statusMessage: String? = null
    private var batteryPercent: Int? = null
    private var storageTotalBytes: Long? = null
    private var storageFreeBytes: Long? = null
    private var storageUsedBytes: Long? = null
    private var firmwareVersion: String? = null
    private var deviceModel: String? = null
    private var recordingFormat = "unknown"
    private var recordingState = "idle"
    private val recordingClock = RecordingCardRecordingClock()
    private var currentFileName: String? = null
    private var currentFileSizeBytes: Long? = null
    private var currentRecordingType: Int? = null
    private var lastCompletedFileName: String? = null
    private var lastCompletedFileSizeBytes: Long? = null
    private var lastCompletedRecordingType: Int? = null
    private var lastCompletedFileNeedsSync: Boolean? = null
    private var recordingRevision = 0L
    private var recordingObservationSource = "runtimeSnapshot"
    private var recordingObservedAt = isoNow()
    private var wifiSupported: Boolean? = null
    private var wifiFirmwareVersion: String? = null
    private var wifiPrepareResult: MethodChannel.Result? = null
    private var wifiPreparationGeneration = 0L
    private var pendingWifiCredentials: WifiCredentials? = null
    private var pendingWifiCredentialTransportGeneration: Long? = null
    private var pendingWifiCredentialFingerprint: String? = null
    private var acceptsUnsolicitedWifiCredentials = false
    private var wifiPreparationAcknowledged = false
    private var wifiHotspotEnableMayHaveBeenDispatched = false
    private val wifiHotspotDisableBarrier = RecordingCardWifiHotspotDisableBarrier()
    private val wifiHotspotDisableWaiters = mutableListOf<() -> Unit>()
    private var wifiHotspotDisableMinimumDelay: Runnable? = null
    private val wifiHotspotDisableInFlight: Boolean
        get() = wifiHotspotDisableBarrier.active
    private var wifiCredentialTimeout: Runnable? = null
    private var wifiDownloadFileKey: String? = null
    @Volatile private var wifiRecoveryBatchId: String? = null
    @Volatile private var wifiAttemptId: String? = null
    private var wifiAttemptOwned = false
    @Volatile private var wifiLastActivityAt = SystemClock.elapsedRealtime()
    @Volatile private var wifiInterruptionCode: String? = null
    @Volatile private var wifiSession: WifiSession? = null
    @Volatile private var wifiSessionOperationInFlight = false
    @Volatile private var wifiSessionCancellationRequested = false
    @Volatile private var wifiActiveCapture: OfflineCapture? = null
    @Volatile private var wifiBleDisconnectExpected = false
    @Volatile private var wifiHandoffReady = false
    private val wifiCommitLock = Any()
    private val pendingWifiCancellationResults = mutableListOf<MethodChannel.Result>()
    @Volatile private var wifiJoinNetwork: Network? = null
    private var wifiJoinCallback: ConnectivityManager.NetworkCallback? = null
    private var wifiJoinResult: MethodChannel.Result? = null
    private var lastInfoRefreshedAt: String? = null
    private var receiverRegistered = false
    private var disposed = false
    private var gattRetry: Runnable? = null
    private var gattRetryCount = 0
    private var gattLinkEstablished = false
    private var gattCloseInProgress = false
    private var pendingGattDevice: BluetoothDevice? = null
    private var pendingGattFingerprint: String? = null

    private val prerequisiteReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action == null) return
            runOnMain(::handleBluetoothPrerequisiteChanged)
        }
    }

    init {
        methodChannel.setMethodCallHandler(::handleMethodCall)
        eventChannel.setStreamHandler(this)
        registerPrerequisiteReceiver()
    }

    companion object {
        private const val METHOD_CHANNEL = "huahuoai/recording_card"
        private const val EVENT_CHANNEL = "huahuoai/recording_card/events"
        private const val COMMAND_TIMEOUT_MS = 8_000L
        private const val WIFI_HOTSPOT_DISABLE_TIMEOUT_MS = 400L
        private const val SCAN_TIMEOUT_MS = 6_000L
        private const val MTU_TIMEOUT_MS = 3_000L
        private const val GATT_RETRY_DELAY_MS = 400L
        private const val BINDING_INFO_RETRY_DELAY_MS = 1_000L
        private const val BINDING_INFO_FAULT_RETRY_DELAY_MS = 50L
        private const val REQUESTED_MTU = 517
        private const val MINIMUM_HANDSHAKE_MTU = 27
        private const val DEBUG_TAG = "FW920"
        private val SERVICE_UUID: UUID = uuid16("E5E0")
        private val WRITE_UUID: UUID = uuid16("E5E1")
        private val CONTROL_NOTIFY_UUID: UUID = uuid16("E5E2")
        private val REALTIME_NOTIFY_UUID: UUID = uuid16("E5E3")
        private val OFFLINE_NOTIFY_UUID: UUID = uuid16("E5E4")
        private const val MAX_PRE_ACK_BYTES = 512 * 1024
        private const val BLE_CAPTURE_SILENCE_MS = 500L
        private const val DOWNLOAD_INACTIVITY_TIMEOUT_MS = 30_000L
        private const val DOWNLOAD_OVERALL_MIN_MS = 5 * 60_000L
        private const val DOWNLOAD_OVERALL_MAX_MS = 30 * 60_000L
        private val LEGACY_BINDING_TOKEN =
            "HHFW920TEST00010".toByteArray(StandardCharsets.US_ASCII)
        private val CLIENT_CONFIGURATION_UUID: UUID = uuid16("2902")

        fun register(
            activity: FlutterActivity,
            messenger: BinaryMessenger,
        ): RecordingCardAndroidBridge = RecordingCardAndroidBridge(
            activity.applicationContext,
            messenger,
        )

        private fun uuid16(value: String): UUID =
            UUID.fromString("0000$value-0000-1000-8000-00805f9b34fb")
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
        emitSnapshot()
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    fun unregister() {
        if (disposed) return
        disposed = true
        eventSink = null
        methodChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
        if (receiverRegistered) {
            runCatching { context.unregisterReceiver(prerequisiteReceiver) }
            receiverRegistered = false
        }
        cancelGattRetry()
        cancelPendingScanForExplicitDisconnect()
        cancelPendingConnectForExplicitDisconnect()
        unbindResult?.error(
            "NATIVE_RECORDING_CARD_DRIVER_UNAVAILABLE",
            "Recording-card driver detached.",
            null,
        )
        unbindResult = null
        disconnect(waitForHotspotDisable = false)
    }

    private fun handleMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val scopedMethods = setOf("prepareWifiSession", "joinWifiNetwork", "verifyWifiHandoff", "openWifiSession",
            "downloadFileInWifiSession", "closeWifiSession", "cancelWifiSession")
        if (call.method in scopedMethods) {
            val arguments = call.arguments as? Map<*, *>
            val batchId = arguments?.get("recoveryBatchId") as? String
            val attemptId = arguments?.get("attemptId") as? String
            if ((batchId != null || attemptId != null) &&
                (!wifiAttemptOwned || batchId != wifiRecoveryBatchId || attemptId != wifiAttemptId)) {
                result.error("RECORDING_CARD_WIFI_ATTEMPT_SUPERSEDED", "Wi-Fi attempt no longer owns the session.", null)
                return
            }
        }
        when (call.method) {
            "scanDevices" -> scanDevices(result)
            "cancelDiscovery" -> cancelDiscovery(result)
            "connect" -> connect(call.arguments as? Map<*, *>, result)
            "getConnectionState" -> result.success(deviceStateMap())
            "refreshDeviceInfo" -> refreshDeviceInfo(result)
            "readRecordingState" -> readRecordingState(result)
            "readAccountBindingClaim" -> readAccountBindingClaim(result)
            "readAccountBindingIdentity" -> readAccountBindingIdentity(result)
            "signAccountBindingChallenge" -> signAccountBindingChallenge(result)
            "setBluetoothName" -> setBluetoothName(call.arguments as? Map<*, *>, result)
            "startRecording" -> recordingCommand(COMMAND_START, "recording", result)
            "pauseRecording" -> recordingCommand(COMMAND_PAUSE, "paused", result)
            "resumeRecording" -> recordingCommand(COMMAND_RESUME, "recording", result)
            "stopRecording" -> recordingCommand(COMMAND_STOP, "idle", result)
            "scanFiles" -> scanFiles(result)
            "downloadFileToLocalCache", "syncFileToLocalCache", "downloadRecoverableBluetoothFile" ->
                downloadFile(call.arguments as? Map<*, *>, result)
            "recoverBluetoothDownload" ->
                recoverBluetoothDownload(call.arguments as? Map<*, *>, result)
            "cancelFileTransfer" -> cancelFileTransfer(result)
            "deleteFileFromDevice" -> deleteFile(call.arguments as? Map<*, *>, result)
            "prepareWifiTransfer" -> prepareWifiTransfer(call.arguments as? Map<*, *>, result)
            "beginWifiAttempt" -> beginWifiAttempt(call.arguments as? Map<*, *>, result)
            "queryWifiSession" -> result.success(wifiRecoverySnapshot())
            "settleWifiRecovery" -> settleWifiRecovery(call.arguments as? Map<*, *>, result)
            "recoverWifiDownload" -> recoverWifiDownload(call.arguments as? Map<*, *>, result)
            "prepareWifiSession" -> prepareWifiSession(call.arguments as? Map<*, *>, result)
            "verifyWifiHandoff" -> verifyWifiHandoff(result)
            "joinWifiNetwork" -> joinWifiNetwork(call.arguments as? Map<*, *>, result)
            "openWifiSession" -> openWifiSession(call.arguments as? Map<*, *>, result)
            "downloadFileInWifiSession" ->
                downloadFileInWifiSession(call.arguments as? Map<*, *>, result)
            "closeWifiSession" -> closeWifiSession(result)
            "cancelWifiSession" -> cancelWifiSession(result)
            "downloadFileOverWifi" ->
                downloadFileOverWifi(call.arguments as? Map<*, *>, result)
            "unbindDevice" -> unbindDevice(call.arguments as? Map<*, *>, result)
            "disconnect" -> disconnect(result)
            else -> result.notImplemented()
        }
    }

    private fun registerPrerequisiteReceiver() {
        val filter = IntentFilter().apply {
            addAction(BluetoothAdapter.ACTION_STATE_CHANGED)
            addAction(LocationManager.MODE_CHANGED_ACTION)
            addAction(LocationManager.PROVIDERS_CHANGED_ACTION)
        }
        runCatching {
            ContextCompat.registerReceiver(
                context,
                prerequisiteReceiver,
                filter,
                ContextCompat.RECEIVER_EXPORTED,
            )
            receiverRegistered = true
        }.onFailure {
            receiverRegistered = false
            Log.w(DEBUG_TAG, "Bluetooth prerequisite receiver registration failed")
        }
    }

    private fun handleBluetoothPrerequisiteChanged() {
        if (disposed) return
        val discoveryActive = scanner != null || scanResult != null ||
            (connectResult != null && connectionStage == "searching")
        if (discoveryActive) {
            val readiness = bluetoothAccess.discoveryReadiness()
            if (readiness != RecordingCardBluetoothReadiness.READY) {
                failForBluetoothReadiness(readiness)
            }
            return
        }
        if (gatt == null && connectResult == null) return
        val readiness = bluetoothAccess.connectionReadiness()
        if (readiness == RecordingCardBluetoothReadiness.READY) return
        failForBluetoothReadiness(readiness)
    }

    private fun cancelDiscovery(result: MethodChannel.Result) {
        if (connectResult != null) {
            result.success(false)
            return
        }
        val pendingScan = scanResult
        if (pendingScan == null) {
            result.success(false)
            return
        }
        stopScan()
        scanResult = null
        scanPreservesConnection = false
        pendingScan.error(
            "RECORDING_CARD_SCAN_CANCELLED",
            "Recording-card scan was cancelled.",
            null,
        )
        if (isReady()) {
            connectionState = "connected"
            connectionStage = "connected"
            statusMessage = "录音卡已连接"
        } else {
            connectionState = "disconnected"
            connectionStage = "idle"
            statusMessage = null
        }
        emitSnapshot()
        result.success(true)
    }

    private fun scanDevices(result: MethodChannel.Result) {
        if (unbindResult != null) {
            result.error(
                "RECORDING_CARD_UNBIND_IN_PROGRESS",
                "Recording-card unbind is already running.",
                null,
            )
            return
        }
        if (scanResult != null || connectResult != null) {
            result.error("RECORDING_CARD_SCAN_IN_PROGRESS", "A recording-card scan is already running.", null)
            return
        }
        if (!ensureBluetoothReady(result)) return
        scanResult = result
        startScan()
    }

    private fun readAccountBindingClaim(result: MethodChannel.Result) {
        if (!isReady()) {
            result.error("RECORDING_CARD_NOT_CONNECTED", "Recording card is not connected.", null)
            return
        }
        sendCommand(COMMAND_GET_SERIAL, byteArrayOf(), result) { payload ->
            val claim = recordingCardOpaqueAccountClaim(payload)
                ?: throw IllegalArgumentException("invalid recording-card identity")
            CommandResponse.Complete(mapOf("opaqueClaim" to claim))
        }
    }

    private fun readAccountBindingIdentity(result: MethodChannel.Result) {
        if (!isReady()) {
            result.error("RECORDING_CARD_NOT_CONNECTED", "Recording card is not connected.", null)
            return
        }
        connectedSerialNumber?.let { serialNumber ->
            result.success(mapOf("serialNumber" to serialNumber))
            return
        }
        sendCommand(COMMAND_GET_SERIAL, byteArrayOf(), result) { payload ->
            val serialNumber = recordingCardSerialNumber(payload)
                ?: throw IllegalArgumentException("invalid recording-card identity")
            connectedSerialNumber = serialNumber
            CommandResponse.Complete(mapOf("serialNumber" to serialNumber))
        }
    }

    private fun signAccountBindingChallenge(result: MethodChannel.Result) {
        if (!isReady()) {
            result.error("RECORDING_CARD_NOT_CONNECTED", "Recording card is not connected.", null)
            return
        }
        result.error(
            "RECORDING_CARD_ATTESTATION_UNSUPPORTED",
            "The connected recording-card firmware does not expose a challenge-signing command.",
            null,
        )
    }

    private fun setBluetoothName(arguments: Map<*, *>?, result: MethodChannel.Result) {
        if (!isReady()) {
            result.error("RECORDING_CARD_NOT_CONNECTED", "Recording card is not connected.", null)
            return
        }
        val bluetoothName = arguments?.get("bluetoothName") as? String
        val payload = recordingCardBluetoothNamePayload(bluetoothName)
        if (payload == null) {
            result.error(
                "RECORDING_CARD_BLUETOOTH_NAME_INVALID",
                "Bluetooth name must be 1 to 32 UTF-8 bytes and contain no control characters.",
                null,
            )
            return
        }
        sendCommand(COMMAND_SET_BLUETOOTH_NAME, payload, result) { response ->
            when (recordingCardBluetoothNameResponse(response)) {
                RecordingCardBluetoothNameResponse.SUCCESS -> {
                    deviceName = bluetoothName
                    emitSnapshot()
                    CommandResponse.Complete(deviceStateMap())
                }
                RecordingCardBluetoothNameResponse.REJECTED -> throw BluetoothNameSetFailure(
                    "RECORDING_CARD_BLUETOOTH_NAME_REJECTED",
                    "Recording card rejected the Bluetooth name update.",
                )
                RecordingCardBluetoothNameResponse.INVALID -> throw BluetoothNameSetFailure(
                    "RECORDING_CARD_BLUETOOTH_NAME_RESPONSE_INVALID",
                    "Recording-card Bluetooth name response was invalid.",
                )
            }
        }
    }

    private fun connect(arguments: Map<*, *>?, result: MethodChannel.Result) {
        if (unbindResult != null) {
            result.error(
                "RECORDING_CARD_UNBIND_IN_PROGRESS",
                "Recording-card unbind is already running.",
                null,
            )
            return
        }
        if (connectResult != null) {
            result.error("RECORDING_CARD_CONNECT_IN_PROGRESS", "A recording-card connection is already running.", null)
            return
        }
        if (!ensureBluetoothReady(result)) return
        val forceScan = arguments?.get("forceScan") == true
        val overallTimeoutMs = recordingCardConnectTimeoutMillis(
            arguments?.get("overallTimeoutMs"),
        )
        val bindingToken = bindingTokenBytes(arguments?.get("bindingToken") as? String)
        if (bindingToken == null) {
            result.error("RECORDING_CARD_BINDING_TOKEN_INVALID", "Recording-card binding token is invalid.", null)
            return
        }
        val expectedSerialArgument = arguments?.get("expectedSerialNumber") as? String
        val expectedSerialNumber = expectedSerialArgument?.let(
            ::recordingCardNormalizedOwnershipSerial,
        )
        if (expectedSerialArgument != null && expectedSerialNumber == null) {
            result.error(
                "RECORDING_CARD_ADVERTISEMENT_SN_INVALID",
                "Recording-card advertisement serial number is invalid.",
                null,
            )
            return
        }
        scanResult?.let { activeScan ->
            val rows = discoveredRows.values.toList()
            stopScan()
            scanResult = null
            activeScan.success(mapOf("devices" to rows))
        }
        if (isReady() && !forceScan) {
            if (recordingCardCanReuseConnection(
                    arguments?.get("safeDeviceFingerprint") as? String,
                    safeFingerprint,
                    expectedSerialNumber,
                    connectedSerialNumber,
                )
            ) {
                result.success(deviceStateMap())
            } else {
                result.error("RECORDING_CARD_CONNECT_BUSY", "Disconnect the current recording card before selecting another.", null)
            }
            return
        }
        val resetsActiveTransport = forceScan && gatt != null
        if (resetsActiveTransport) {
            if (recordingState != "idle" ||
                pendingCommands.isNotEmpty() ||
                hasActiveTransferOrWifiOperation()
            ) {
                result.error(
                    "RECORDING_CARD_CONNECT_BUSY",
                    "Recording card is busy and cannot start a recovery scan.",
                    null,
                )
                return
            }
        }
        requestedFingerprint = arguments?.get("safeDeviceFingerprint") as? String
        requestedBindingToken = bindingToken
        requestedExpectedSerialNumber = expectedSerialNumber
        connectResult = result
        debugLog(
            "connect requested selected=${requestedFingerprint != null} " +
                "forceScan=$forceScan timeoutMs=$overallTimeoutMs",
        )
        scheduleConnectDeadline(overallTimeoutMs)
        if (resetsActiveTransport && resetGattTransportForForceScan()) {
            return
        }
        val cached = requestedFingerprint?.let(discoveredDevices::get)
        val known = cached.takeIf {
            recordingCardShouldReuseCachedDevice(forceScan, cached != null)
        }
        if (known != null) {
            connectDevice(known, requestedFingerprint!!)
        } else {
            startScan()
        }
    }

    @SuppressLint("MissingPermission")
    private fun startScan() {
        scanPreservesConnection = connectResult == null && isReady()
        if (!ensureBluetoothScanReady()) return
        val adapter = bluetoothAccess.adapter
        if (adapter == null) {
            failScanAndConnect(
                "RECORDING_CARD_BLUETOOTH_UNAVAILABLE",
                "Bluetooth LE is unavailable.",
            )
            return
        }
        val scannerAccess = runCatching { adapter.bluetoothLeScanner }
        val leScanner = scannerAccess.getOrNull()
        if (leScanner == null) {
            if (scannerAccess.exceptionOrNull() is SecurityException) {
                failForBluetoothReadiness(
                    RecordingCardBluetoothReadiness.PERMISSION_REQUIRED,
                )
            } else {
                failScanAndConnect(
                    "RECORDING_CARD_BLUETOOTH_UNAVAILABLE",
                    "Bluetooth LE scanning is unavailable.",
                )
            }
            return
        }
        scanner = leScanner
        discoveredDevices.clear()
        discoveredRows.clear()
        manufacturerScanDiagnosticShapes.clear()
        if (!scanPreservesConnection) {
            connectionState = if (connectResult == null) "disconnected" else "connecting"
            connectionStage = if (connectResult == null) "idle" else "searching"
        }
        statusMessage = if (scanPreservesConnection) {
            "录音卡已连接，正在扫描附近设备"
        } else if (connectResult == null) {
            "正在扫描附近录音卡"
        } else {
            "正在搜索录音卡"
        }
        emitSnapshot()
        val generation = ++scanGeneration
        val callback = object : ScanCallback() {
            override fun onScanResult(callbackType: Int, result: ScanResult) {
                runOnMain {
                    if (generation != scanGeneration || activeScanCallback == null) {
                        return@runOnMain
                    }
                    handleScanResult(result)
                }
            }

            override fun onScanFailed(errorCode: Int) {
                runOnMain {
                    if (generation != scanGeneration || activeScanCallback == null) {
                        return@runOnMain
                    }
                    Log.w(DEBUG_TAG, "BLE scan callback failed errorCode=$errorCode")
                    when (errorCode) {
                        ScanCallback.SCAN_FAILED_ALREADY_STARTED -> failScanAndConnect(
                            "RECORDING_CARD_SCAN_IN_PROGRESS",
                            "A recording-card scan is already running.",
                        )
                        6 -> failScanAndConnect(
                            "RECORDING_CARD_SCAN_THROTTLED",
                            "Bluetooth scanning is temporarily rate limited.",
                        )
                        ScanCallback.SCAN_FAILED_FEATURE_UNSUPPORTED -> failForBluetoothReadiness(
                            RecordingCardBluetoothReadiness.UNSUPPORTED,
                        )
                        else -> failScanAndConnect(
                            "RECORDING_CARD_SCAN_FAILED",
                            "Recording-card scan failed.",
                        )
                    }
                }
            }
        }
        activeScanCallback = callback
        val scanStartFailure = runCatching {
            leScanner.startScan(
                null,
                bluetoothAccess.foregroundScanSettings(),
                callback,
            )
        }.exceptionOrNull()
        if (scanStartFailure != null) {
            Log.w(
                DEBUG_TAG,
                "BLE scan start failed type=${scanStartFailure.javaClass.simpleName}",
            )
            if (scanStartFailure is SecurityException) {
                permissionProblem = "bluetooth_permission_required"
                failScanAndConnect(
                    "RECORDING_CARD_BLUETOOTH_PERMISSION_REQUIRED",
                    "Bluetooth scan permission is required.",
                )
            } else {
                failScanAndConnect(
                    "RECORDING_CARD_SCAN_FAILED",
                    "Recording-card scan could not start.",
                )
            }
            return
        }
        debugLog("BLE scan started mode=lowLatency callback=allMatches")
        if (connectResult == null) {
            scanTimeout?.let(mainHandler::removeCallbacks)
            scanTimeout = Runnable {
                stopScan()
                scanResult?.success(mapOf("devices" to discoveredRows.values.toList()))
                scanResult = null
                if (scanPreservesConnection) {
                    statusMessage = "录音卡已连接"
                }
                scanPreservesConnection = false
                emitSnapshot()
            }.also { mainHandler.postDelayed(it, SCAN_TIMEOUT_MS) }
        }
    }

    @SuppressLint("MissingPermission")
    private fun stopScan() {
        val activeScanner = scanner
        val callback = activeScanCallback
        scanner = null
        activeScanCallback = null
        ++scanGeneration
        if (activeScanner != null && callback != null) {
            runCatching { activeScanner.stopScan(callback) }
            debugLog("BLE scan stopped")
        }
        scanTimeout?.let(mainHandler::removeCallbacks)
        scanTimeout = null
    }

    @SuppressLint("MissingPermission")
    private fun handleScanResult(result: ScanResult) {
        val manufacturerPayload = result.scanRecord?.getManufacturerSpecificData(
            RECORDING_CARD_MANUFACTURER_COMPANY_ID,
        )
        val diagnostic = recordingCardManufacturerAdvertisementDiagnostic(
            RECORDING_CARD_MANUFACTURER_COMPANY_ID,
            manufacturerPayload,
        )
        if (manufacturerScanDiagnosticShapes.add(diagnostic)) {
            debugLog(diagnostic)
        }
        if (!recordingCardHasCompatibleManufacturerData(
                RECORDING_CARD_MANUFACTURER_COMPANY_ID,
                manufacturerPayload,
            )
        ) {
            return
        }
        val device = result.device ?: return
        val fingerprint = safeFingerprintFor(device)
        val serialNumber = recordingCardManufacturerSerialNumber(
            RECORDING_CARD_MANUFACTURER_COMPANY_ID,
            manufacturerPayload,
        )
        discoveredDevices[fingerprint] = device
        val currentRow = discoveredRows[fingerprint]
        val retainedSerialNumber = currentRow?.get("serialNumber") as? String
        val transportConnectable = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            result.isConnectable
        } else {
            null
        }
        val advertisedName = result.scanRecord?.deviceName
        val fallbackName = runCatching { device.name }.getOrNull()
        val row = recordingCardMergedDiscoveredRow(
            current = currentRow,
            advertisedName = advertisedName,
            fallbackName = fallbackName,
            defaultName = "Huahuo Recording Card",
            fingerprint = fingerprint,
            rssi = result.rssi,
            isConnectable = recordingCardDiscoveryRowIsConnectable(
                hasValidatedIdentity = serialNumber != null || retainedSerialNumber != null,
                transportConnectable = transportConnectable,
            ),
            serialNumber = serialNumber,
            lastSeenAt = isoNow(),
        )
        discoveredRows[fingerprint] = row
        if (recordingCardDiscoveryRowHasMeaningfulChange(currentRow, row)) {
            emitSnapshot()
        }

        if (transportConnectable != false && recordingCardDiscoveryCanStartConnection(
                hasPendingConnect = connectResult != null,
                requestedFingerprint = requestedFingerprint,
                observedFingerprint = fingerprint,
                requestedExpectedSerialNumber = requestedExpectedSerialNumber,
                observedSerialNumber = serialNumber ?: retainedSerialNumber,
            )
        ) {
            stopScan()
            connectDevice(device, fingerprint)
        }
    }

    @SuppressLint("MissingPermission")
    private fun connectDevice(
        device: BluetoothDevice,
        fingerprint: String,
        retrying: Boolean = false,
    ) {
        if (!retrying) {
            gattRetryCount = 0
            resetRecordingRuntime("connectionReset")
        }
        gattLinkEstablished = false
        pendingGattDevice = device
        pendingGattFingerprint = fingerprint
        wifiBleDisconnectExpected = false
        wifiHandoffReady = false
        connectionState = "connecting"
        connectionStage = "connecting"
        statusMessage = "正在连接录音卡"
        safeFingerprint = fingerprint
        deviceName = discoveredRows[fingerprint]?.get("displayName") as? String
        emitSnapshot()
        closeGatt()
        acceptsUnsolicitedWifiCredentials = true
        val connection = runCatching {
            bluetoothAccess.connectGatt(device, gattCallback, mainHandler)
        }
        val connectedGatt = connection.getOrNull()
        if (connectedGatt == null) {
            if (connection.exceptionOrNull() is SecurityException) {
                failForBluetoothReadiness(
                    RecordingCardBluetoothReadiness.PERMISSION_REQUIRED,
                )
            } else {
                failConnect(
                    "RECORDING_CARD_CONNECT_FAILED",
                    "Recording-card connection could not start.",
                )
            }
            return
        }
        gatt = connectedGatt
    }

    private val gattCallback = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) {
            runOnMain { handleGattConnectionStateChange(gatt, status, newState) }
        }

        override fun onMtuChanged(gatt: BluetoothGatt, mtu: Int, status: Int) {
            runOnMain { handleGattMtuChanged(gatt, mtu, status) }
        }

        override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) {
            runOnMain { handleGattServicesDiscovered(gatt, status) }
        }

        override fun onDescriptorWrite(gatt: BluetoothGatt, descriptor: BluetoothGattDescriptor, status: Int) {
            runOnMain { handleGattDescriptorWrite(gatt, descriptor, status) }
        }

        @Deprecated("Deprecated in Java")
        override fun onCharacteristicChanged(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
        ) {
            val value = characteristic.value?.copyOf() ?: return
            runOnMain { handleGattCharacteristicChanged(gatt, characteristic, value) }
        }

        override fun onCharacteristicChanged(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            value: ByteArray,
        ) {
            val stableValue = value.copyOf()
            runOnMain { handleGattCharacteristicChanged(gatt, characteristic, stableValue) }
        }
    }

    @SuppressLint("MissingPermission")
    private fun handleGattConnectionStateChange(
        callbackGatt: BluetoothGatt,
        status: Int,
        newState: Int,
    ) {
        if (!acceptGattCallback(callbackGatt)) return
        debugLog("gatt state status=$status newState=$newState")
        if (forceScanDisconnectGatt === callbackGatt &&
            (newState == BluetoothProfile.STATE_DISCONNECTED || status != BluetoothGatt.GATT_SUCCESS)
        ) {
            completeForceScanTransportReset(callbackGatt)
            return
        }
        if (
            newState == BluetoothProfile.STATE_DISCONNECTED &&
            recordingCardUnbindDisconnectCompletesOperation(
                unbindInProgress = unbindResult != null,
                commandDispatched = unbindDisconnectExpected &&
                    pendingCommands.containsKey(COMMAND_BIND_DEVICE),
            )
        ) {
            debugLog("gatt disconnect completed dispatched unbind without ACK")
            clearPendingCommand(COMMAND_BIND_DEVICE)
            unbindDisconnectExpected = false
            finishUnbindSuccessfully()
            return
        }
        if (status != BluetoothGatt.GATT_SUCCESS) {
            val disposition = recordingCardGattDisconnectDisposition(
                hasPendingConnect = connectResult != null,
                wifiBleDisconnectExpected = wifiBleDisconnectExpected,
                wifiSessionActive = wifiSession != null,
            )
            if (disposition == RecordingCardGattDisconnectDisposition.EXPECTED_WIFI_HANDOFF) {
                settleGattTransportDisconnect(expectedWifiHandoff = true)
                return
            }
            if (connectResult != null &&
                connectionStage == "connecting" &&
                !gattLinkEstablished &&
                recordingCardShouldRetryInitialGattFailure(status, gattRetryCount) &&
                scheduleGattRetry(callbackGatt)
            ) {
                return
            }
            if (disposition == RecordingCardGattDisconnectDisposition.ACTIVE_SESSION_INTERRUPTED) {
                settleGattTransportDisconnect(expectedWifiHandoff = false)
                return
            }
            failConnect(
                if (gattLinkEstablished) "RECORDING_CARD_DISCONNECTED" else "RECORDING_CARD_CONNECT_FAILED",
                if (gattLinkEstablished) "Recording-card BLE link was lost." else "Recording-card connection failed.",
            )
            return
        }
        when (newState) {
            BluetoothProfile.STATE_CONNECTED -> {
                if (gattLinkEstablished) return
                gattLinkEstablished = true
                connectionState = "connecting"
                connectionStage = "connecting"
                statusMessage = "正在发现录音卡服务"
                emitSnapshot()
                runCatching {
                    callbackGatt.requestConnectionPriority(BluetoothGatt.CONNECTION_PRIORITY_HIGH)
                }
                beginMtuNegotiation(callbackGatt)
            }
            BluetoothProfile.STATE_DISCONNECTED -> {
                when (recordingCardGattDisconnectDisposition(
                    hasPendingConnect = connectResult != null,
                    wifiBleDisconnectExpected = wifiBleDisconnectExpected,
                    wifiSessionActive = wifiSession != null,
                )) {
                    RecordingCardGattDisconnectDisposition.EXPECTED_WIFI_HANDOFF ->
                        settleGattTransportDisconnect(expectedWifiHandoff = true)
                    RecordingCardGattDisconnectDisposition.CONNECTION_SETUP_FAILED ->
                        failConnect(
                            "RECORDING_CARD_DISCONNECTED",
                            "Recording-card disconnected during connection.",
                        )
                    RecordingCardGattDisconnectDisposition.ACTIVE_SESSION_INTERRUPTED ->
                        settleGattTransportDisconnect(expectedWifiHandoff = false)
                }
            }
        }
    }

    private fun settleGattTransportDisconnect(expectedWifiHandoff: Boolean) {
        clearAllPendingCommands()
        resetRecordingRuntime("transportDisconnected")
        connectionState = "disconnected"
        connectionStage = "idle"
        statusMessage = if (expectedWifiHandoff) {
            "录音卡已切换到 Wi-Fi 传输"
        } else {
            "录音卡已断开"
        }
        emitSnapshot()
        closeGatt(preserveWifiHandoff = expectedWifiHandoff)
    }

    @SuppressLint("MissingPermission")
    private fun scheduleGattRetry(failedGatt: BluetoothGatt): Boolean {
        val device = pendingGattDevice ?: return false
        val fingerprint = pendingGattFingerprint ?: return false
        cancelMtuDeadline()
        if (gatt === failedGatt) gatt = null
        runCatching { failedGatt.disconnect() }
        runCatching { failedGatt.close() }
        writeCharacteristic = null
        controlCharacteristic = null
        realtimeCharacteristic = null
        offlineCharacteristic = null
        notificationSetup.reset()
        frameDecoder.reset()
        gattRetryCount += 1
        connectionState = "connecting"
        connectionStage = "connecting"
        statusMessage = "正在重新建立蓝牙连接"
        emitSnapshot()
        cancelGattRetry()
        gattRetry = Runnable {
            gattRetry = null
            if (disposed || connectResult == null) return@Runnable
            val readiness = bluetoothAccess.connectionReadiness()
            if (readiness != RecordingCardBluetoothReadiness.READY) {
                failForBluetoothReadiness(readiness)
                return@Runnable
            }
            connectDevice(device, fingerprint, retrying = true)
        }.also { mainHandler.postDelayed(it, GATT_RETRY_DELAY_MS) }
        debugLog("transient GATT connection failure scheduled one retry")
        return true
    }

    private fun cancelGattRetry() {
        gattRetry?.let(mainHandler::removeCallbacks)
        gattRetry = null
    }

    private fun handleGattMtuChanged(callbackGatt: BluetoothGatt, mtu: Int, status: Int) {
        if (!acceptGattCallback(callbackGatt)) return
        if (connectResult == null || mtuNegotiationCompleted || handshake.inProgress) return
        mtuNegotiationCompleted = true
        cancelMtuDeadline()
        debugLog("mtu changed status=$status mtu=$mtu")
        if (status != BluetoothGatt.GATT_SUCCESS || mtu < MINIMUM_HANDSHAKE_MTU) {
            failConnect(
                "RECORDING_CARD_MTU_NEGOTIATION_FAILED",
                "Recording-card MTU negotiation failed.",
            )
            return
        }
        startServiceDiscovery(callbackGatt)
    }

    private fun handleGattServicesDiscovered(callbackGatt: BluetoothGatt, status: Int) {
        if (!acceptGattCallback(callbackGatt)) return
        if (connectResult == null || !serviceDiscoveryStarted ||
            handshake.inProgress || writeCharacteristic != null
        ) return
        debugLog("services discovered status=$status")
        if (status != BluetoothGatt.GATT_SUCCESS) {
            failConnect("RECORDING_CARD_SERVICE_DISCOVERY_FAILED", "Recording-card service discovery failed.")
            return
        }
        val service = callbackGatt.getService(SERVICE_UUID)
        val write = service?.getCharacteristic(WRITE_UUID)
        val control = service?.getCharacteristic(CONTROL_NOTIFY_UUID)
        val realtime = service?.getCharacteristic(REALTIME_NOTIFY_UUID)
        val offline = service?.getCharacteristic(OFFLINE_NOTIFY_UUID)
        if (service == null || write == null || control == null || realtime == null || offline == null) {
            failConnect("RECORDING_CARD_PROFILE_INCOMPLETE", "Recording-card BLE profile is incomplete.")
            return
        }
        writeCharacteristic = write
        controlCharacteristic = control
        realtimeCharacteristic = realtime
        offlineCharacteristic = offline
        notificationSetup.begin(listOf(control.uuid, realtime.uuid, offline.uuid))
        debugLog("recording-card GATT profile ready")
        enableNextNotification(callbackGatt)
    }

    private fun handleGattDescriptorWrite(
        callbackGatt: BluetoothGatt,
        descriptor: BluetoothGattDescriptor,
        status: Int,
    ) {
        if (!acceptGattCallback(callbackGatt)) return
        if (descriptor.uuid != CLIENT_CONFIGURATION_UUID) return
        if (connectResult == null || handshake.inProgress ||
            descriptor.characteristic.uuid != notificationSetup.next
        ) return
        debugLog(
            "notification descriptor status=$status " +
                "characteristic=${descriptor.characteristic.uuid}",
        )
        if (status != BluetoothGatt.GATT_SUCCESS) {
            failConnect("RECORDING_CARD_NOTIFICATION_FAILED", "Recording-card notification subscription failed.")
            return
        }
        if (notificationSetup.acknowledge(descriptor.characteristic.uuid)) {
            enableNextNotification(callbackGatt)
        }
    }

    private fun handleGattCharacteristicChanged(
        callbackGatt: BluetoothGatt,
        characteristic: BluetoothGattCharacteristic,
        value: ByteArray,
    ) {
        if (!acceptGattCallback(callbackGatt)) return
        handleCharacteristicValue(characteristic, value)
    }

    @SuppressLint("MissingPermission")
    private fun beginMtuNegotiation(currentGatt: BluetoothGatt) {
        mtuNegotiationCompleted = false
        serviceDiscoveryStarted = false
        statusMessage = "正在协商录音卡连接"
        emitSnapshot()
        val queued = runCatching { currentGatt.requestMtu(REQUESTED_MTU) }
            .getOrDefault(false)
        debugLog("mtu request queued=$queued requested=$REQUESTED_MTU")
        when (recordingCardGattSetupAction(queued)) {
            RecordingCardGattSetupAction.WAIT_FOR_MTU_CALLBACK -> {
                if (mtuNegotiationCompleted) return
                cancelMtuDeadline()
                mtuDeadline = Runnable {
                    if (!recordingCardOwnsGattCallback(gatt, currentGatt)) return@Runnable
                    if (mtuNegotiationCompleted) return@Runnable
                    debugLog("mtu negotiation timed out")
                    failConnect(
                        "RECORDING_CARD_MTU_NEGOTIATION_TIMEOUT",
                        "Recording-card MTU negotiation timed out.",
                    )
                }.also { mainHandler.postDelayed(it, MTU_TIMEOUT_MS) }
            }
            RecordingCardGattSetupAction.FAIL_MTU_REQUEST -> failConnect(
                "RECORDING_CARD_MTU_NEGOTIATION_FAILED",
                "Recording-card MTU negotiation could not start.",
            )
        }
    }

    @SuppressLint("MissingPermission")
    private fun startServiceDiscovery(currentGatt: BluetoothGatt) {
        if (serviceDiscoveryStarted) return
        serviceDiscoveryStarted = true
        connectionState = "connecting"
        connectionStage = "connecting"
        statusMessage = "正在发现录音卡服务"
        emitSnapshot()
        val queued = runCatching { currentGatt.discoverServices() }
            .getOrDefault(false)
        debugLog("service discovery queued=$queued")
        if (!queued) {
            failConnect(
                "RECORDING_CARD_SERVICE_DISCOVERY_FAILED",
                "Recording-card service discovery could not start.",
            )
        }
    }

    private fun cancelMtuDeadline() {
        mtuDeadline?.let(mainHandler::removeCallbacks)
        mtuDeadline = null
    }

    @SuppressLint("MissingPermission")
    private fun acceptGattCallback(callbackGatt: BluetoothGatt): Boolean {
        if (recordingCardOwnsGattCallback(gatt, callbackGatt)) return true
        runCatching { callbackGatt.close() }
        return false
    }

    @SuppressLint("MissingPermission")
    private fun enableNotification(
        currentGatt: BluetoothGatt,
        characteristic: BluetoothGattCharacteristic,
    ): Boolean {
        if (!currentGatt.setCharacteristicNotification(characteristic, true)) return false
        val descriptor = characteristic.getDescriptor(CLIENT_CONFIGURATION_UUID) ?: return false
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            currentGatt.writeDescriptor(
                descriptor,
                BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE,
            ) == BluetoothStatusCodes.SUCCESS
        } else {
            @Suppress("DEPRECATION")
            run {
                descriptor.value = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
                currentGatt.writeDescriptor(descriptor)
            }
        }
    }

    private fun enableNextNotification(currentGatt: BluetoothGatt) {
        if (connectResult == null || handshake.inProgress) return
        if (notificationSetup.isComplete) {
            beginSecureHandshake()
            return
        }
        val next = listOfNotNull(controlCharacteristic, realtimeCharacteristic, offlineCharacteristic)
            .firstOrNull { it.uuid == notificationSetup.next }
        val enabled = runCatching { next != null && enableNotification(currentGatt, next) }
        if (enabled.exceptionOrNull() is SecurityException) {
            failForBluetoothReadiness(RecordingCardBluetoothReadiness.PERMISSION_REQUIRED)
        } else if (enabled.getOrDefault(false).not()) {
            failConnect("RECORDING_CARD_NOTIFICATION_FAILED", "Recording-card notification subscription failed.")
        }
    }

    private fun beginSecureHandshake() {
        if (connectResult == null || !handshake.begin()) return
        val token = requestedBindingToken
        if (token == null || token.size != 16) {
            failConnect("RECORDING_CARD_BINDING_TOKEN_INVALID", "Recording-card binding token is invalid.")
            return
        }
        connectionState = "connecting"
        connectionStage = "connecting"
        statusMessage = "正在完成安全连接"
        emitSnapshot()
        debugLog("secure handshake started")
        runSerialHandshakeStep {
            beginBindingSendWindow()
            resolveBindingToken(token) { compatibleToken ->
                runHandshakeStep(COMMAND_BIND_DEVICE, compatibleToken + byteArrayOf(0)) {
                    runHandshakeStep(COMMAND_SET_TIME, currentTimePayload()) {
                        runHandshakeStep(COMMAND_SET_PHONE_TYPE, byteArrayOf(1)) {
                            runHandshakeStep(COMMAND_DEVICE_INFO, byteArrayOf()) {
                                completeSecureHandshake()
                            }
                        }
                    }
                }
            }
        }
    }

    private fun runSerialHandshakeStep(next: () -> Unit) {
        handshakeCommand = COMMAND_GET_SERIAL
        val callback = object : MethodChannel.Result {
            override fun success(result: Any?) {
                if (!handshake.inProgress || connectResult == null) return
                val actualSerialNumber = result as? String
                if (!recordingCardSerialMatchesExpected(
                        requestedExpectedSerialNumber,
                        actualSerialNumber,
                    )
                ) {
                    failConnect(
                        "RECORDING_CARD_ADVERTISEMENT_SN_MISMATCH",
                        "Recording-card identity does not match its advertisement.",
                    )
                    return
                }
                connectedSerialNumber = actualSerialNumber
                next()
            }

            override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {
                if (!handshake.inProgress || connectResult == null) return
                failConnect(errorCode, errorMessage ?: "Recording-card serial could not be read.")
            }

            override fun notImplemented() {
                failConnect(
                    "RECORDING_CARD_HANDSHAKE_FAILED",
                    "Recording-card secure handshake failed.",
                )
            }
        }
        sendCommand(COMMAND_GET_SERIAL, byteArrayOf(), callback) { response ->
            val serialNumber = recordingCardSerialNumber(response)
                ?: throw IllegalArgumentException("invalid recording-card identity")
            CommandResponse.Complete(serialNumber)
        }
    }

    private fun resolveBindingToken(requestedToken: ByteArray, next: (ByteArray) -> Unit) {
        if (!handshake.inProgress || connectResult == null) return
        handshakeCommand = COMMAND_GET_BINDING_INFO
        val callback = object : MethodChannel.Result {
            override fun success(result: Any?) {
                if (!handshake.inProgress || connectResult == null) return
                val existing = result as? ByteArray
                val compatible = existing?.let { compatibleBindingToken(it, requestedToken) }
                if (compatible == null) {
                    failConnect(
                        "RECORDING_CARD_BINDING_INFO_MALFORMED",
                        "Recording-card binding information was malformed.",
                    )
                    return
                }
                next(compatible)
            }

            override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {
                if (!handshake.inProgress || connectResult == null) return
                failConnect(errorCode, errorMessage ?: "Recording-card binding information could not be read.")
            }

            override fun notImplemented() {
                failConnect("RECORDING_CARD_HANDSHAKE_FAILED", "Recording-card secure handshake failed.")
            }
        }
        sendCommand(COMMAND_GET_BINDING_INFO, byteArrayOf(), callback) { response ->
            if (response.isEmpty()) throw RecordingCardHandshakeFailure(
                "RECORDING_CARD_BINDING_INFO_MALFORMED",
                "Recording-card binding information was malformed.",
            )
            CommandResponse.Complete(response.copyOf())
        }
    }

    private fun beginBindingSendWindow() {
        handshake.receivedSerial(SystemClock.elapsedRealtime())
        val expectedDeadline = handshake.bindingDeadlineMillis
        bindingSendDeadline?.let(mainHandler::removeCallbacks)
        val deadline = Runnable {
            if (handshake.inProgress && connectResult != null &&
                handshake.bindingDeadlineMillis == expectedDeadline
            ) {
                recordingCardBindingSendSlaElapsed()
            }
        }
        bindingSendDeadline = deadline
        mainHandler.postDelayed(deadline, 5000L)
    }

    private fun recordingCardBindingSendSlaElapsed() {
        bindingSendDeadline = null
        debugLog(
            "binding send SLA elapsed command=${handshakeCommand ?: -1}; keeping live transport",
        )
        pendingCommands[COMMAND_GET_BINDING_INFO]?.let { pending ->
            scheduleBindingInfoRetry(pending.ownership, 0L)
        }
    }

    private fun resetHandshake() {
        bindingSendDeadline?.let(mainHandler::removeCallbacks)
        bindingSendDeadline = null
        cancelBindingInfoRetry()
        handshake.reset()
        handshakeCommand = null
    }

    private fun compatibleBindingToken(existingPayload: ByteArray, requested: ByteArray): ByteArray? {
        return compatibleRecordingCardBindingToken(
            existingPayload,
            requested,
            LEGACY_BINDING_TOKEN,
        )
    }

    private fun unbindDevice(arguments: Map<*, *>?, result: MethodChannel.Result) {
        if (unbindResult != null) {
            result.error(
                "RECORDING_CARD_UNBIND_IN_PROGRESS",
                "Recording-card unbind is already running.",
                null,
            )
            return
        }
        if (!isReady()) {
            result.error("RECORDING_CARD_NOT_CONNECTED", "Recording card is not connected.", null)
            return
        }
        if (recordingState != "idle") {
            result.error(
                "RECORDING_CARD_UNBIND_RECORDING_ACTIVE",
                "Stop recording before unbinding the recording card.",
                null,
            )
            return
        }
        if (pendingCommands.isNotEmpty() || hasActiveTransferOrWifiOperation()) {
            result.error(
                "RECORDING_CARD_UNBIND_BUSY",
                "Wait for recording-card commands and transfers to finish before unbinding.",
                null,
            )
            return
        }
        val requestedToken = bindingTokenBytes(arguments?.get("bindingToken") as? String)
        if (requestedToken == null) {
            result.error(
                "RECORDING_CARD_BINDING_TOKEN_INVALID",
                "Recording-card binding token is invalid.",
                null,
            )
            return
        }
        val deleteDeviceFiles = arguments?.get("deleteDeviceFiles") as? Boolean ?: false

        unbindResult = result
        val callback = object : MethodChannel.Result {
            override fun success(result: Any?) {
                val bindingPayload = result as? ByteArray
                val resolution = resolveRecordingCardUnbindToken(
                    bindingPayload,
                    requestedToken,
                    LEGACY_BINDING_TOKEN,
                )
                when (resolution.status) {
                    RecordingCardUnbindTokenStatus.TOKEN -> sendUnbindCommand(deleteDeviceFiles)
                    RecordingCardUnbindTokenStatus.ALREADY_UNBOUND -> finishUnbindWithError(
                        "RECORDING_CARD_ALREADY_UNBOUND",
                        "Recording card is already unbound.",
                    )
                    RecordingCardUnbindTokenStatus.MALFORMED -> finishUnbindWithError(
                        "RECORDING_CARD_UNBIND_BINDING_INFO_INVALID",
                        "Recording-card binding information was malformed.",
                    )
                    RecordingCardUnbindTokenStatus.CONFLICT -> finishUnbindWithError(
                        "RECORDING_CARD_UNBIND_BINDING_CONFLICT",
                        "Recording card is bound to a different phone.",
                    )
                }
            }

            override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {
                finishUnbindWithError(
                    "RECORDING_CARD_UNBIND_BINDING_READ_FAILED",
                    "Recording-card binding information could not be read.",
                )
            }

            override fun notImplemented() {
                finishUnbindWithError(
                    "RECORDING_CARD_UNBIND_BINDING_READ_FAILED",
                    "Recording-card binding information could not be read.",
                )
            }
        }
        sendCommand(
            COMMAND_GET_BINDING_INFO,
            byteArrayOf(),
            callback,
            allowDuringUnbind = true,
        ) { response ->
            CommandResponse.Complete(response.copyOf())
        }
    }

    private fun sendUnbindCommand(deleteDeviceFiles: Boolean) {
        val payload = recordingCardUnbindPayload(deleteDeviceFiles)
        val callback = object : MethodChannel.Result {
            override fun success(result: Any?) {
                val acknowledgement = result as? ByteArray
                when {
                    acknowledgement == null || acknowledgement.isEmpty() -> finishUnbindWithError(
                        "RECORDING_CARD_UNBIND_ACK_MALFORMED",
                        "Recording-card unbind acknowledgement was malformed.",
                    )
                    !recordingCardUnbindAckAccepted(acknowledgement) -> finishUnbindWithError(
                        "RECORDING_CARD_UNBIND_REJECTED",
                        "Recording card rejected the unbind request.",
                    )
                    else -> finishUnbindSuccessfully()
                }
            }

            override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {
                finishUnbindWithError(
                    "RECORDING_CARD_UNBIND_FAILED",
                    "Recording-card unbind failed.",
                )
            }

            override fun notImplemented() {
                finishUnbindWithError(
                    "RECORDING_CARD_UNBIND_FAILED",
                    "Recording-card unbind failed.",
                )
            }
        }
        unbindDisconnectExpected = true
        val dispatched = sendCommand(
            COMMAND_BIND_DEVICE,
            payload,
            callback,
            allowDuringUnbind = true,
        ) { response ->
            CommandResponse.Complete(response.copyOf())
        }
        if (!dispatched) unbindDisconnectExpected = false
    }

    private fun finishUnbindSuccessfully() {
        val result = unbindResult ?: return
        unbindResult = null
        unbindDisconnectExpected = false
        clearDeviceRuntimeAfterUnbind()
        result.success(deviceStateMap())
    }

    private fun finishUnbindWithError(code: String, message: String) {
        val result = unbindResult ?: return
        unbindResult = null
        unbindDisconnectExpected = false
        result.error(code, message, null)
    }

    private fun hasActiveTransferOrWifiOperation(): Boolean =
        offlineCapture != null ||
            recordingCardWifiOperationOwnsTransport(
                attemptOwned = wifiAttemptOwned,
                preparationInFlight = wifiPrepareResult != null,
                hotspotDisableInFlight = wifiHotspotDisableInFlight,
                joinInFlight = wifiJoinResult != null,
                joinCallbackRetained = wifiJoinCallback != null,
                joinNetworkRetained = wifiJoinNetwork != null,
                sessionRetained = wifiSession != null || wifiSessionOperationInFlight,
                bleDisconnectExpected = wifiBleDisconnectExpected,
                handoffReady = wifiHandoffReady,
            ) ||
            wifiActiveCapture != null ||
            wifiDownloadFileKey != null

    private fun clearDeviceRuntimeAfterUnbind() {
        cancelConnectDeadline()
        stopScan()
        clearAllPendingCommands()
        requestedFingerprint = null
        requestedBindingToken = null
        requestedExpectedSerialNumber = null
        finishWifiPreparation("RECORDING_CARD_WIFI_DISCONNECTED")
        closeWifiSessionInternal(deleteActivePart = true, cancelled = true)
        wifiAttemptOwned = false
        wifiBleDisconnectExpected = false
        wifiHandoffReady = false
        closeGatt()
        discoveredDevices.clear()
        discoveredRows.clear()
        connectionState = "disconnected"
        connectionStage = "idle"
        statusMessage = "录音卡已取消绑定"
        safeFingerprint = null
        deviceName = null
        batteryPercent = null
        storageTotalBytes = null
        storageFreeBytes = null
        storageUsedBytes = null
        firmwareVersion = null
        deviceModel = null
        recordingFormat = "unknown"
        resetRecordingRuntime("runtimeSnapshot")
        wifiSupported = null
        wifiFirmwareVersion = null
        lastInfoRefreshedAt = null
        fileDirectory.commit(fileDirectory.beginScan())
        emitSnapshot()
    }

    private fun runHandshakeStep(command: Int, payload: ByteArray, next: () -> Unit) {
        if (!handshake.inProgress || connectResult == null) return
        handshakeCommand = command
        val callback = object : MethodChannel.Result {
            override fun success(result: Any?) {
                if (handshake.inProgress && connectResult != null) next()
            }

            override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {
                if (!handshake.inProgress || connectResult == null) return
                failConnect(errorCode, errorMessage ?: "Recording-card secure handshake failed.")
            }

            override fun notImplemented() {
                failConnect("RECORDING_CARD_HANDSHAKE_FAILED", "Recording-card secure handshake failed.")
            }
        }
        sendCommand(command, payload, callback) { response ->
            if (command == COMMAND_BIND_DEVICE) {
                recordingCardBindingAcknowledgementFailure(response)?.let { throw it }
            }
            if (command == COMMAND_DEVICE_INFO) applyDeviceInfo(response)
            CommandResponse.Complete(Unit)
        }
    }

    private fun completeSecureHandshake() {
        if (connectResult == null) return
        resetHandshake()
        cancelConnectDeadline()
        cancelGattRetry()
        wifiBleDisconnectExpected = false
        wifiHandoffReady = false
        connectionState = "connected"
        connectionStage = "connected"
        statusMessage = "录音卡已连接"
        lastInfoRefreshedAt = isoNow()
        connectResult?.success(deviceStateMap())
        connectResult = null
        pendingGattDevice = null
        pendingGattFingerprint = null
        gattRetryCount = 0
        gattLinkEstablished = false
        requestedBindingToken = null
        requestedExpectedSerialNumber = null
        debugLog("secure handshake completed")
        emitSnapshot()
        readRecordingState(null)
    }

    private fun currentTimePayload(): ByteArray {
        val now = java.util.Calendar.getInstance()
        return byteArrayOf(
            (now.get(java.util.Calendar.YEAR) - 2000).coerceIn(0, 255).toByte(),
            (now.get(java.util.Calendar.MONTH) + 1).toByte(),
            now.get(java.util.Calendar.DAY_OF_MONTH).toByte(),
            now.get(java.util.Calendar.HOUR_OF_DAY).toByte(),
            now.get(java.util.Calendar.MINUTE).toByte(),
            now.get(java.util.Calendar.SECOND).toByte(),
        )
    }

    private fun handleCharacteristicValue(characteristic: BluetoothGattCharacteristic, value: ByteArray) {
        when (characteristic.uuid) {
            CONTROL_NOTIFY_UUID -> {
                val batch = frameDecoder.push(value)
                if (batch.issues.isNotEmpty() || batch.awaitingBytes != null) {
                    debugLog(
                        "control decode bytes=${value.size} packets=${batch.packets.size} " +
                            "issues=${batch.issues.size} awaiting=${batch.awaitingBytes ?: 0} " +
                            "buffered=${batch.bufferedByteCount}",
                    )
                }
                batch.packets.forEach(::handleControlPacket)
                if (batch.issues.any { it.requestsBindingInfoRetry }) {
                    recoverBindingInfoAfterControlFault()
                }
            }
            OFFLINE_NOTIFY_UUID -> appendOfflineData(value)
        }
    }

    private fun refreshDeviceInfo(result: MethodChannel.Result?) {
        val requestRevision = recordingRevision
        sendCommand(COMMAND_DEVICE_INFO, byteArrayOf(), result) { payload ->
            applyDeviceInfo(
                payload,
                applyRecordingState = requestRevision == recordingRevision,
            )
            CommandResponse.Complete(runtimeSnapshotMap())
        }
    }

    private fun readRecordingState(result: MethodChannel.Result?) {
        val requestRevision = recordingRevision
        sendCommand(COMMAND_RECORDING_INFO, byteArrayOf(), result) { payload ->
            if (requestRevision == recordingRevision) applyRecordingInfo(payload)
            CommandResponse.Complete(recordingInfoMap())
        }
    }

    private fun recordingCommand(
        command: Int,
        targetState: String,
        result: MethodChannel.Result,
    ) {
        sendCommand(command, byteArrayOf(), result) { payload ->
            val parsed = recordingCardRecordingCommandPayload(command, payload)
                ?: throw IllegalStateException("recording command rejected")
            if (parsed.state != targetState) throw IllegalStateException("recording command state mismatch")
            applyRecordingPayload(parsed, "command")
            emitSnapshot()
            CommandResponse.Complete(recordingInfoMap())
        }
    }

    private fun scanFiles(result: MethodChannel.Result) {
        val fileRows = fileDirectory.beginScan()
        sendCommand(COMMAND_LIST_FILES, byteArrayOf(), result) { payload ->
            when (payload.firstOrNull()?.toInt()) {
                0x00 -> {
                    parseFileRow(payload, fileRows.size)?.let(fileRows::add)
                    CommandResponse.Wait
                }
                0x02 -> {
                    val files = fileDirectory.commit(fileRows)
                    emitSnapshot()
                    CommandResponse.Complete(mapOf("files" to files))
                }
                else -> CommandResponse.Wait
            }
        }
    }

    private fun downloadFile(arguments: Map<*, *>?, result: MethodChannel.Result) {
        if (offlineCharacteristic == null) {
            result.error(
                "RECORDING_CARD_OFFLINE_TRANSFER_UNAVAILABLE",
                "Recording-card offline transfer notifications are unavailable.",
                null,
            )
            return
        }
        if (offlineCapture != null || wifiDownloadFileKey != null || bleSilenceBarrier.active) {
            result.error(
                "RECORDING_CARD_DOWNLOAD_IN_PROGRESS",
                "A recording-card file download is already running.",
                null,
            )
            return
        }
        val request = parseDownloadRequest(arguments)
        if (request == null) {
            result.error(
                "RECORDING_CARD_INVALID_FILE",
                "Recording-card file payload is invalid.",
                null,
            )
            return
        }
        val plannedNativeFileId = arguments?.get("plannedNativeFileId") as? String
        if (plannedNativeFileId != null && !isSafeNativeFileId(plannedNativeFileId)) {
            result.error(
                "RECORDING_CARD_LOCAL_TARGET_INVALID",
                "Recording-card private file target is invalid.",
                null,
            )
            return
        }
        val capture = createOfflineCapture(
            request,
            plannedNativeFileId = plannedNativeFileId,
        )
        if (capture == null) {
            result.error(
                "RECORDING_CARD_LOCAL_STORAGE_FAILED",
                "Recording-card download could not prepare private storage.",
                null,
            )
            return
        }
        offlineCapture = capture
        val queued = sendCommand(
            COMMAND_REQUEST_FILE,
            fileRequestPayload(request.deviceFilename),
            result,
        ) { payload ->
            val acknowledgedSize = resolveAcknowledgedSize(payload, request)
            val capture = offlineCapture ?: throw FileRequestFailure(
                "RECORDING_CARD_FILE_REQUEST_STATE_LOST",
                "Recording-card file capture state was lost.",
            )
            capture.request = request.withTargetBytes(acknowledgedSize)
            capture.directorySizeMismatch = request.directorySizeBytes != null &&
                request.directorySizeBytes != acknowledgedSize
            capture.acknowledged = true
            scheduleDownloadTimeouts(capture.request.targetBytes)
            emitTransferProgress(capture, force = true)
            val earlyChunks = capture.preAckChunks.toList()
            capture.preAckChunks.clear()
            capture.preAckBytes = 0L
            earlyChunks.forEach(::appendOfflineData)
            CommandResponse.Wait
        }
        if (!queued) cleanupOfflineCapture(deletePart = true)
    }

    private fun resolveAcknowledgedSize(payload: ByteArray, request: DownloadRequest): Long {
        val status = payload.firstOrNull()?.toInt()?.and(0xff)
            ?: throw FileRequestFailure(
                "RECORDING_CARD_FILE_REQUEST_ACK_MALFORMED",
                "Recording-card file request acknowledgement was malformed.",
            )
        if (status != 0x00) {
            throw FileRequestFailure(
                "RECORDING_CARD_FILE_REQUEST_REJECTED",
                "Recording-card file request was rejected.",
            )
        }
        if (payload.size == 1) {
            return request.directorySizeBytes?.takeIf(::isValidDeviceFileSize)
                ?: throw FileRequestFailure(
                    "RECORDING_CARD_FILE_REQUEST_LENGTH_UNAVAILABLE",
                    "Recording-card file length is unavailable.",
                )
        }
        if (payload.size < 5) {
            throw FileRequestFailure(
                "RECORDING_CARD_FILE_REQUEST_ACK_MALFORMED",
                "Recording-card file request acknowledgement was malformed.",
            )
        }
        val littleEndianSize = readUInt32LittleEndian(payload, 1)
        val bigEndianSize = readUInt32(payload, 1)
        val acknowledgedSize = resolveRecordingCardDeviceFileSize(
            littleEndianSize,
            bigEndianSize,
        )?.first ?: throw FileRequestFailure(
                "RECORDING_CARD_FILE_REQUEST_LENGTH_UNAVAILABLE",
                "Recording-card file length is unavailable.",
            )
        if (request.sizeConfidence == "trusted" &&
            request.directorySizeBytes != null &&
            request.directorySizeBytes != acknowledgedSize
        ) {
            throw FileRequestFailure(
                "RECORDING_CARD_FILE_REQUEST_LENGTH_MISMATCH",
                "Recording-card file length did not match the fresh directory.",
            )
        }
        return acknowledgedSize
    }

    private fun cancelFileTransfer(result: MethodChannel.Result) {
        if (wifiPrepareResult != null || wifiHotspotDisableInFlight ||
            wifiSessionOperationInFlight || wifiSession != null
        ) {
            cancelWifiSession(result)
            return
        }
        if (offlineCapture == null || !pendingCommands.containsKey(COMMAND_REQUEST_FILE)) {
            result.error(
                "RECORDING_CARD_TRANSFER_NOT_ACTIVE",
                "No recording-card BLE transfer is active.",
                null,
            )
            return
        }
        completeCommandWithError(
            COMMAND_REQUEST_FILE,
            "RECORDING_CARD_TRANSFER_CANCELLED",
            "Recording-card file transfer was cancelled.",
            retireTransport = true,
        )
        result.success(mapOf("cancelled" to true))
        emitSnapshot()
    }

    private fun prepareWifiTransfer(arguments: Map<*, *>?, result: MethodChannel.Result) {
        if (!recordingCardLegacyWifiOperationCanBegin(wifiAttemptOwned)) {
            result.error(
                "RECORDING_CARD_WIFI_SESSION_BUSY",
                "A recovery-owned recording-card Wi-Fi session is active.",
                null,
            )
            return
        }
        val filename = arguments?.get("deviceFilename") as? String
        if (filename == null || recordingCardFileRequestPayload(filename) == null) {
            result.error("RECORDING_CARD_INVALID_FILE", "Recording-card file payload is invalid.", null)
            return
        }
        beginWifiPreparation(result)
    }

    private fun prepareWifiSession(arguments: Map<*, *>?, result: MethodChannel.Result) {
        val rows = arguments?.get("files") as? List<*>
        if (rows.isNullOrEmpty() || rows.any { row ->
                @Suppress("UNCHECKED_CAST")
                parseDownloadRequest(row as? Map<*, *>) == null
            }
        ) {
            result.error(
                "RECORDING_CARD_INVALID_FILE",
                "Recording-card Wi-Fi batch payload is invalid.",
                null,
            )
            return
        }
        beginWifiPreparation(result)
    }

    private fun beginWifiPreparation(result: MethodChannel.Result) {
        if (!isReady()) {
            result.error("RECORDING_CARD_NOT_CONNECTED", "Recording card is not connected.", null)
            return
        }
        if (wifiSupported == false) {
            result.error("RECORDING_CARD_WIFI_UNAVAILABLE", "Recording-card firmware does not advertise Wi-Fi transfer.", null)
            return
        }
        if (wifiPrepareResult != null || wifiHotspotDisableInFlight) {
            result.error("RECORDING_CARD_WIFI_PREPARE_IN_PROGRESS", "Recording-card Wi-Fi preparation is already running.", null)
            return
        }
        discardWifiCredentialLeaseUnlessCurrent()
        wifiPreparationAcknowledged = false
        wifiHotspotEnableMayHaveBeenDispatched = false
        wifiBleDisconnectExpected = false
        wifiHandoffReady = false
        wifiPreparationGeneration += 1
        val preparationGeneration = wifiPreparationGeneration
        wifiPrepareResult = result
        sendWifiEnable(
            allowResetRecovery = true,
            preparationGeneration = preparationGeneration,
        )
    }

    private fun sendWifiEnable(
        allowResetRecovery: Boolean,
        preparationGeneration: Long,
    ) {
        if (!ownsWifiPreparation(preparationGeneration)) return
        debugLog("wifi enable attempt resetRecoveryAllowed=$allowResetRecovery")
        val callback = object : MethodChannel.Result {
            override fun success(result: Any?) {
                if (!ownsWifiPreparation(preparationGeneration)) return
                wifiPreparationAcknowledged = true
                wifiHotspotEnableMayHaveBeenDispatched = true
                wifiBleDisconnectExpected = true
                scheduleWifiCredentialTimeout(preparationGeneration)
                finishWifiPreparationIfPossible(preparationGeneration)
            }

            override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {
                if (!ownsWifiPreparation(preparationGeneration)) return
                if (errorCode == "RECORDING_CARD_COMMAND_REJECTED") {
                    wifiHotspotEnableMayHaveBeenDispatched = false
                }
                if (recordingCardCanRecoverWifiEnableWithReset(allowResetRecovery)) {
                    beginWifiResetRecovery(preparationGeneration)
                } else {
                    finishWifiPreparation(
                        if (errorCode == "RECORDING_CARD_COMMAND_TIMEOUT") {
                            "RECORDING_CARD_WIFI_PREPARE_TIMEOUT"
                        } else {
                            "RECORDING_CARD_WIFI_FIRMWARE_INCOMPATIBLE"
                        },
                        preparationGeneration,
                    )
                }
            }

            override fun notImplemented() {
                error("RECORDING_CARD_WIFI_PREPARE_FAILED", null, null)
            }
        }
        val dispatched = sendCommand(COMMAND_ENABLE_WIFI, byteArrayOf(1), callback) { payload ->
            if (payload.firstOrNull()?.toInt()?.and(0xff) != 0) {
                throw IllegalStateException("wifi enable rejected")
            }
            CommandResponse.Complete(Unit)
        }
        if (dispatched && ownsWifiPreparation(preparationGeneration)) {
            wifiHotspotEnableMayHaveBeenDispatched = true
        }
    }

    private fun beginWifiResetRecovery(preparationGeneration: Long) {
        if (!ownsWifiPreparation(preparationGeneration) || !isReady()) {
            finishWifiPreparation(
                "RECORDING_CARD_WIFI_DISCONNECTED",
                preparationGeneration,
            )
            return
        }
        wifiPreparationAcknowledged = false
        wifiBleDisconnectExpected = false
        wifiHandoffReady = false
        debugLog("wifi reset recovery started firmware=${firmwareVersion ?: "unknown"}")
        val callback = object : MethodChannel.Result {
            override fun success(result: Any?) {
                if (!ownsWifiPreparation(preparationGeneration)) return
                wifiHotspotEnableMayHaveBeenDispatched = false
                debugLog("wifi reset acknowledged")
                mainHandler.postDelayed(
                    {
                        sendWifiEnable(
                            allowResetRecovery = false,
                            preparationGeneration = preparationGeneration,
                        )
                    },
                    WIFI_RESET_RECOVERY_DELAY_MS,
                )
            }

            override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {
                finishWifiPreparation(
                    "RECORDING_CARD_WIFI_FIRMWARE_INCOMPATIBLE",
                    preparationGeneration,
                )
            }

            override fun notImplemented() {
                error("RECORDING_CARD_WIFI_PREPARE_FAILED", null, null)
            }
        }
        sendCommand(COMMAND_ENABLE_WIFI, byteArrayOf(0), callback) { payload ->
            if (payload.firstOrNull()?.toInt()?.and(0xff) != 0) {
                throw IllegalStateException("wifi reset rejected")
            }
            CommandResponse.Complete(Unit)
        }
    }

    private fun verifyWifiHandoff(result: MethodChannel.Result) {
        val network = wifiJoinNetwork
        val callback = wifiJoinCallback
        val manager = context.getSystemService(ConnectivityManager::class.java)
        if (!wifiHandoffReady || network == null || callback == null || manager == null) {
            result.success(mapOf("status" to "networkUnavailable"))
            return
        }
        val ready = recorderCardWifiNetworkIsReady(network, callback, manager)
        result.success(mapOf("status" to if (ready) "ready" else "networkUnavailable"))
    }

    private fun joinWifiNetwork(arguments: Map<*, *>?, result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            result.error(
                "RECORDING_CARD_WIFI_JOIN_UNAVAILABLE",
                "System recording-card Wi-Fi join requires Android 10 or newer.",
                null,
            )
            return
        }
        if (wifiJoinResult != null || wifiJoinCallback != null) {
            result.error(
                "RECORDING_CARD_WIFI_JOIN_IN_PROGRESS",
                "A recording-card Wi-Fi join is already active.",
                null,
            )
            return
        }
        val credentials = pendingWifiCredentials
        val ssid = arguments?.get("ssid") as? String
        val password = arguments?.get("password") as? String
        if (!wifiHandoffReady || credentials == null ||
            ssid != credentials.ssid || password != credentials.password
        ) {
            result.error(
                "RECORDING_CARD_WIFI_CREDENTIALS_INVALID",
                "Recording-card Wi-Fi credentials are invalid.",
                null,
            )
            return
        }
        wifiJoinNetwork?.let {
            result.success(true)
            return
        }
        val manager = context.getSystemService(ConnectivityManager::class.java)
        if (manager == null) {
            result.error(
                "RECORDING_CARD_WIFI_JOIN_UNAVAILABLE",
                "Android Wi-Fi network service is unavailable.",
                null,
            )
            return
        }
        val specifier = try {
            WifiNetworkSpecifier.Builder()
                .setSsid(ssid)
                .setWpa2Passphrase(password)
                .build()
        } catch (_: IllegalArgumentException) {
            result.error(
                "RECORDING_CARD_WIFI_CREDENTIALS_INVALID",
                "Recording-card Wi-Fi credentials are invalid.",
                null,
            )
            return
        }
        val request = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
            .removeCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .setNetworkSpecifier(specifier)
            .build()
        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                mainHandler.post {
                    if (wifiJoinCallback !== this) return@post
                    wifiJoinNetwork = network
                    wifiJoinResult?.success(true)
                    wifiJoinResult = null
                }
            }

            override fun onUnavailable() {
                mainHandler.post {
                    if (wifiJoinCallback !== this) return@post
                    val pending = wifiJoinResult
                    releaseWifiNetworkRequest(cancelPending = false)
                    pending?.error(
                        "RECORDING_CARD_WIFI_JOIN_DENIED",
                        "Recording-card Wi-Fi join was cancelled or unavailable.",
                        null,
                    )
                }
            }

            override fun onLost(network: Network) {
                mainHandler.post {
                    if (wifiJoinCallback !== this) return@post
                    if (wifiJoinNetwork == network) {
                        wifiJoinNetwork = null
                        emitWifiInterruption("RECORDING_CARD_WIFI_NETWORK_LOST")
                        wifiSessionCancellationRequested = true
                        closeWifiSessionInternal(
                            deleteActivePart = false,
                            cancelled = true,
                            cleanupMode = RecordingCardWifiSessionCleanupMode
                                .FAILURE_AWAITING_ATTEMPT_TEARDOWN,
                        )
                    }
                }
            }
        }
        wifiJoinCallback = callback
        wifiJoinResult = result
        try {
            manager.requestNetwork(request, callback, 30_000)
        } catch (_: SecurityException) {
            releaseWifiNetworkRequest(cancelPending = false)
            result.error(
                "RECORDING_CARD_WIFI_PERMISSION_REQUIRED",
                "Nearby Wi-Fi permission is required for recording-card transfer.",
                null,
            )
        } catch (_: RuntimeException) {
            releaseWifiNetworkRequest(cancelPending = false)
            result.error(
                "RECORDING_CARD_WIFI_JOIN_FAILED",
                "Recording-card Wi-Fi join could not start.",
                null,
            )
        }
    }

    private fun beginWifiAttempt(arguments: Map<*, *>?, result: MethodChannel.Result) {
        val batchId = arguments?.get("recoveryBatchId") as? String
        val attemptId = arguments?.get("attemptId") as? String
        if (batchId.isNullOrBlank() || batchId.length > 160 ||
            attemptId == null || !Regex("^[a-zA-Z0-9_-]{1,128}$").matches(attemptId)) {
            result.error("RECORDING_CARD_WIFI_ATTEMPT_INVALID", "Invalid Wi-Fi attempt identity.", null)
            return
        }
        if (!recordingCardWifiAttemptCanBegin(
                attemptOwned = wifiAttemptOwned,
                preparationInFlight = wifiPrepareResult != null,
                hotspotDisableInFlight = wifiHotspotDisableInFlight,
                joinInFlight = wifiJoinResult != null,
                joinCallbackRetained = wifiJoinCallback != null,
                joinNetworkRetained = wifiJoinNetwork != null,
                sessionRetained = wifiSessionOperationInFlight || wifiSession != null,
                bleDisconnectExpected = wifiBleDisconnectExpected,
                handoffReady = wifiHandoffReady,
            )
        ) {
            result.error("RECORDING_CARD_WIFI_SESSION_BUSY", "Previous Wi-Fi session is still active.", null)
            return
        }
        wifiRecoveryBatchId = batchId
        wifiAttemptId = attemptId
        wifiAttemptOwned = true
        wifiInterruptionCode = null
        wifiLastActivityAt = SystemClock.elapsedRealtime()
        result.success(true)
    }

    private fun settleWifiRecovery(arguments: Map<*, *>?, result: MethodChannel.Result) {
        if (!recordingCardWifiRecoverySettlementIsValid(
                batchId = arguments?.get("recoveryBatchId") as? String,
                attemptId = arguments?.get("attemptId") as? String,
                safeDeviceFingerprint = arguments?.get("safeDeviceFingerprint") as? String,
            )
        ) {
            result.error(
                "RECORDING_CARD_WIFI_ATTEMPT_INVALID",
                "Invalid Wi-Fi recovery settlement identity.",
                null,
            )
            return
        }
        result.success(true)
    }

    private fun wifiRecoverySnapshot(): Map<String, Any> {
        val session = wifiSession
        val active = recordingCardWifiAttemptIsActive(
            attemptOwned = wifiAttemptOwned,
            preparationInFlight = wifiPrepareResult != null,
            hotspotDisableInFlight = wifiHotspotDisableInFlight,
            joinInFlight = wifiJoinResult != null,
            joinCallbackRetained = wifiJoinCallback != null,
            joinNetworkRetained = wifiJoinNetwork != null,
            sessionActive = session != null && !session.closed && !session.cancelled &&
                SystemClock.elapsedRealtime() - wifiLastActivityAt < 30_000L,
            bleDisconnectExpected = wifiBleDisconnectExpected,
            handoffReady = wifiHandoffReady,
        )
        return mutableMapOf<String, Any>(
            "type" to "wifi_session",
            "batchId" to (wifiRecoveryBatchId ?: ""),
            "attemptId" to (wifiAttemptId ?: ""),
            "active" to active,
        ).apply { wifiInterruptionCode?.let { put("failureCode", it) } }
    }

    private fun emitWifiInterruption(code: String) {
        wifiInterruptionCode = code
        val event = wifiRecoverySnapshot().toMutableMap().apply { put("active", false) }
        mainHandler.post { if (!disposed) eventSink?.success(event) }
    }

    private fun recoverWifiDownload(arguments: Map<*, *>?, result: MethodChannel.Result) {
        recoverCommittedDownload(
            arguments = arguments,
            invalidTargetCode = "RECORDING_CARD_WIFI_TARGET_INVALID",
            invalidTargetMessage = "Invalid private Wi-Fi target.",
            recoveryFailureCode = "RECORDING_CARD_WIFI_LOCAL_RECOVERY_FAILED",
            recoveryFailureMessage = "Private Wi-Fi file could not be verified.",
            result = result,
        )
    }

    private fun recoverBluetoothDownload(arguments: Map<*, *>?, result: MethodChannel.Result) {
        recoverCommittedDownload(
            arguments = arguments,
            invalidTargetCode = "RECORDING_CARD_BLUETOOTH_TARGET_INVALID",
            invalidTargetMessage = "Invalid private Bluetooth target.",
            recoveryFailureCode = "RECORDING_CARD_BLUETOOTH_LOCAL_RECOVERY_FAILED",
            recoveryFailureMessage = "Private Bluetooth file could not be verified.",
            result = result,
        )
    }

    private fun recoverCommittedDownload(
        arguments: Map<*, *>?,
        invalidTargetCode: String,
        invalidTargetMessage: String,
        recoveryFailureCode: String,
        recoveryFailureMessage: String,
        result: MethodChannel.Result,
    ) {
        val request = parseDownloadRequest(arguments)
        val fileId = arguments?.get("plannedNativeFileId") as? String
        if (request == null || fileId == null || !isSafeNativeFileId(fileId)) {
            result.error(invalidTargetCode, invalidTargetMessage, null)
            return
        }
        Thread {
            try {
                val directory = File(context.filesDir, "recordings/recording-card")
                val finalFile = File(directory, "$fileId.${request.format}")
                val partFile = File(directory, "$fileId.${request.format}.part")
                val recoveryDecision = recordingCardCommittedDownloadRecoveryDecision(
                    finalFileExists = finalFile.isFile,
                    finalFileSize = finalFile.takeIf(File::isFile)?.length(),
                    expectedSize = request.directorySizeBytes,
                )
                if (recoveryDecision ==
                    RecordingCardCommittedDownloadRecoveryDecision.CLEAN_AND_REDOWNLOAD
                ) {
                    if (finalFile.exists() && !finalFile.delete()) {
                        throw IOException("invalid committed file could not be removed")
                    }
                    if (partFile.exists() && !partFile.delete()) {
                        throw IOException("partial file could not be removed")
                    }
                    mainHandler.post { result.success(mapOf("exists" to false)) }
                    return@Thread
                }
                val digest = MessageDigest.getInstance("SHA-256")
                finalFile.inputStream().use { stream ->
                    val buffer = ByteArray(64 * 1024)
                    while (true) {
                        val count = stream.read(buffer)
                        if (count < 0) break
                        if (count > 0) digest.update(buffer, 0, count)
                    }
                }
                val recovered = buildMap<String, Any> {
                    put("exists", true)
                    put("localFileKey", request.localFileKey)
                    put("localFileId", fileId)
                    put("appPrivateUri", "app-private://recording-card/${finalFile.name}")
                    put("displayName", displayNameFor(request.deviceFilename, request.format))
                    request.durationSeconds?.let { put("durationSeconds", it) }
                    put("sizeBytes", finalFile.length())
                    put(
                        "contentHash",
                        digest.digest().joinToString("") { byte ->
                            "%02x".format(byte.toInt() and 0xff)
                        },
                    )
                    put("format", request.format)
                    put("mimeType", mimeTypeFor(request.format))
                }
                mainHandler.post { result.success(recovered) }
            } catch (_: Exception) {
                mainHandler.post {
                    result.error(
                        recoveryFailureCode,
                        recoveryFailureMessage,
                        null,
                    )
                }
            }
        }.start()
    }

    private fun openWifiSession(arguments: Map<*, *>?, result: MethodChannel.Result) {
        if (wifiHotspotDisableInFlight) {
            result.error(
                "RECORDING_CARD_WIFI_SESSION_BUSY",
                "Recording-card Wi-Fi session is shutting down.",
                null,
            )
            return
        }
        val existing = wifiSession
        if (existing != null && !existing.closed) {
            if (existing.ready && !wifiSessionOperationInFlight) {
                result.success(wifiSessionMap(existing))
            } else {
                result.error(
                    "RECORDING_CARD_WIFI_SESSION_BUSY",
                    "Recording-card Wi-Fi session is still opening.",
                    null,
                )
            }
            return
        }
        if (!beginWifiSessionOperation(result)) return
        Thread {
            try {
                if (wifiSessionCancellationRequested) throw cancelledWifiFailure()
                val session = openWifiSessionInternal(arguments?.get("sessionId") as? String)
                if (wifiSessionCancellationRequested) throw cancelledWifiFailure()
                completeWifiSessionOperation {
                    result.success(wifiSessionMap(session))
                }
            } catch (failure: WifiDownloadFailure) {
                emitWifiInterruption(failure.code)
                closeWifiSessionAfterFailure(deleteActivePart = true)
                completeWifiSessionOperation {
                    result.error(failure.code, failure.safeMessage, null)
                }
            } catch (_: Exception) {
                closeWifiSessionAfterFailure(deleteActivePart = true)
                completeWifiSessionOperation {
                    result.error(
                        "RECORDING_CARD_WIFI_NETWORK_UNAVAILABLE",
                        "Recording-card Wi-Fi endpoint is unavailable.",
                        null,
                    )
                }
            }
        }.start()
    }

    private fun downloadFileInWifiSession(
        arguments: Map<*, *>?,
        result: MethodChannel.Result,
    ) {
        runWifiDownload(arguments, result, requireExistingSession = true)
    }

    private fun downloadFileOverWifi(arguments: Map<*, *>?, result: MethodChannel.Result) {
        if (!recordingCardLegacyWifiOperationCanBegin(wifiAttemptOwned)) {
            result.error(
                "RECORDING_CARD_WIFI_SESSION_BUSY",
                "A recovery-owned recording-card Wi-Fi session is active.",
                null,
            )
            return
        }
        runWifiDownload(arguments, result, requireExistingSession = false)
    }

    private fun runWifiDownload(
        arguments: Map<*, *>?,
        result: MethodChannel.Result,
        requireExistingSession: Boolean,
    ) {
        if (offlineCapture != null || wifiActiveCapture != null) {
            result.error(
                "RECORDING_CARD_DOWNLOAD_IN_PROGRESS",
                "A recording-card file download is already running.",
                null,
            )
            return
        }
        val request = parseDownloadRequest(arguments)
        if (request == null) {
            result.error(
                "RECORDING_CARD_INVALID_FILE",
                "Recording-card file payload is invalid.",
                null,
            )
            return
        }
        val existingSession = wifiSession?.takeUnless { it.closed }
        if (requireExistingSession && existingSession == null) {
            result.error(
                "RECORDING_CARD_WIFI_SESSION_NOT_OPEN",
                "Recording-card Wi-Fi session is not open.",
                null,
            )
            return
        }
        val requestedSessionId = arguments?.get("sessionId") as? String
        if (requestedSessionId != null &&
            existingSession != null &&
            requestedSessionId != existingSession.id
        ) {
            result.error(
                "RECORDING_CARD_WIFI_SESSION_MISMATCH",
                "Recording-card Wi-Fi session does not match the active session.",
                null,
            )
            return
        }
        if (!beginWifiSessionOperation(result)) return
        val capture = createOfflineCapture(
            request,
            transferTransport = "wifi",
            plannedNativeFileId = arguments?.get("plannedNativeFileId") as? String,
            batchId = safeBatchId(arguments?.get("batchId")),
            batchFileIndex = asNonNegativeInt(arguments?.get("fileIndex")),
            batchFileCount = asPositiveInt(arguments?.get("fileCount")),
            aggregateReceivedBase = asNonNegativeLong(arguments?.get("aggregateReceivedBytes")),
            aggregateTotalBytes = asNonZeroLong(arguments?.get("aggregateTotalBytes")),
        )
        if (capture == null) {
            RecordingCardSyncService.setWifiTransferEnabled(context, false)
            wifiSessionOperationInFlight = false
            result.error(
                "RECORDING_CARD_LOCAL_STORAGE_FAILED",
                "Recording-card Wi-Fi download could not prepare private storage.",
                null,
            )
            return
        }
        wifiDownloadFileKey = request.localFileKey
        wifiActiveCapture = capture
        emitSnapshot()
        val autoCloseSession = existingSession == null
        Thread {
            try {
                val session = existingSession ?: openWifiSessionInternal(null)
                val downloadedFile = performWifiDownloadInSession(session, capture)
                if (autoCloseSession) closeWifiSessionInternal(deleteActivePart = false)
                wifiActiveCapture = null
                completeWifiSessionOperation {
                    wifiDownloadFileKey = null
                    emitSnapshot()
                    result.success(downloadedFile)
                }
            } catch (failure: WifiDownloadFailure) {
                if (failure.invalidatesSession) emitWifiInterruption(failure.code)
                val terminalStage = if (failure.code == "RECORDING_CARD_WIFI_TRANSFER_CANCELLED") {
                    "cancelled"
                } else {
                    "failed"
                }
                if (capture.transferStage != terminalStage) {
                    capture.transferStage = terminalStage
                    emitWifiTransferProgress(capture, force = true)
                }
                cleanupWifiCapture(capture)
                wifiActiveCapture = null
                if (autoCloseSession || failure.invalidatesSession) {
                    closeWifiSessionAfterFailure(deleteActivePart = false)
                }
                completeWifiSessionOperation {
                    wifiDownloadFileKey = null
                    emitSnapshot()
                    result.error(failure.code, failure.safeMessage, null)
                }
            } catch (_: SocketTimeoutException) {
                if (capture.transferStage != "cancelled") {
                    capture.transferStage = "failed"
                    emitWifiTransferProgress(capture, force = true)
                }
                cleanupWifiCapture(capture)
                wifiActiveCapture = null
                closeWifiSessionAfterFailure(deleteActivePart = false)
                completeWifiSessionOperation {
                    wifiDownloadFileKey = null
                    emitSnapshot()
                    result.error(
                        "RECORDING_CARD_WIFI_DOWNLOAD_TIMEOUT",
                        "Recording-card Wi-Fi download timed out.",
                        null,
                    )
                }
            } catch (_: Exception) {
                if (capture.transferStage != "cancelled") {
                    capture.transferStage = "failed"
                    emitWifiTransferProgress(capture, force = true)
                }
                cleanupWifiCapture(capture)
                wifiActiveCapture = null
                closeWifiSessionAfterFailure(deleteActivePart = false)
                completeWifiSessionOperation {
                    wifiDownloadFileKey = null
                    emitSnapshot()
                    result.error(
                        "RECORDING_CARD_WIFI_TRANSFER_FAILED",
                        "Recording-card Wi-Fi download failed.",
                        null,
                    )
                }
            }
        }.start()
    }

    private fun openWifiSessionInternal(requestedSessionId: String?): WifiSession {
        if (wifiSessionCancellationRequested) throw cancelledWifiFailure()
        wifiSession?.takeUnless { it.closed }?.let { return it }
        val network = recorderCardWifiNetwork()
            ?: throw WifiDownloadFailure(
                "RECORDING_CARD_WIFI_NETWORK_UNAVAILABLE",
                "Recording-card Wi-Fi network is not connected.",
            )
        val socket = network.socketFactory.createSocket()
        val session = WifiSession(
            id = requestedSessionId?.takeIf(::isSafeSessionId)
                ?: "wifi-${UUID.randomUUID().toString().replace("-", "")}",
            socket = socket,
            mainFirmwareVersion = firmwareVersion,
            wifiFirmwareVersion = wifiFirmwareVersion,
            readBufferBytes = WIFI_READ_BUFFER_BYTES,
        )
        wifiSession = session
        try {
            if (wifiSessionCancellationRequested) {
                session.cancelled = true
                throw cancelledWifiFailure()
            }
            try {
                socket.connect(
                    InetSocketAddress(WIFI_TRANSFER_HOST, WIFI_TRANSFER_PORT),
                    WIFI_CONNECT_TIMEOUT_MS,
                )
            } catch (_: SocketTimeoutException) {
                throw WifiDownloadFailure(
                    "RECORDING_CARD_WIFI_NETWORK_UNAVAILABLE",
                    "Recording-card Wi-Fi endpoint is not reachable.",
                )
            } catch (_: IOException) {
                if (session.cancelled) throw cancelledWifiFailure()
                throw WifiDownloadFailure(
                    "RECORDING_CARD_WIFI_NETWORK_UNAVAILABLE",
                    "Recording-card Wi-Fi endpoint is not reachable.",
                )
            }
            session.input = socket.getInputStream()
            session.output = socket.getOutputStream()
            val status = readWifiPacket(session, WIFI_CONNECT_TIMEOUT_MS.toLong())
            if (status.command != COMMAND_WIFI_SESSION_STATUS ||
                status.payload.firstOrNull()?.toInt()?.and(0xff) != 0x00
            ) {
                throw WifiDownloadFailure(
                    "RECORDING_CARD_WIFI_HANDOFF_REJECTED",
                    "Recording-card Wi-Fi handoff was rejected.",
                )
            }
            sendWifiPacket(session, COMMAND_LIST_FILES, 0, byteArrayOf())
            val directory = linkedMapOf<String, WifiDirectoryEntry>()
            while (true) {
                val packet = try {
                    readWifiPacket(session, WIFI_DIRECTORY_TIMEOUT_MS)
                } catch (_: SocketTimeoutException) {
                    throw WifiDownloadFailure(
                        "RECORDING_CARD_WIFI_DIRECTORY_TIMEOUT",
                        "Recording-card Wi-Fi directory refresh timed out.",
                    )
                }
                if (packet.command != COMMAND_LIST_FILES) {
                    throw WifiDownloadFailure(
                        "RECORDING_CARD_WIFI_UNEXPECTED_COMMAND",
                        "Recording-card Wi-Fi returned an unexpected directory command.",
                    )
                }
                if (packet.payload.size == 1) {
                    when (packet.payload[0].toInt() and 0xff) {
                        0x02 -> break
                        0x01 -> throw WifiDownloadFailure(
                            "RECORDING_CARD_WIFI_DIRECTORY_REJECTED",
                            "Recording-card Wi-Fi directory refresh was rejected.",
                        )
                        else -> throw WifiDownloadFailure(
                            "RECORDING_CARD_WIFI_DIRECTORY_MALFORMED",
                            "Recording-card Wi-Fi directory response was malformed.",
                        )
                    }
                }
                val entry = parseWifiDirectoryEntry(packet.payload)
                    ?: throw WifiDownloadFailure(
                        "RECORDING_CARD_WIFI_DIRECTORY_MALFORMED",
                        "Recording-card Wi-Fi directory response was malformed.",
                    )
                val existing = directory[entry.filename]
                if (existing != null && existing != entry) {
                    throw WifiDownloadFailure(
                        "RECORDING_CARD_WIFI_DIRECTORY_CONFLICT",
                        "Recording-card Wi-Fi directory contained conflicting duplicate rows.",
                    )
                }
                if (existing == null) directory[entry.filename] = entry
            }
            session.directory = directory
            session.ready = true
            return session
        } catch (failure: WifiDownloadFailure) {
            throw failure
        } catch (_: SocketTimeoutException) {
            throw WifiDownloadFailure(
                "RECORDING_CARD_WIFI_NETWORK_TIMEOUT",
                "Recording-card Wi-Fi session timed out.",
            )
        } catch (_: RecordingCardWifiProtocolException) {
            throw WifiDownloadFailure(
                "RECORDING_CARD_WIFI_PROTOCOL_ERROR",
                "Recording-card Wi-Fi response frame is invalid.",
            )
        } catch (_: IOException) {
            if (session.cancelled) throw cancelledWifiFailure()
            throw WifiDownloadFailure(
                "RECORDING_CARD_WIFI_NETWORK_UNAVAILABLE",
                "Recording-card Wi-Fi endpoint is unavailable.",
            )
        } finally {
            if (!session.ready) {
                session.closed = true
                runCatching { socket.close() }
                if (wifiSession === session) wifiSession = null
            }
        }
    }

    private fun performWifiDownloadInSession(
        session: WifiSession,
        capture: OfflineCapture,
    ): Map<String, Any> {
        if (!session.ready || session.closed || session.cancelled) {
            throw WifiDownloadFailure(
                "RECORDING_CARD_WIFI_SESSION_NOT_OPEN",
                "Recording-card Wi-Fi session is not open.",
            )
        }
        val directoryEntry = session.directory[capture.request.deviceFilename]
            ?: throw WifiDownloadFailure(
                "RECORDING_CARD_WIFI_FILE_NOT_FOUND",
                "The selected recording no longer exists on the recording card.",
                invalidatesSession = false,
            )
        capture.request = capture.request.withDirectorySize(
            directoryEntry.sizeBytes,
            directoryEntry.sizeConfidence,
        )
        capture.wifiRateSampler?.reset(
            SystemClock.elapsedRealtime(),
            capture.receivedBytes,
        )
        capture.transferStage = "transferring"
        emitWifiTransferProgress(capture, force = true)
        sendWifiPacket(
            session,
            COMMAND_REQUEST_FILE,
            0,
            fileRequestPayload(capture.request.deviceFilename),
        )
        var payloadBudget: RecordingCardWifiPayloadBudget? = null
        var prematureEndDeadlineMs: Long? = null
        var tailSeekAttempted = false
        var tailSeekAwaitingData = false
        val overallDeadline = SystemClock.elapsedRealtime() +
            downloadOverallTimeoutMs(directoryEntry.sizeBytes)

        fun beginTailSeekOrFail() {
            prematureEndDeadlineMs = null
            val seekOffset = recordingCardWifiTailResumeOffset(
                profileAllowed = RecordingCardWifiCompatibility.isVerifiedFirmwareProfile(
                    session.mainFirmwareVersion,
                    session.wifiFirmwareVersion,
                ),
                receivedBytes = capture.receivedBytes,
                targetBytes = capture.request.targetBytes,
                alreadyAttempted = tailSeekAttempted,
            )
            val connectionHealthy = session.socket.isConnected &&
                !session.socket.isClosed &&
                !session.socket.isInputShutdown &&
                !session.socket.isOutputShutdown &&
                !session.closed &&
                !session.cancelled
            if (seekOffset == null || !connectionHealthy ||
                session.packetQueue.isNotEmpty() || session.decoder.pendingBytes != 0
            ) {
                throw WifiDownloadFailure(
                    "RECORDING_CARD_WIFI_DOWNLOAD_INCOMPLETE",
                    "Recording-card Wi-Fi file ended before its advertised size.",
                    invalidatesSession = false,
                )
            }
            tailSeekAttempted = true
            tailSeekAwaitingData = true
            session.dataSequenceGuard.reset()
            debugLog(
                "wifi tail seek recovery starting id=${capture.correlationId} " +
                    "seekBytes=$seekOffset remainingBytes=${capture.request.targetBytes - seekOffset}",
            )
            sendWifiPacket(
                session,
                COMMAND_REQUEST_FILE,
                0,
                fileRequestPayload(capture.request.deviceFilename, seekOffset),
            )
        }

        while (capture.receivedBytes < capture.request.targetBytes || !capture.acknowledged) {
            if (session.cancelled) throw cancelledWifiFailure()
            val nowMs = SystemClock.elapsedRealtime()
            val remainingOverall = overallDeadline - nowMs
            if (remainingOverall <= 0L) {
                throw WifiDownloadFailure(
                    "RECORDING_CARD_WIFI_DOWNLOAD_TIMEOUT",
                    "Recording-card Wi-Fi download timed out.",
                )
            }
            val remainingGrace = prematureEndDeadlineMs?.minus(nowMs)
            if (remainingGrace != null && remainingGrace <= 0L) {
                beginTailSeekOrFail()
                continue
            }
            val readTimeout = minOf(
                DOWNLOAD_INACTIVITY_TIMEOUT_MS,
                remainingOverall,
                remainingGrace ?: Long.MAX_VALUE,
            )
            val packet = try {
                readWifiPacket(session, readTimeout)
            } catch (_: SocketTimeoutException) {
                if (prematureEndDeadlineMs != null) {
                    beginTailSeekOrFail()
                    continue
                }
                throw WifiDownloadFailure(
                    if (remainingOverall <= DOWNLOAD_INACTIVITY_TIMEOUT_MS) {
                        "RECORDING_CARD_WIFI_DOWNLOAD_TIMEOUT"
                    } else {
                        "RECORDING_CARD_WIFI_DOWNLOAD_INACTIVITY_TIMEOUT"
                    },
                    "Recording-card Wi-Fi download stopped making progress.",
                )
            }
            if (packet.command != COMMAND_REQUEST_FILE) {
                throw WifiDownloadFailure(
                    "RECORDING_CARD_WIFI_UNEXPECTED_COMMAND",
                    "Recording-card Wi-Fi returned an unexpected file command.",
                )
            }
            val payload = packet.payload
            if (payload.size == 1 && (payload[0].toInt() and 0xff) == 0x02) {
                if (!capture.acknowledged) {
                    capture.request = capture.request.withTargetBytes(directoryEntry.sizeBytes)
                    capture.acknowledged = true
                }
                when (recordingCardWifiEndDecision(
                    receivedBytes = capture.receivedBytes,
                    targetBytes = capture.request.targetBytes,
                    graceExpired = false,
                )) {
                    RecordingCardWifiEndDecision.COMPLETE -> break
                    RecordingCardWifiEndDecision.AWAIT_TRAILING_DATA -> {
                        prematureEndDeadlineMs =
                            SystemClock.elapsedRealtime() + WIFI_PREMATURE_END_GRACE_MS
                        debugLog(
                            "wifi premature end observed id=${capture.correlationId} " +
                                "acceptedBytes=${capture.receivedBytes} " +
                                "targetBytes=${capture.request.targetBytes}",
                        )
                        continue
                    }
                    RecordingCardWifiEndDecision.FAIL_INCOMPLETE -> throw WifiDownloadFailure(
                        "RECORDING_CARD_WIFI_DOWNLOAD_INCOMPLETE",
                        "Recording-card Wi-Fi file ended before its advertised size.",
                        invalidatesSession = false,
                    )
                }
            }
            if (tailSeekAwaitingData) {
                when (recordingCardWifiStatusOnlyResponse(payload)) {
                    RecordingCardWifiStatusOnlyResponse.ACCEPTED -> continue
                    RecordingCardWifiStatusOnlyResponse.REJECTED,
                    RecordingCardWifiStatusOnlyResponse.INCOMPLETE,
                    -> throw WifiDownloadFailure(
                        "RECORDING_CARD_WIFI_TAIL_SEEK_REJECTED",
                        "Recording-card Wi-Fi tail seek was rejected.",
                        invalidatesSession = false,
                    )
                    RecordingCardWifiStatusOnlyResponse.NOT_STATUS -> Unit
                }
                if (payload.size == 5 && (payload[0].toInt() and 0xff) == 0x00) {
                    val acknowledgedSize = readUInt32(payload, 1)
                    val remainingBytes = capture.request.targetBytes - capture.receivedBytes
                    if (acknowledgedSize != remainingBytes &&
                        acknowledgedSize != capture.request.targetBytes
                    ) {
                        throw WifiDownloadFailure(
                            "RECORDING_CARD_WIFI_TAIL_SEEK_LENGTH_MISMATCH",
                            "Recording-card Wi-Fi tail seek length was invalid.",
                            invalidatesSession = false,
                        )
                    }
                    continue
                }
                val remainingBytes = capture.request.targetBytes - capture.receivedBytes
                if (!recordingCardWifiTailPayloadMatches(remainingBytes, payload.size)) {
                    throw WifiDownloadFailure(
                        "RECORDING_CARD_WIFI_TAIL_SEEK_LENGTH_MISMATCH",
                        "Recording-card Wi-Fi tail seek returned an ambiguous payload length.",
                        invalidatesSession = false,
                    )
                }
                tailSeekAwaitingData = false
                debugLog(
                    "wifi tail seek data started id=${capture.correlationId} " +
                        "payloadBytes=${payload.size}",
                )
            }
            if (!capture.acknowledged) {
                if (payload.size == 5 && (payload[0].toInt() and 0xff) == 0x00) {
                    val acknowledgedSize = resolveWifiAcknowledgedSize(payload, directoryEntry)
                    capture.request = capture.request.withTargetBytes(acknowledgedSize)
                    capture.acknowledged = true
                    emitWifiTransferProgress(capture, force = false)
                    continue
                }
                when (recordingCardWifiStatusOnlyResponse(payload)) {
                    RecordingCardWifiStatusOnlyResponse.ACCEPTED -> {
                        capture.request = capture.request.withTargetBytes(directoryEntry.sizeBytes)
                        capture.acknowledged = true
                        emitWifiTransferProgress(capture, force = false)
                        continue
                    }
                    RecordingCardWifiStatusOnlyResponse.REJECTED -> throw WifiDownloadFailure(
                        "RECORDING_CARD_WIFI_REQUEST_REJECTED",
                        "Recording-card Wi-Fi file request was rejected.",
                        invalidatesSession = false,
                    )
                    RecordingCardWifiStatusOnlyResponse.INCOMPLETE -> throw WifiDownloadFailure(
                        "RECORDING_CARD_WIFI_DOWNLOAD_INCOMPLETE",
                        "Recording-card Wi-Fi file ended before its advertised size.",
                        invalidatesSession = false,
                    )
                    RecordingCardWifiStatusOnlyResponse.NOT_STATUS -> Unit
                }
                capture.request = capture.request.withTargetBytes(directoryEntry.sizeBytes)
                capture.acknowledged = true
                emitWifiTransferProgress(capture, force = false)
            }

            try {
                session.dataSequenceGuard.accept(packet.sequence)
            } catch (_: RecordingCardWifiProtocolException) {
                throw WifiDownloadFailure(
                    "RECORDING_CARD_WIFI_SEQUENCE_MISMATCH",
                    "Recording-card Wi-Fi file sequence was discontinuous.",
                )
            }
            val budget = payloadBudget
                ?: RecordingCardWifiPayloadBudget(capture.request.targetBytes).also {
                    payloadBudget = it
                }
            try {
                budget.accept(payload.size)
            } catch (_: RecordingCardWifiProtocolException) {
                throw WifiDownloadFailure(
                    "RECORDING_CARD_WIFI_DATA_OVERRUN",
                    "Recording-card Wi-Fi returned more data than advertised.",
                )
            }
            try {
                capture.output.write(payload)
                capture.digest.update(payload)
                capture.receivedBytes += payload.size.toLong()
                capture.wifiRateSampler?.observe(
                    SystemClock.elapsedRealtime(),
                    capture.receivedBytes,
                )
            } catch (_: IOException) {
                throw WifiDownloadFailure(
                    "RECORDING_CARD_LOCAL_STORAGE_FAILED",
                    "Recording-card Wi-Fi download could not write private storage.",
                )
            }
            if (prematureEndDeadlineMs != null) {
                prematureEndDeadlineMs = if (capture.receivedBytes < capture.request.targetBytes) {
                    SystemClock.elapsedRealtime() + WIFI_PREMATURE_END_GRACE_MS
                } else {
                    null
                }
            }
            emitWifiTransferProgress(capture, force = false)
        }
        capture.transferStage = "verifying"
        emitWifiTransferProgress(capture, force = true)
        awaitWifiFileBoundary(session, capture)
        val committed = synchronized(wifiCommitLock) {
            if (session.cancelled || wifiSessionCancellationRequested) {
                throw cancelledWifiFailure()
            }
            commitWifiCapture(capture).also {
                capture.transferStage = "completed"
            }
        }
        emitWifiTransferProgress(capture, force = true)
        return committed
    }

    private fun resolveWifiAcknowledgedSize(
        payload: ByteArray,
        directoryEntry: WifiDirectoryEntry,
    ): Long {
        val littleEndian = readUInt32LittleEndian(payload, 1)
        val bigEndian = readUInt32(payload, 1)
        val acknowledged = resolveRecordingCardDeviceFileSize(littleEndian, bigEndian)?.first
            ?: throw WifiDownloadFailure(
                "RECORDING_CARD_DOWNLOAD_LENGTH_UNAVAILABLE",
                "Recording-card Wi-Fi file length was unavailable.",
            )
        if (directoryEntry.sizeConfidence == "trusted" && acknowledged != directoryEntry.sizeBytes) {
            throw WifiDownloadFailure(
                "RECORDING_CARD_DOWNLOAD_SIZE_MISMATCH",
                "Recording-card Wi-Fi size did not match the device listing.",
            )
        }
        return acknowledged
    }

    private fun awaitWifiFileBoundary(
        session: WifiSession,
        capture: OfflineCapture,
    ) {
        val verifiedProfile = RecordingCardWifiCompatibility.isVerifiedFirmwareProfile(
            session.mainFirmwareVersion,
            session.wifiFirmwareVersion,
        )
        val boundaryMode = recordingCardWifiBoundaryMode(
            allowQuietBoundary = verifiedProfile,
            fileIndex = capture.batchFileIndex,
            fileCount = capture.batchFileCount,
        )
        val natural = try {
            readWifiPacket(
                session,
                if (verifiedProfile) {
                    WIFI_VERIFIED_PROFILE_NATURAL_END_WAIT_MS
                } else {
                    WIFI_NATURAL_END_WAIT_MS
                },
            )
        } catch (_: SocketTimeoutException) {
            null
        }
        if (natural != null) {
            if (natural.command == COMMAND_REQUEST_FILE &&
                natural.payload.size == 1 &&
                (natural.payload[0].toInt() and 0xff) == 0x02
            ) return
            throw WifiDownloadFailure(
                "RECORDING_CARD_WIFI_DATA_OVERRUN",
                "Recording-card Wi-Fi returned data beyond the advertised file boundary.",
            )
        }
        if (!boundaryMode.requiresStopRequest) {
            debugLog(
                "wifi inter-file quiet boundary waiting id=${capture.correlationId} " +
                    "fileIndex=${capture.batchFileIndex} fileCount=${capture.batchFileCount}",
            )
            val boundary = try {
                readWifiPacket(session, WIFI_STOP_CONFIRM_TIMEOUT_MS)
            } catch (_: SocketTimeoutException) {
                null
            }
            if (boundary != null) {
                requireValidWifiBoundaryPacket(boundary)
                return
            }
            if (RecordingCardWifiCompatibility.acceptsQuietBoundary(
                    mainFirmware = session.mainFirmwareVersion,
                    wifiFirmware = session.wifiFirmwareVersion,
                    connectionHealthy = wifiSessionConnectionHealthy(session),
                    queuedPackets = session.packetQueue.size,
                    pendingBytes = session.decoder.pendingBytes,
                )
            ) {
                debugLog(
                    "wifi inter-file quiet boundary accepted id=${capture.correlationId} " +
                        "profile=fw-1.0.6-wifi-1.0.2",
                )
                return
            }
            throw WifiDownloadFailure(
                "RECORDING_CARD_WIFI_BOUNDARY_TIMEOUT",
                "Recording-card Wi-Fi inter-file boundary timed out.",
            )
        }
        sendWifiPacket(session, COMMAND_STOP_FILE_TRANSFER, 0, byteArrayOf())
        val stop = try {
            readWifiPacket(session, WIFI_STOP_CONFIRM_TIMEOUT_MS)
        } catch (_: SocketTimeoutException) {
            if (RecordingCardWifiCompatibility.acceptsQuietStopBoundary(
                    mainFirmware = session.mainFirmwareVersion,
                    wifiFirmware = session.wifiFirmwareVersion,
                    stopWriteSucceeded = true,
                    connectionHealthy = wifiSessionConnectionHealthy(session),
                    queuedPackets = session.packetQueue.size,
                    pendingBytes = session.decoder.pendingBytes,
                )
            ) return
            throw WifiDownloadFailure(
                "RECORDING_CARD_WIFI_BOUNDARY_TIMEOUT",
                "Recording-card Wi-Fi file boundary could not be confirmed.",
            )
        }
        requireValidWifiBoundaryPacket(stop)
    }

    private fun requireValidWifiBoundaryPacket(packet: RecordingCardWifiPacket) {
        val status = packet.payload.singleOrNull()?.toInt()?.and(0xff)
        if (packet.command !in setOf(COMMAND_REQUEST_FILE, COMMAND_STOP_FILE_TRANSFER) ||
            status !in setOf(0x00, 0x02)
        ) {
            throw WifiDownloadFailure(
                "RECORDING_CARD_WIFI_BOUNDARY_INVALID",
                "Recording-card Wi-Fi file boundary response was invalid.",
            )
        }
    }

    private fun wifiSessionConnectionHealthy(session: WifiSession): Boolean =
        session.socket.isConnected &&
            !session.socket.isClosed &&
            !session.socket.isInputShutdown &&
            !session.socket.isOutputShutdown &&
            !session.closed &&
            !session.cancelled

    private fun commitWifiCapture(capture: OfflineCapture): Map<String, Any> {
        if (capture.receivedBytes != capture.request.targetBytes) {
            throw WifiDownloadFailure(
                "RECORDING_CARD_DOWNLOAD_SIZE_MISMATCH",
                "Recording-card Wi-Fi download did not receive the advertised size.",
            )
        }
        try {
            capture.output.flush()
            capture.output.fd.sync()
            capture.output.close()
        } catch (_: IOException) {
            throw WifiDownloadFailure(
                "RECORDING_CARD_LOCAL_STORAGE_FAILED",
                "Recording-card Wi-Fi download could not finalize private storage.",
            )
        }
        if (capture.partFile.length() != capture.request.targetBytes) {
            throw WifiDownloadFailure(
                "RECORDING_CARD_DOWNLOAD_SIZE_MISMATCH",
                "Recording-card Wi-Fi download did not commit the advertised size.",
            )
        }
        val contentHash = capture.digest.digest().joinToString("") { byte ->
            "%02x".format(byte.toInt() and 0xff)
        }
        try {
            recordingCardCommitVerifiedPart(
                partFile = capture.partFile,
                finalFile = capture.finalFile,
                expectedSize = capture.request.targetBytes,
                expectedContentHash = contentHash,
            )
        } catch (_: IOException) {
            throw WifiDownloadFailure(
                "RECORDING_CARD_LOCAL_STORAGE_FAILED",
                "Recording-card Wi-Fi download could not commit private storage.",
            )
        }
        return buildMap {
            put("localFileKey", capture.request.localFileKey)
            put("localFileId", capture.fileId)
            put("appPrivateUri", capture.appPrivateUri)
            put("displayName", capture.displayName)
            capture.request.durationSeconds?.let { put("durationSeconds", it) }
            put("sizeBytes", capture.request.targetBytes)
            put("contentHash", contentHash)
            put("format", capture.request.format)
            put("mimeType", mimeTypeFor(capture.request.format))
        }
    }

    private fun cleanupWifiCapture(capture: OfflineCapture) {
        runCatching { capture.output.close() }
        if (capture.partFile.exists()) capture.partFile.delete()
    }

    private fun closeWifiSession(result: MethodChannel.Result) {
        if (wifiSessionOperationInFlight) {
            result.error(
                "RECORDING_CARD_WIFI_SESSION_BUSY",
                "Recording-card Wi-Fi session is processing an operation.",
                null,
            )
            return
        }
        finishWifiPreparation(
            "RECORDING_CARD_WIFI_TRANSFER_CANCELLED",
            terminalShutdownRequested = true,
            afterHotspotSettlement = { completeWifiSessionClose(result) },
        )
    }

    private fun completeWifiSessionClose(result: MethodChannel.Result) {
        if (wifiSessionOperationInFlight) {
            result.error(
                "RECORDING_CARD_WIFI_SESSION_BUSY",
                "Recording-card Wi-Fi session is processing an operation.",
                null,
            )
            return
        }
        closeWifiSessionInternal(deleteActivePart = true)
        wifiAttemptOwned = false
        result.success(true)
    }

    private fun cancelWifiSession(result: MethodChannel.Result) {
        finishWifiPreparation(
            "RECORDING_CARD_WIFI_TRANSFER_CANCELLED",
            terminalShutdownRequested = true,
            afterHotspotSettlement = { completeWifiSessionCancellation(result) },
        )
    }

    private fun completeWifiSessionCancellation(result: MethodChannel.Result) {
        if (wifiSessionOperationInFlight) {
            synchronized(wifiCommitLock) {
                pendingWifiCancellationResults += result
                wifiSessionCancellationRequested = true
            }
            closeWifiSessionInternal(deleteActivePart = false, cancelled = true)
            emitSnapshot()
            return
        }
        closeWifiSessionInternal(deleteActivePart = true, cancelled = true)
        wifiDownloadFileKey = null
        wifiAttemptOwned = false
        emitSnapshot()
        result.success(true)
    }

    private fun closeWifiSessionInternal(
        deleteActivePart: Boolean,
        cancelled: Boolean = false,
        cleanupMode: RecordingCardWifiSessionCleanupMode =
            RecordingCardWifiSessionCleanupMode.TERMINAL,
    ) {
        val retainHotspotFacts = recordingCardWifiCleanupRetainsHotspotFacts(
            mode = cleanupMode,
            attemptOwned = wifiAttemptOwned,
        )
        if (cancelled) {
            wifiActiveCapture?.let { capture ->
                if (capture.transferStage !in setOf("completed", "cancelled")) {
                    capture.transferStage = "cancelled"
                    emitWifiTransferProgress(capture, force = true)
                }
            }
        }
        val session = wifiSession
        if (session != null) {
            if (cancelled && session.ready && !session.closed && !session.cancelled) {
                runCatching {
                    sendWifiPacket(session, COMMAND_STOP_FILE_TRANSFER, 0, byteArrayOf())
                }
            }
            session.cancelled = cancelled
            session.closed = true
            runCatching { session.socket.close() }
            if (wifiSession === session) wifiSession = null
        }
        if (deleteActivePart) {
            wifiActiveCapture?.let(::cleanupWifiCapture)
            wifiActiveCapture = null
        }
        runCatching { RecordingCardSyncService.setWifiTransferEnabled(context, false) }
        releaseWifiNetworkRequest(cancelPending = cancelled)
        clearWifiCredentialLease()
        acceptsUnsolicitedWifiCredentials = false
        if (!retainHotspotFacts) {
            wifiHotspotEnableMayHaveBeenDispatched = false
            wifiBleDisconnectExpected = false
            wifiHandoffReady = false
        }
    }

    private fun closeWifiSessionAfterFailure(deleteActivePart: Boolean) {
        closeWifiSessionInternal(
            deleteActivePart = deleteActivePart,
            cleanupMode = RecordingCardWifiSessionCleanupMode
                .FAILURE_AWAITING_ATTEMPT_TEARDOWN,
        )
    }

    private fun beginWifiSessionOperation(result: MethodChannel.Result): Boolean {
        if (unbindResult != null) {
            result.error(
                "RECORDING_CARD_UNBIND_IN_PROGRESS",
                "Recording-card unbind is already running.",
                null,
            )
            return false
        }
        if (wifiSessionOperationInFlight || wifiHotspotDisableInFlight) {
            result.error(
                "RECORDING_CARD_WIFI_SESSION_BUSY",
                "Recording-card Wi-Fi session is already processing a request.",
                null,
            )
            return false
        }
        val serviceFailure = runCatching {
            RecordingCardSyncService.setWifiTransferEnabled(context, true)
        }.exceptionOrNull()
        if (serviceFailure != null) {
            debugLog(
                "native Wi-Fi foreground service unavailable " +
                    "type=${serviceFailure.javaClass.simpleName}",
            )
            wifiSessionCancellationRequested = true
            closeWifiSessionInternal(
                deleteActivePart = true,
                cancelled = true,
                cleanupMode = RecordingCardWifiSessionCleanupMode
                    .FAILURE_AWAITING_ATTEMPT_TEARDOWN,
            )
            wifiSessionCancellationRequested = false
            wifiSessionOperationInFlight = false
            result.error(
                "RECORDING_CARD_WIFI_BACKGROUND_UNAVAILABLE",
                "Recording-card Wi-Fi transfer could not start foreground execution.",
                null,
            )
            return false
        }
        wifiSessionCancellationRequested = false
        wifiSessionOperationInFlight = true
        wifiLastActivityAt = SystemClock.elapsedRealtime()
        return true
    }

    private fun completeWifiSessionOperation(block: () -> Unit) {
        mainHandler.post {
            wifiSessionOperationInFlight = false
            try {
                block()
            } finally {
                settlePendingWifiCancellations()
            }
        }
    }

    private fun settlePendingWifiCancellations() {
        if (pendingWifiCancellationResults.isEmpty()) {
            wifiSessionCancellationRequested = false
            return
        }
        val results = pendingWifiCancellationResults.toList()
        pendingWifiCancellationResults.clear()
        closeWifiSessionInternal(deleteActivePart = true, cancelled = true)
        wifiDownloadFileKey = null
        wifiSessionCancellationRequested = false
        wifiAttemptOwned = false
        emitSnapshot()
        results.forEach { it.success(true) }
    }

    private fun recorderCardWifiNetwork(): Network? {
        val network = wifiJoinNetwork ?: return null
        val callback = wifiJoinCallback ?: return null
        val manager = context.getSystemService(ConnectivityManager::class.java) ?: return null
        return network.takeIf { recorderCardWifiNetworkIsReady(it, callback, manager) }
    }

    private fun recorderCardWifiNetworkIsReady(
        network: Network,
        callback: ConnectivityManager.NetworkCallback,
        manager: ConnectivityManager,
    ): Boolean {
        val recorderEndpoint = InetAddress.getByAddress(
            byteArrayOf(192.toByte(), 168.toByte(), 200.toByte(), 1),
        )
        return runCatching {
            val capabilities = manager.getNetworkCapabilities(network)
            val linkProperties = manager.getLinkProperties(network)
            recordingCardWifiHandoffRouteReady(
                ownsRequestedNetwork = wifiJoinNetwork == network && wifiJoinCallback === callback,
                hasWifiTransport = capabilities?.hasTransport(
                    NetworkCapabilities.TRANSPORT_WIFI,
                ) == true,
                routesRecorderEndpoint = linkProperties?.routes?.any { route ->
                    route.gateway?.hostAddress == WIFI_TRANSFER_HOST ||
                        route.destination.contains(recorderEndpoint)
                } == true,
            )
        }.getOrDefault(false)
    }

    private fun releaseWifiNetworkRequest(cancelPending: Boolean) {
        val pending = wifiJoinResult
        wifiJoinResult = null
        val callback = wifiJoinCallback
        wifiJoinCallback = null
        wifiJoinNetwork = null
        if (callback != null) {
            val manager = context.getSystemService(ConnectivityManager::class.java)
            runCatching { manager?.unregisterNetworkCallback(callback) }
        }
        if (cancelPending) {
            pending?.error(
                "RECORDING_CARD_WIFI_JOIN_CANCELLED",
                "Recording-card Wi-Fi join was cancelled.",
                null,
            )
        }
    }

    private fun sendWifiPacket(
        session: WifiSession,
        command: Int,
        sequence: Int,
        payload: ByteArray,
    ) {
        if (session.closed || session.cancelled) throw cancelledWifiFailure()
        val frame = RecordingCardWifiProtocol.encode(command, sequence, payload)
        try {
            session.output.write(frame)
            session.output.flush()
        } catch (_: IOException) {
            if (session.cancelled) throw cancelledWifiFailure()
            throw WifiDownloadFailure(
                "RECORDING_CARD_WIFI_WRITE_FAILED",
                "Recording-card Wi-Fi request could not be sent.",
            )
        }
    }

    private fun readWifiPacket(session: WifiSession, timeoutMs: Long): RecordingCardWifiPacket {
        session.packetQueue.pollFirst()?.let { return it }
        while (true) {
            if (session.closed || session.cancelled) throw cancelledWifiFailure()
            session.socket.soTimeout = timeoutMs.coerceIn(1L, Int.MAX_VALUE.toLong()).toInt()
            val read = try {
                session.input.read(session.readBuffer)
            } catch (failure: SocketTimeoutException) {
                throw failure
            } catch (_: IOException) {
                if (session.cancelled) throw cancelledWifiFailure()
                throw WifiDownloadFailure(
                    "RECORDING_CARD_WIFI_TRANSFER_FAILED",
                    "Recording-card Wi-Fi connection was interrupted.",
                )
            }
            if (read < 0) {
                throw WifiDownloadFailure(
                    "RECORDING_CARD_WIFI_TRANSFER_FAILED",
                    "Recording-card Wi-Fi connection ended unexpectedly.",
                )
            }
            if (read == 0) continue
            val packets = try {
                session.decoder.push(session.readBuffer, read)
            } catch (_: RecordingCardWifiProtocolException) {
                throw WifiDownloadFailure(
                    "RECORDING_CARD_WIFI_PROTOCOL_ERROR",
                    "Recording-card Wi-Fi response frame is invalid.",
                )
            }
            session.packetQueue.addAll(packets)
            session.packetQueue.pollFirst()?.let { return it }
        }
    }

    private fun parseWifiDirectoryEntry(payload: ByteArray): WifiDirectoryEntry? {
        if (payload.size < 19 || (payload[0].toInt() and 0xff) != 0x00) return null
        val filename = asciiText(payload.copyOfRange(1, 15)) ?: return null
        val resolved = resolveRecordingCardDeviceFileSize(
            readUInt32LittleEndian(payload, 15),
            readUInt32(payload, 15),
        ) ?: return null
        return WifiDirectoryEntry(filename, resolved.first, resolved.second)
    }

    private fun wifiSessionMap(session: WifiSession): Map<String, Any> = mapOf(
        "sessionId" to session.id,
        "status" to "ready",
        "files" to session.directory.values.map(::wifiDirectoryEntryMap),
        "directoryFileCount" to session.directory.size,
        "openedAt" to session.openedAt,
        "transport" to "wifi",
    )

    private fun wifiDirectoryEntryMap(entry: WifiDirectoryEntry): Map<String, Any> {
        val key = "card-${entry.filename.lowercase()}"
        return mapOf(
            "deviceFileId" to key,
            "localFileKey" to key,
            "deviceFilename" to entry.filename,
            "sizeBytes" to entry.sizeBytes,
            "sizeConfidence" to entry.sizeConfidence,
            "format" to "unknown",
            "syncState" to "deviceOnly",
        )
    }

    private fun cancelledWifiFailure(): WifiDownloadFailure = WifiDownloadFailure(
        "RECORDING_CARD_WIFI_TRANSFER_CANCELLED",
        "Recording-card Wi-Fi transfer was cancelled.",
    )

    private fun deleteFile(arguments: Map<*, *>?, result: MethodChannel.Result) {
        val filename = arguments?.get("deviceFilename") as? String
        val deviceFileId = arguments?.get("deviceFileId") as? String
        if (filename == null || deviceFileId == null || !isSafeFilename(filename)) {
            result.error("RECORDING_CARD_INVALID_FILE", "Recording-card file payload is invalid.", null)
            return
        }
        sendCommand(COMMAND_DELETE_FILE, fileRequestPayload(filename), result) { payload ->
            if (payload.firstOrNull()?.toInt() != 0) throw IllegalStateException("delete rejected")
            fileDirectory.remove(deviceFileId)
            emitSnapshot()
            CommandResponse.Complete(
                mapOf(
                    "deleted" to true,
                    "deviceFileId" to deviceFileId,
                    "deviceFilename" to filename,
                ),
            )
        }
    }

    @SuppressLint("MissingPermission")
    private fun sendCommand(
        command: Int,
        payload: ByteArray,
        result: MethodChannel.Result?,
        allowDuringUnbind: Boolean = false,
        allowWifiHandoffCleanup: Boolean = false,
        timeoutMs: Long = COMMAND_TIMEOUT_MS,
        onPacket: (ByteArray) -> CommandResponse,
    ): Boolean {
        if (unbindResult != null && !allowDuringUnbind) {
            result?.error(
                "RECORDING_CARD_UNBIND_IN_PROGRESS",
                "Recording-card unbind is already running.",
                null,
            )
            return false
        }
        val currentGatt = gatt
        val characteristic = writeCharacteristic
        val cleanupTransportReady = allowWifiHandoffCleanup &&
            command == COMMAND_ENABLE_WIFI &&
            wifiHotspotDisableInFlight &&
            wifiBleDisconnectExpected
        if ((!isTransportReady() && !cleanupTransportReady) ||
            currentGatt == null || characteristic == null
        ) {
            result?.error("RECORDING_CARD_NOT_CONNECTED", "Recording card is not connected.", null)
            return false
        }
        if (pendingCommands.containsKey(command)) {
            result?.error("RECORDING_CARD_COMMAND_IN_PROGRESS", "A recording-card command is already running.", null)
            return false
        }
        val writeType = when {
            characteristic.properties and BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE != 0 ->
                BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE
            characteristic.properties and BluetoothGattCharacteristic.PROPERTY_WRITE != 0 ->
                BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
            else -> {
                result?.error("RECORDING_CARD_WRITE_UNSUPPORTED", "Recording-card write characteristic is not writable.", null)
                return false
            }
        }
        val ownership = nextCommandOwnership()
        val frame = recordingCardEncodeControlFrame(command, payload)
        val timeout = Runnable {
            val pending = pendingCommands[command]
                ?.takeIf {
                    it.ownership == ownership &&
                        ownership.transportGeneration == transportGeneration
                }
                ?: return@Runnable
            val retireTransport = recordingCardAbandonedCommandRequiresTransportRetirement(
                pending.ownership,
                transportGeneration,
                pending.dispatchCount,
            )
            pendingCommands.remove(command)
            commandTimeouts.remove(command)
            if (command == COMMAND_GET_BINDING_INFO) cancelBindingInfoRetry()
            if (command == COMMAND_REQUEST_FILE) {
                cleanupOfflineCapture(deletePart = true)
                stopOfflineTransfer()
                pending.result?.error(
                    "RECORDING_CARD_DOWNLOAD_TIMEOUT",
                    "Recording-card download timed out.",
                    null,
                )
            } else {
                val code = if (handshake.inProgress && command == COMMAND_BIND_DEVICE) {
                    if (pending.dispatchCount > 0) {
                        "RECORDING_CARD_BINDING_ACK_TIMEOUT"
                    } else {
                        "RECORDING_CARD_WRITE_FAILED"
                    }
                } else if (handshake.inProgress && command == COMMAND_GET_BINDING_INFO) {
                    if (pending.dispatchCount > 0) {
                        "RECORDING_CARD_BINDING_INFO_TIMEOUT"
                    } else {
                        "RECORDING_CARD_WRITE_FAILED"
                    }
                } else {
                    "RECORDING_CARD_COMMAND_TIMEOUT"
                }
                pending.result?.error(code, "Recording-card command timed out.", null)
            }
            val replacementOwnsTransport = recordingCardReplacementCommandOwnsTimedOutTransport(
                allowReplacementTakeover = command == COMMAND_ENABLE_WIFI,
                timedOutOwnership = pending.ownership,
                replacementOwnership = pendingCommands[command]?.ownership,
                activeTransportGeneration = transportGeneration,
            )
            if (retireTransport && !replacementOwnsTransport) {
                retireGattTransport("command timeout")
            } else if (replacementOwnsTransport) {
                debugLog(
                    "timed-out command transport retained for replacement " +
                        "command=0x${command.toString(16).padStart(2, '0')}",
                )
            }
        }
        pendingCommands[command] = PendingCommand(
            ownership = ownership,
            frame = frame,
            result = result,
            onPacket = onPacket,
        )
        commandTimeouts[command] = timeout
        mainHandler.postDelayed(timeout, timeoutMs)
        debugLog(
            "tx command=0x${command.toString(16).padStart(2, '0')} " +
                "payloadBytes=${payload.size} frameBytes=${frame.size} requestId=${ownership.requestId}",
        )
        val dispatchUptime = SystemClock.elapsedRealtime()
        val writeResult = runCatching {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                currentGatt.writeCharacteristic(characteristic, frame, writeType) == BluetoothStatusCodes.SUCCESS
            } else {
                @Suppress("DEPRECATION")
                run {
                    characteristic.writeType = writeType
                    characteristic.value = frame
                    currentGatt.writeCharacteristic(characteristic)
                }
            }
        }
        if (writeResult.exceptionOrNull() is SecurityException) {
            completeCommandWithError(
                command,
                "RECORDING_CARD_BLUETOOTH_PERMISSION_REQUIRED",
                "Bluetooth permission is required to write to the recording card.",
                ownership,
            )
            return false
        }
        if (!writeResult.getOrDefault(false)) {
            completeCommandWithError(
                command,
                "RECORDING_CARD_WRITE_FAILED",
                "Recording-card command could not be queued.",
                ownership,
            )
            return false
        }
        recordCommandDispatch(command, ownership)
        if (command == COMMAND_BIND_DEVICE && handshake.inProgress &&
            handshake.dispatchedBinding(dispatchUptime)
        ) {
            bindingSendDeadline?.let(mainHandler::removeCallbacks)
            bindingSendDeadline = null
            debugLog(
                if (handshake.bindingDispatchMetDeadline == true) {
                    "binding command dispatched within SLA"
                } else {
                    "binding command dispatched after SLA on live transport"
                },
            )
        }
        return true
    }

    private fun nextCommandOwnership(): RecordingCardCommandOwnership {
        commandRequestCounter += 1L
        if (commandRequestCounter == 0L) commandRequestCounter += 1L
        return RecordingCardCommandOwnership(commandRequestCounter, transportGeneration)
    }

    private fun recordCommandDispatch(command: Int, ownership: RecordingCardCommandOwnership) {
        val pending = pendingCommands[command]
            ?.takeIf {
                it.ownership == ownership &&
                    ownership.transportGeneration == transportGeneration
            }
            ?: return
        pending.dispatchCount += 1
        if (command == COMMAND_GET_BINDING_INFO &&
            recordingCardCanRetryBindingInfo(
                handshakeInProgress = handshake.inProgress,
                unbindInProgress = unbindResult != null,
                dispatchCount = pending.dispatchCount,
            )
        ) {
            scheduleBindingInfoRetry(ownership, BINDING_INFO_RETRY_DELAY_MS)
        }
    }

    private fun recoverBindingInfoAfterControlFault() {
        val pending = pendingCommands[COMMAND_GET_BINDING_INFO] ?: return
        if (pending.ownership.transportGeneration != transportGeneration ||
            !recordingCardCanRetryBindingInfo(
                handshakeInProgress = handshake.inProgress,
                unbindInProgress = unbindResult != null,
                dispatchCount = pending.dispatchCount,
            )
        ) return
        debugLog("binding info recovery requested reason=decodeRejected")
        scheduleBindingInfoRetry(pending.ownership, BINDING_INFO_FAULT_RETRY_DELAY_MS)
    }

    private fun scheduleBindingInfoRetry(
        ownership: RecordingCardCommandOwnership,
        delayMs: Long,
    ) {
        val pending = pendingCommands[COMMAND_GET_BINDING_INFO] ?: return
        if (pending.ownership != ownership || ownership.transportGeneration != transportGeneration ||
            !recordingCardCanRetryBindingInfo(
                handshakeInProgress = handshake.inProgress,
                unbindInProgress = unbindResult != null,
                dispatchCount = pending.dispatchCount,
            )
        ) return
        val dueAt = SystemClock.elapsedRealtime() + delayMs.coerceAtLeast(0L)
        val existingDueAt = bindingInfoRetryDueAtMs
        if (bindingInfoRetry != null && existingDueAt != null && existingDueAt <= dueAt) return
        cancelBindingInfoRetry()
        bindingInfoRetryDueAtMs = dueAt
        bindingInfoRetry = Runnable {
            bindingInfoRetry = null
            bindingInfoRetryDueAtMs = null
            retryBindingInfoQueryIfNeeded(ownership)
        }.also { mainHandler.postDelayed(it, delayMs.coerceAtLeast(0L)) }
    }

    @SuppressLint("MissingPermission")
    private fun retryBindingInfoQueryIfNeeded(ownership: RecordingCardCommandOwnership) {
        val pending = pendingCommands[COMMAND_GET_BINDING_INFO] ?: return
        if (pending.ownership != ownership || ownership.transportGeneration != transportGeneration ||
            !recordingCardCanRetryBindingInfo(
                handshakeInProgress = handshake.inProgress,
                unbindInProgress = unbindResult != null,
                dispatchCount = pending.dispatchCount,
            )
        ) return
        val currentGatt = gatt ?: return
        val characteristic = writeCharacteristic ?: return
        val writeType = when {
            characteristic.properties and BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE != 0 ->
                BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE
            characteristic.properties and BluetoothGattCharacteristic.PROPERTY_WRITE != 0 ->
                BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
            else -> return
        }
        frameDecoder.reset()
        debugLog("binding info retry tx requestId=${ownership.requestId}")
        val writeResult = runCatching {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                currentGatt.writeCharacteristic(
                    characteristic,
                    pending.frame,
                    writeType,
                ) == BluetoothStatusCodes.SUCCESS
            } else {
                @Suppress("DEPRECATION")
                run {
                    characteristic.writeType = writeType
                    characteristic.value = pending.frame
                    currentGatt.writeCharacteristic(characteristic)
                }
            }
        }
        if (writeResult.exceptionOrNull() is SecurityException) {
            completeCommandWithError(
                COMMAND_GET_BINDING_INFO,
                "RECORDING_CARD_BLUETOOTH_PERMISSION_REQUIRED",
                "Bluetooth permission is required to write to the recording card.",
                ownership,
            )
            return
        }
        if (!writeResult.getOrDefault(false)) {
            completeCommandWithError(
                COMMAND_GET_BINDING_INFO,
                "RECORDING_CARD_WRITE_FAILED",
                "Recording-card binding query could not be retried.",
                ownership,
            )
            return
        }
        recordCommandDispatch(COMMAND_GET_BINDING_INFO, ownership)
    }

    private fun cancelBindingInfoRetry() {
        bindingInfoRetry?.let(mainHandler::removeCallbacks)
        bindingInfoRetry = null
        bindingInfoRetryDueAtMs = null
    }

    private fun parseDownloadRequest(arguments: Map<*, *>?): DownloadRequest? {
        val source = arguments ?: return null
        val deviceFilename = source["deviceFilename"] as? String ?: return null
        val localFileKey = source["localFileKey"] as? String ?: return null
        if (!isSafeFilename(deviceFilename) ||
            recordingCardFileRequestPayload(deviceFilename) == null ||
            !isSafeFilename(localFileKey)
        ) return null
        val sizeConfidence = source["sizeConfidence"] as? String
        if (sizeConfidence != null && sizeConfidence != "trusted" && sizeConfidence != "suspect") {
            return null
        }
        val requestedFormat = source["format"] as? String
        val format = recordingFormatFor(deviceFilename, requestedFormat) ?: return null
        val durationSeconds = asNonNegativeInt(source["durationSeconds"])
        return DownloadRequest(
            deviceFilename = deviceFilename,
            localFileKey = localFileKey,
            directorySizeBytes = asNonZeroLong(source["sizeBytes"])
                ?.takeIf(::isValidDeviceFileSize),
            sizeConfidence = sizeConfidence,
            targetBytes = 0L,
            durationSeconds = durationSeconds,
            format = format,
        )
    }

    private fun createOfflineCapture(
        request: DownloadRequest,
        transferTransport: String = "bluetooth",
        batchId: String? = null,
        batchFileIndex: Int? = null,
        batchFileCount: Int? = null,
        aggregateReceivedBase: Long? = null,
        aggregateTotalBytes: Long? = null,
        plannedNativeFileId: String? = null,
    ): OfflineCapture? {
        var partFile: File? = null
        var output: FileOutputStream? = null
        return try {
            if (plannedNativeFileId != null && !isSafeNativeFileId(plannedNativeFileId)) return null
            val fileId = plannedNativeFileId ?: "card-${UUID.randomUUID().toString().replace("-", "")}"
            val directory = File(context.filesDir, "recordings/recording-card")
            if (!directory.exists() && !directory.mkdirs()) return null
            val sourceName = "$fileId.${request.format}"
            partFile = File(directory, "$sourceName.part")
            val finalFile = File(directory, sourceName)
            if (partFile.exists() && !partFile.delete()) return null
            output = FileOutputStream(partFile)
            OfflineCapture(
                request = request,
                fileId = fileId,
                appPrivateUri = "app-private://recording-card/$sourceName",
                displayName = displayNameFor(request.deviceFilename, request.format),
                partFile = partFile,
                finalFile = finalFile,
                output = output,
                digest = MessageDigest.getInstance("SHA-256"),
                transferTransport = transferTransport,
                bleTransportGeneration = transportGeneration.takeIf {
                    transferTransport == "bluetooth"
                },
                batchId = batchId,
                batchFileIndex = batchFileIndex,
                batchFileCount = batchFileCount,
                aggregateReceivedBase = aggregateReceivedBase,
                aggregateTotalBytes = aggregateTotalBytes,
            )
        } catch (_: Exception) {
            runCatching { output?.close() }
            partFile?.takeIf(File::exists)?.delete()
            null
        }
    }

    private fun appendOfflineData(value: ByteArray) {
        if (extendBleSilenceBarrier()) return
        val capture = offlineCapture ?: return
        if (!recordingCardBleCaptureOwnsTransport(
                capture.bleTransportGeneration,
                transportGeneration,
            )
        ) {
            return
        }
        if (value.isEmpty()) return
        scheduleDownloadInactivityTimeout()
        if (!capture.acknowledged) {
            val nextSize = capture.preAckBytes + value.size.toLong()
            if (nextSize > MAX_PRE_ACK_BYTES) {
                failOfflineCapture(
                    "RECORDING_CARD_DOWNLOAD_PROTOCOL_ORDER",
                    "Recording-card file data arrived before a usable acknowledgement.",
                )
                return
            }
            capture.preAckChunks += value.copyOf()
            capture.preAckBytes = nextSize
            return
        }
        if (capture.receivedBytes >= capture.request.targetBytes) return
        val remainingBytes = capture.request.targetBytes - capture.receivedBytes
        val acceptedLength = minOf(value.size.toLong(), remainingBytes).toInt()
        if (acceptedLength <= 0) return
        val acceptedData = if (acceptedLength == value.size) value else value.copyOf(acceptedLength)
        try {
            capture.output.write(acceptedData)
            capture.digest.update(acceptedData)
            capture.receivedBytes += acceptedLength.toLong()
            emitTransferProgress(
                capture,
                force = capture.receivedBytes == capture.request.targetBytes,
            )
        } catch (_: Exception) {
            failOfflineCapture(
                "RECORDING_CARD_LOCAL_STORAGE_FAILED",
                "Recording-card download could not write private storage.",
            )
            return
        }
        if (capture.receivedBytes == capture.request.targetBytes) {
            capture.dataComplete = true
            stopOfflineTransfer()
            if (capture.acknowledged) completeOfflineCapture(capture)
        }
    }

    private fun completeOfflineCapture(capture: OfflineCapture) {
        try {
            capture.output.flush()
            capture.output.fd.sync()
            capture.output.close()
            if (capture.partFile.length() != capture.request.targetBytes) {
                failOfflineCapture(
                    "RECORDING_CARD_DOWNLOAD_SIZE_MISMATCH",
                    "Recording-card download did not commit the expected size.",
                )
                return
            }
            val contentHash = capture.digest.digest().joinToString("") { byte ->
                "%02x".format(byte.toInt() and 0xff)
            }
            recordingCardCommitVerifiedPart(
                partFile = capture.partFile,
                finalFile = capture.finalFile,
                expectedSize = capture.request.targetBytes,
                expectedContentHash = contentHash,
            )
            offlineCapture = null
            stopOfflineTransfer()
            val pending = pendingCommands[COMMAND_REQUEST_FILE]
            clearPendingCommand(COMMAND_REQUEST_FILE)
            val committed = mapOf(
                "localFileKey" to capture.request.localFileKey,
                "localFileId" to capture.fileId,
                "appPrivateUri" to capture.appPrivateUri,
                "displayName" to capture.displayName,
                "durationSeconds" to capture.request.durationSeconds,
                "sizeBytes" to capture.request.targetBytes,
                "contentHash" to contentHash,
                "format" to capture.request.format,
                "mimeType" to mimeTypeFor(capture.request.format),
            ).filterValues { it != null }
            beginBleSilenceBarrier {
                pending?.result?.success(committed)
            }
        } catch (_: Exception) {
            failOfflineCapture(
                "RECORDING_CARD_LOCAL_STORAGE_FAILED",
                "Recording-card download could not commit private storage.",
            )
        }
    }

    private fun failOfflineCapture(code: String, message: String) {
        cleanupOfflineCapture(deletePart = true)
        stopOfflineTransfer()
        completeCommandWithError(
            COMMAND_REQUEST_FILE,
            code,
            message,
            retireTransport = true,
        )
    }

    private fun cleanupOfflineCapture(deletePart: Boolean) {
        offlineInactivityTimeout?.let(mainHandler::removeCallbacks)
        offlineInactivityTimeout = null
        val capture = offlineCapture ?: return
        offlineCapture = null
        try {
            capture.output.close()
        } catch (_: Exception) {
            // A failed stream close must not leave a partial file visible.
        }
        if (deletePart && capture.partFile.exists()) capture.partFile.delete()
    }

    private fun beginBleSilenceBarrier(completion: () -> Unit) {
        check(bleSilenceCompletion == null)
        bleSilenceCompletion = completion
        val generation = bleSilenceBarrier.begin(SystemClock.elapsedRealtime())
        scheduleBleSilenceCompletion(generation)
    }

    private fun extendBleSilenceBarrier(): Boolean {
        val generation = bleSilenceBarrier.observeOrphanedData(
            SystemClock.elapsedRealtime(),
        ) ?: return false
        scheduleBleSilenceCompletion(generation)
        return true
    }

    private fun scheduleBleSilenceCompletion(generation: Long) {
        bleSilenceTimeout?.let(mainHandler::removeCallbacks)
        val delayMs = bleSilenceBarrier.remainingDelayMs(
            generation,
            SystemClock.elapsedRealtime(),
        ) ?: return
        bleSilenceTimeout = Runnable {
            if (!bleSilenceBarrier.completeIfQuiet(
                    generation,
                    SystemClock.elapsedRealtime(),
                )
            ) {
                scheduleBleSilenceCompletion(generation)
                return@Runnable
            }
            bleSilenceTimeout = null
            val completion = bleSilenceCompletion
            bleSilenceCompletion = null
            completion?.invoke()
        }.also { mainHandler.postDelayed(it, delayMs.coerceAtLeast(1L)) }
    }

    private fun scheduleDownloadTimeouts(sizeBytes: Long) {
        commandTimeouts.remove(COMMAND_REQUEST_FILE)?.let(mainHandler::removeCallbacks)
        val timeout = Runnable {
            if (!pendingCommands.containsKey(COMMAND_REQUEST_FILE)) return@Runnable
            cleanupOfflineCapture(deletePart = true)
            stopOfflineTransfer()
            completeCommandWithError(
                COMMAND_REQUEST_FILE,
                "RECORDING_CARD_DOWNLOAD_TIMEOUT",
                "Recording-card download timed out.",
                retireTransport = true,
            )
        }
        commandTimeouts[COMMAND_REQUEST_FILE] = timeout
        mainHandler.postDelayed(timeout, downloadOverallTimeoutMs(sizeBytes))
        scheduleDownloadInactivityTimeout()
    }

    private fun scheduleDownloadInactivityTimeout() {
        offlineInactivityTimeout?.let(mainHandler::removeCallbacks)
        val timeout = Runnable {
            if (!pendingCommands.containsKey(COMMAND_REQUEST_FILE)) return@Runnable
            failOfflineCapture(
                "RECORDING_CARD_DOWNLOAD_INACTIVITY_TIMEOUT",
                "Recording-card download stopped making progress.",
            )
        }
        offlineInactivityTimeout = timeout
        mainHandler.postDelayed(timeout, DOWNLOAD_INACTIVITY_TIMEOUT_MS)
    }

    private fun emitTransferProgress(capture: OfflineCapture, force: Boolean = false) {
        val now = android.os.SystemClock.elapsedRealtime()
        if (!force && now - capture.lastProgressEmittedAtMs < TRANSFER_PROGRESS_INTERVAL_MS) return
        capture.lastProgressEmittedAtMs = now
        val progress = transferProgressMap(capture)
        val event = mutableMapOf<String, Any?>("type" to "transfer_progress", "progress" to progress)
        if (capture.transferTransport == "wifi") {
            event["recoveryBatchId"] = wifiRecoveryBatchId
            event["attemptId"] = wifiAttemptId
        }
        mainHandler.post { eventSink?.success(event) }
    }

    private fun emitRecordingStateInvalidated() {
        mainHandler.post {
            eventSink?.success(mapOf("type" to "recording_state_invalidated"))
        }
    }

    @SuppressLint("MissingPermission")
    private fun stopOfflineTransfer() {
        val currentGatt = gatt ?: return
        val characteristic = writeCharacteristic ?: return
        val writeType = when {
            characteristic.properties and BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE != 0 ->
                BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE
            characteristic.properties and BluetoothGattCharacteristic.PROPERTY_WRITE != 0 ->
                BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
            else -> return
        }
        val frame = encodeFrame(COMMAND_STOP_FILE_TRANSFER, byteArrayOf())
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            currentGatt.writeCharacteristic(characteristic, frame, writeType)
        } else {
            @Suppress("DEPRECATION")
            run {
                characteristic.writeType = writeType
                characteristic.value = frame
                currentGatt.writeCharacteristic(characteristic)
            }
        }
    }

    private fun handleControlPacket(packet: RecordingCardPacket) {
        debugLog(
            "rx command=0x${packet.command.toString(16).padStart(2, '0')} " +
                "payloadBytes=${packet.payload.size} " +
                "pending=${pendingCommands.containsKey(packet.command)}",
        )
        if (packet.command == COMMAND_WIFI_CREDENTIALS) {
            if (!recordingCardShouldAcceptWifiCredentials(
                    preparationInFlight = wifiPrepareResult != null,
                    unsolicitedGateOpen = acceptsUnsolicitedWifiCredentials,
                )
            ) {
                debugLog("ignored stale Wi-Fi credentials outside preparation")
                return
            }
            parseWifiCredentials(packet.payload)?.let { credentials ->
                cacheWifiCredentialLease(credentials)
                debugLog(
                    "wifi credentials cached for current transport " +
                        "activePreparation=${wifiPrepareResult != null}",
                )
                if (wifiPrepareResult != null) finishWifiPreparationIfPossible()
            }
            return
        }
        if (packet.command == COMMAND_REQUEST_FILE &&
            pendingCommands.containsKey(COMMAND_REQUEST_FILE) &&
            packet.payload.firstOrNull()?.toInt()?.and(0xff) == 0x02
        ) {
            val capture = offlineCapture
            when {
                capture == null || !capture.acknowledged -> failOfflineCapture(
                    "RECORDING_CARD_FILE_REQUEST_REJECTED",
                    "Recording-card file request ended before acknowledgement.",
                )
                capture.request.targetBytes <= 0L ||
                    capture.receivedBytes != capture.request.targetBytes -> failOfflineCapture(
                    "RECORDING_CARD_DOWNLOAD_INCOMPLETE",
                    "Recording-card file ended before its resolved size.",
                )
                else -> completeOfflineCapture(capture)
            }
            return
        }
        when (packet.command) {
            COMMAND_DEVICE_INFO -> if (!pendingCommands.containsKey(packet.command)) {
                applyDeviceInfo(packet.payload)
            }
            COMMAND_RECORDING_INFO -> if (!pendingCommands.containsKey(packet.command)) {
                applyRecordingInfo(packet.payload)
            }
            COMMAND_STATUS_CHANGED -> {
                packet.payload.getOrNull(1)?.toInt()?.and(0xff)?.let { battery ->
                    batteryPercent = battery.coerceIn(0, 100)
                }
                emitSnapshot()
                emitRecordingStateInvalidated()
            }
        }

        if (!pendingCommands.containsKey(packet.command)) {
            recordingCardRecordingCommandPayload(packet.command, packet.payload)?.let { parsed ->
                applyRecordingPayload(parsed, "statusNotification")
                emitSnapshot()
            }
        }

        val pending = pendingCommands[packet.command]
            ?.takeIf { it.ownership.transportGeneration == transportGeneration }
            ?: return
        try {
            when (val response = pending.onPacket(packet.payload)) {
                CommandResponse.Wait -> Unit
                is CommandResponse.Complete -> {
                    clearPendingCommand(packet.command)
                    pending.result?.success(response.value)
                }
            }
        } catch (failure: Exception) {
            if (packet.command == COMMAND_REQUEST_FILE) {
                cleanupOfflineCapture(deletePart = true)
                stopOfflineTransfer()
            }
            completeCommandWithError(
                packet.command,
                if (failure is RecordingCardHandshakeFailure) {
                    failure.code
                } else if (failure is FileRequestFailure) {
                    failure.code
                } else if (failure is BluetoothNameSetFailure) {
                    failure.code
                } else {
                    "RECORDING_CARD_COMMAND_REJECTED"
                },
                if (failure is RecordingCardHandshakeFailure) {
                    failure.safeMessage
                } else if (failure is FileRequestFailure) {
                    failure.safeMessage
                } else if (failure is BluetoothNameSetFailure) {
                    failure.safeMessage
                } else {
                    "Recording-card command was rejected."
                },
            )
        }
    }

    private fun ownsWifiPreparation(generation: Long): Boolean =
        generation == wifiPreparationGeneration && wifiPrepareResult != null

    private fun cacheWifiCredentialLease(credentials: WifiCredentials) {
        pendingWifiCredentials = credentials
        pendingWifiCredentialTransportGeneration = transportGeneration
        pendingWifiCredentialFingerprint = safeFingerprint
    }

    private fun clearWifiCredentialLease() {
        pendingWifiCredentials = null
        pendingWifiCredentialTransportGeneration = null
        pendingWifiCredentialFingerprint = null
    }

    private fun discardWifiCredentialLeaseUnlessCurrent() {
        if (!recordingCardWifiCredentialLeaseIsReusable(
                observedTransportGeneration = pendingWifiCredentialTransportGeneration,
                currentTransportGeneration = transportGeneration,
                observedFingerprint = pendingWifiCredentialFingerprint,
                currentFingerprint = safeFingerprint,
            )
        ) {
            clearWifiCredentialLease()
        }
    }

    private fun finishWifiPreparationIfPossible(
        expectedGeneration: Long = wifiPreparationGeneration,
    ) {
        if (!ownsWifiPreparation(expectedGeneration)) return
        val credentials = pendingWifiCredentials ?: return
        val result = wifiPrepareResult ?: return
        if (!wifiPreparationAcknowledged) return
        wifiCredentialTimeout?.let(mainHandler::removeCallbacks)
        wifiCredentialTimeout = null
        wifiPrepareResult = null
        wifiPreparationAcknowledged = false
        acceptsUnsolicitedWifiCredentials = false
        wifiPreparationGeneration += 1
        wifiBleDisconnectExpected = true
        wifiHandoffReady = true
        connectionState = "disconnected"
        connectionStage = "idle"
        statusMessage = "录音卡已切换到 Wi-Fi 传输"
        debugLog("wifi preparation completed; BLE projected disconnected for hotspot handoff")
        emitSnapshot()
        result.success(mapOf("ssid" to credentials.ssid, "password" to credentials.password))
    }

    private fun finishWifiPreparation(
        code: String,
        expectedGeneration: Long? = null,
        allowHotspotDisable: Boolean = true,
        terminalShutdownRequested: Boolean = false,
        afterHotspotSettlement: (() -> Unit)? = null,
    ) {
        if (expectedGeneration != null && expectedGeneration != wifiPreparationGeneration) return
        if (wifiHotspotDisableInFlight) {
            afterHotspotSettlement?.let(wifiHotspotDisableWaiters::add)
            return
        }
        wifiCredentialTimeout?.let(mainHandler::removeCallbacks)
        wifiCredentialTimeout = null
        val result = wifiPrepareResult
        val pendingWifiCommand = pendingCommands[COMMAND_ENABLE_WIFI]
        val enableMayHaveBeenDispatched = wifiHotspotEnableMayHaveBeenDispatched ||
            (pendingWifiCommand?.dispatchCount ?: 0) > 0
        val shouldDisableHotspot = recordingCardWifiShouldDisableHotspot(
            hotspotEnableAcknowledged = wifiPreparationAcknowledged,
            hotspotEnableMayHaveBeenDispatched = enableMayHaveBeenDispatched,
            handoffReady = wifiHandoffReady,
            bleWritable = allowHotspotDisable &&
                (isTransportReady() ||
                    (wifiHandoffReady && gatt != null && writeCharacteristic != null)),
            terminalShutdownRequested = terminalShutdownRequested,
        )
        val abandonedCommand = pendingWifiCommand?.takeIf { pending ->
            recordingCardAbandonedCommandRequiresTransportRetirement(
                pending.ownership,
                transportGeneration,
                pending.dispatchCount,
            )
        }
        if (result != null) clearPendingCommand(COMMAND_ENABLE_WIFI)
        wifiPrepareResult = null
        wifiPreparationAcknowledged = false
        clearWifiCredentialLease()
        acceptsUnsolicitedWifiCredentials = false
        wifiHandoffReady = false
        wifiPreparationGeneration += 1
        if (shouldDisableHotspot) {
            beginWifiHotspotDisable {
                result?.error(code, "Recording-card Wi-Fi preparation failed.", null)
                afterHotspotSettlement?.invoke()
            }
        } else {
            wifiHotspotEnableMayHaveBeenDispatched = false
            wifiBleDisconnectExpected = false
            result?.error(code, "Recording-card Wi-Fi preparation failed.", null)
            afterHotspotSettlement?.invoke()
        }
        if (abandonedCommand != null && !shouldDisableHotspot && allowHotspotDisable) {
            retireGattTransport("Wi-Fi preparation abandoned")
        }
    }

    private fun beginWifiHotspotDisable(afterSettlement: () -> Unit) {
        check(!wifiHotspotDisableInFlight)
        wifiHotspotDisableWaiters += afterSettlement
        val disableGeneration = wifiHotspotDisableBarrier.begin()
        wifiBleDisconnectExpected = true
        debugLog("wifi preparation failure disabling hotspot generation=$disableGeneration")
        val disableStartedAt = SystemClock.elapsedRealtime()
        val callback = object : MethodChannel.Result {
            override fun success(value: Any?) = settle()

            override fun error(
                errorCode: String,
                errorMessage: String?,
                errorDetails: Any?,
            ) = settle()

            override fun notImplemented() = settle()

            private fun settle() {
                settleWifiHotspotDisableCommand(disableGeneration)
            }
        }
        val dispatched = sendCommand(
            COMMAND_ENABLE_WIFI,
            byteArrayOf(0),
            callback,
            allowWifiHandoffCleanup = true,
            timeoutMs = WIFI_HOTSPOT_DISABLE_TIMEOUT_MS,
        ) { payload ->
            if (payload.firstOrNull()?.toInt()?.and(0xff) != 0) {
                throw IllegalStateException("wifi disable rejected")
            }
            CommandResponse.Complete(Unit)
        }
        if (!dispatched) settleWifiHotspotDisableCommand(disableGeneration)
        val elapsed = (SystemClock.elapsedRealtime() - disableStartedAt).coerceAtLeast(0L)
        val remainingDelay = (WIFI_HOTSPOT_DISABLE_TIMEOUT_MS - elapsed).coerceAtLeast(0L)
        lateinit var minimumDelay: Runnable
        minimumDelay = Runnable {
            if (wifiHotspotDisableMinimumDelay !== minimumDelay) return@Runnable
            wifiHotspotDisableMinimumDelay = null
            if (wifiHotspotDisableBarrier.elapseMinimumDelay(disableGeneration)) {
                completeWifiHotspotDisableSettlement()
            }
        }
        wifiHotspotDisableMinimumDelay = minimumDelay
        mainHandler.postDelayed(minimumDelay, remainingDelay)
    }

    private fun settleWifiHotspotDisableCommand(disableGeneration: Long) {
        if (wifiHotspotDisableBarrier.settleCommand(disableGeneration)) {
            completeWifiHotspotDisableSettlement()
        }
    }

    private fun forceSettleWifiHotspotDisable() {
        wifiHotspotDisableMinimumDelay?.let(mainHandler::removeCallbacks)
        wifiHotspotDisableMinimumDelay = null
        if (!wifiHotspotDisableBarrier.forceSettle()) return
        clearPendingCommand(COMMAND_ENABLE_WIFI)
        completeWifiHotspotDisableSettlement()
    }

    private fun completeWifiHotspotDisableSettlement() {
        wifiHotspotDisableMinimumDelay?.let(mainHandler::removeCallbacks)
        wifiHotspotDisableMinimumDelay = null
        wifiHotspotEnableMayHaveBeenDispatched = false
        wifiBleDisconnectExpected = false
        debugLog("wifi preparation failure hotspot disable settled")
        val waiters = wifiHotspotDisableWaiters.toList()
        wifiHotspotDisableWaiters.clear()
        waiters.forEach { waiter ->
            runCatching(waiter).onFailure { failure ->
                debugLog(
                    "wifi hotspot settlement waiter failed type=${failure.javaClass.simpleName}",
                )
            }
        }
    }

    private fun scheduleWifiCredentialTimeout(preparationGeneration: Long) {
        wifiCredentialTimeout?.let(mainHandler::removeCallbacks)
        wifiCredentialTimeout = Runnable {
            finishWifiPreparation(
                "RECORDING_CARD_WIFI_CREDENTIALS_TIMEOUT",
                preparationGeneration,
            )
        }.also { mainHandler.postDelayed(it, COMMAND_TIMEOUT_MS) }
    }

    private fun parseWifiCredentials(payload: ByteArray): WifiCredentials? {
        val bytes = if (payload.firstOrNull()?.toInt()?.and(0xff) == 0) {
            payload.copyOfRange(1, payload.size)
        } else {
            payload
        }
        if (bytes.isEmpty()) return null
        if (bytes.size >= 18 && bytes.copyOfRange(18, bytes.size).all { it == 0.toByte() }) {
            val ssid = printableWifiText(bytes.copyOfRange(0, 10), 64)
            val password = printableWifiText(bytes.copyOfRange(10, 18), 128)
            if (ssid != null && password != null) return WifiCredentials(ssid, password)
        }
        if (bytes.size >= 24 && bytes.copyOfRange(24, bytes.size).all { it == 0.toByte() }) {
            val ssid = printableWifiText(bytes.copyOfRange(0, 16), 64)
            val password = printableWifiText(bytes.copyOfRange(16, 24), 128)
            if (ssid != null && password != null) return WifiCredentials(ssid, password)
        }
        val separator = bytes.indexOf(0.toByte())
        if (separator >= 0 && separator < bytes.lastIndex) {
            val ssid = printableWifiText(bytes.copyOfRange(0, separator), 64)
            val password = printableWifiText(bytes.copyOfRange(separator + 1, bytes.size), 128)
            if (ssid != null && password != null) return WifiCredentials(ssid, password)
        }
        listOf(10, 16).forEach { ssidLength ->
            if (bytes.size > ssidLength) {
                val ssid = printableWifiText(bytes.copyOfRange(0, ssidLength), 64)
                val password = printableWifiText(bytes.copyOfRange(ssidLength, bytes.size), 128)
                if (ssid != null && password != null) return WifiCredentials(ssid, password)
            }
        }
        return null
    }

    private fun printableWifiText(value: ByteArray, maximumLength: Int): String? {
        var end = value.indexOf(0.toByte()).takeIf { it >= 0 } ?: value.size
        while (end > 0 && value[end - 1].toInt() == 0x20) end--
        if (end <= 0 || end > maximumLength) return null
        val bytes = value.copyOfRange(0, end)
        if (bytes.any { byte ->
                val code = byte.toInt() and 0xff
                code !in 0x20..0x7e
            }
        ) return null
        return bytes.toString(StandardCharsets.US_ASCII)
    }

    private fun applyDeviceInfo(
        payload: ByteArray,
        applyRecordingState: Boolean = true,
    ) {
        if (payload.size >= 4) {
            val totalMb = readUInt32(payload, 0)
            if (totalMb in 1 until 1_048_576) storageTotalBytes = totalMb * 1_048_576L
        }
        if (payload.size >= 8) {
            val freeMb = readUInt32(payload, 4)
            if (freeMb in 0 until 1_048_576) storageFreeBytes = freeMb * 1_048_576L
        }
        if (storageTotalBytes != null && storageFreeBytes != null) {
            storageUsedBytes = (storageTotalBytes!! - storageFreeBytes!!).coerceAtLeast(0L)
        }
        payload.getOrNull(9)?.toInt()?.and(0xff)?.let { batteryPercent = it.coerceIn(0, 100) }
        if (applyRecordingState) {
            updateRecordingState(
                recordingCardStateFromDeviceInfo(payload.getOrNull(10)?.toInt()?.and(0xff)),
                "deviceInfo",
            )
        }
        if (payload.size > 13) {
            firmwareVersion = "${payload[11].toInt() and 0xff}.${payload[12].toInt() and 0xff}.${payload[13].toInt() and 0xff}"
        }
        if (payload.size > 37) deviceModel = asciiText(payload.copyOfRange(17, 38))
        if (payload.size > 49) {
            recordingFormat = when (payload[49].toInt() and 0xff) {
                0x00 -> "mp3"
                0x01 -> "opus"
                else -> "unknown"
            }
        }
        payload.getOrNull(44)?.toInt()?.and(0xff)?.let { wifiSupported = it != 0 }
        if (payload.size > 47) {
            wifiFirmwareVersion = "${payload[45].toInt() and 0xff}.${payload[46].toInt() and 0xff}.${payload[47].toInt() and 0xff}"
        }
        lastInfoRefreshedAt = isoNow()
        emitSnapshot()
    }

    private fun applyRecordingInfo(payload: ByteArray) {
        recordingCardRecordingInfoPayload(payload)?.let { parsed ->
            applyRecordingPayload(parsed, "recordingInfo")
        }
        emitSnapshot()
    }

    private fun applyRecordingPayload(parsed: RecordingCardRecordingPayload, source: String) {
        if (parsed.state == "idle") {
            lastCompletedFileName = parsed.fileName ?: currentFileName ?: lastCompletedFileName
            lastCompletedFileSizeBytes =
                parsed.sizeBytes ?: currentFileSizeBytes ?: lastCompletedFileSizeBytes
            lastCompletedRecordingType =
                parsed.recordingType ?: currentRecordingType ?: lastCompletedRecordingType
            lastCompletedFileNeedsSync = parsed.needsSync ?: lastCompletedFileNeedsSync
            updateRecordingState(parsed.state, source)
            return
        }
        if (recordingState == "idle") {
            currentFileName = null
            currentFileSizeBytes = null
            currentRecordingType = null
        }
        updateRecordingState(parsed.state, source, parsed.fileName)
        parsed.fileName?.let { currentFileName = it }
        parsed.sizeBytes?.let { currentFileSizeBytes = it }
        parsed.recordingType?.let { currentRecordingType = it }
    }

    private fun parseFileRow(payload: ByteArray, rowIndex: Int): Map<String, Any>? {
        if (payload.size < 19 || payload.firstOrNull()?.toInt() != 0) return null
        val filename = asciiText(payload.copyOfRange(1, 15)) ?: "recording-${rowIndex + 1}"
        if (!isSafeFilename(filename)) return null
        val key = "card-${filename.lowercase()}"
        val littleEndianSize = readUInt32LittleEndian(payload, 15)
        val bigEndianSize = readUInt32(payload, 15)
        val row = mutableMapOf<String, Any>(
            "deviceFileId" to key,
            "localFileKey" to key,
            "deviceFilename" to filename,
            "format" to "unknown",
            "syncState" to "deviceOnly",
        )
        resolveRecordingCardDeviceFileSize(littleEndianSize, bigEndianSize)?.let { resolved ->
            row["sizeBytes"] = resolved.first
            row["sizeConfidence"] = resolved.second
        }
        return row
    }

    private fun disconnect(
        result: MethodChannel.Result? = null,
        waitForHotspotDisable: Boolean = true,
    ) {
        cancelConnectDeadline()
        cancelGattRetry()
        stopScan()
        cancelPendingScanForExplicitDisconnect()
        cancelPendingConnectForExplicitDisconnect()
        clearPendingCommandsExcept(COMMAND_ENABLE_WIFI)
        requestedFingerprint = null
        requestedBindingToken = null
        requestedExpectedSerialNumber = null
        pendingGattDevice = null
        pendingGattFingerprint = null
        gattRetryCount = 0
        gattLinkEstablished = false
        finishWifiPreparation(
            "RECORDING_CARD_WIFI_DISCONNECTED",
            allowHotspotDisable = waitForHotspotDisable,
            terminalShutdownRequested = true,
            afterHotspotSettlement = { completeExplicitDisconnect(result) },
        )
        if (!waitForHotspotDisable) forceSettleWifiHotspotDisable()
    }

    private fun completeExplicitDisconnect(result: MethodChannel.Result?) {
        clearAllPendingCommands()
        closeWifiSessionInternal(deleteActivePart = true, cancelled = true)
        wifiAttemptOwned = false
        wifiBleDisconnectExpected = false
        wifiHandoffReady = false
        closeGatt()
        resetRecordingRuntime("transportDisconnected")
        connectionState = "disconnected"
        connectionStage = "idle"
        statusMessage = "录音卡已断开"
        safeFingerprint = null
        deviceName = null
        emitSnapshot()
        result?.success(deviceStateMap())
    }

    private fun cancelPendingScanForExplicitDisconnect() {
        val pendingScan = scanResult ?: return
        scanResult = null
        pendingScan.error(
            "RECORDING_CARD_SCAN_CANCELLED",
            "Recording-card scan was cancelled.",
            null,
        )
    }

    private fun cancelPendingConnectForExplicitDisconnect() {
        val pendingConnect = connectResult ?: return
        connectResult = null
        pendingConnect.error(
            "RECORDING_CARD_CONNECTION_CANCELLED",
            "Recording-card connection was cancelled.",
            null,
        )
    }

    private fun failScanAndConnect(code: String, message: String) {
        stopScan()
        val preserveConnection = scanPreservesConnection && isReady()
        scanPreservesConnection = false
        if (connectResult != null) {
            failConnect(code, message)
        } else {
            scanResult?.error(code, message, null)
            scanResult = null
        }
        if (preserveConnection) {
            connectionState = "connected"
            connectionStage = "connected"
            statusMessage = message
            emitSnapshot()
            return
        }
        connectionState = "error"
        connectionStage = "failed"
        statusMessage = message
        emitSnapshot()
    }

    private fun failConnect(
        code: String,
        message: String,
        failureState: String = "error",
        failureStage: String = "failed",
    ) {
        debugLog("connect failed code=$code stage=$connectionStage handshakeCommand=$handshakeCommand")
        cancelConnectDeadline()
        cancelGattRetry()
        cancelMtuDeadline()
        stopScan()
        if (connectResult != null) abandonPendingSetupCommands() else clearAllPendingCommands()
        closeGatt()
        resetRecordingRuntime("transportDisconnected")
        connectResult?.error(code, message, null)
        connectResult = null
        requestedFingerprint = null
        requestedBindingToken = null
        requestedExpectedSerialNumber = null
        pendingGattDevice = null
        pendingGattFingerprint = null
        gattRetryCount = 0
        gattLinkEstablished = false
        finishWifiPreparation("RECORDING_CARD_WIFI_DISCONNECTED")
        connectionState = failureState
        connectionStage = failureStage
        statusMessage = message
        emitSnapshot()
    }

    private fun abandonPendingSetupCommands() {
        cancelBindingInfoRetry()
        commandTimeouts.values.forEach(mainHandler::removeCallbacks)
        commandTimeouts.clear()
        pendingCommands.clear()
    }

    private fun scheduleConnectDeadline(timeoutMs: Long) {
        cancelConnectDeadline()
        val deadline = Runnable {
            if (connectResult == null) return@Runnable
            val code = recordingCardConnectionDeadlineErrorCode(connectionStage)
            failConnect(
                code,
                if (code == "RECORDING_CARD_NOT_FOUND") {
                    "No compatible recording card was found."
                } else {
                    "Recording-card connection setup timed out."
                },
            )
        }
        connectDeadline = deadline
        mainHandler.postDelayed(deadline, timeoutMs)
    }

    private fun cancelConnectDeadline() {
        connectDeadline?.let(mainHandler::removeCallbacks)
        connectDeadline = null
    }

    private fun completeCommandWithError(
        command: Int,
        code: String,
        message: String,
        ownership: RecordingCardCommandOwnership? = null,
        retireTransport: Boolean = false,
    ) {
        val pending = pendingCommands[command] ?: return
        if (ownership != null && pending.ownership != ownership) return
        val shouldRetireTransport = retireTransport &&
            recordingCardAbandonedCommandRequiresTransportRetirement(
                pending.ownership,
                transportGeneration,
                pending.dispatchCount,
            )
        pendingCommands.remove(command)
        commandTimeouts.remove(command)?.let(mainHandler::removeCallbacks)
        if (command == COMMAND_GET_BINDING_INFO) cancelBindingInfoRetry()
        if (command == COMMAND_REQUEST_FILE) {
            cleanupOfflineCapture(deletePart = true)
            stopOfflineTransfer()
        }
        pending.result?.error(code, message, null)
        if (shouldRetireTransport) {
            retireGattTransport("command abandoned")
        }
    }

    private fun retireGattTransport(reason: String) {
        if (gatt == null) return
        debugLog("retiring GATT transport reason=$reason")
        settleGattTransportDisconnect(expectedWifiHandoff = false)
    }

    private fun clearPendingCommand(command: Int) {
        pendingCommands.remove(command)
        commandTimeouts.remove(command)?.let(mainHandler::removeCallbacks)
        if (command == COMMAND_GET_BINDING_INFO) cancelBindingInfoRetry()
        if (command == COMMAND_REQUEST_FILE) {
            offlineInactivityTimeout?.let(mainHandler::removeCallbacks)
            offlineInactivityTimeout = null
        }
    }

    private fun clearAllPendingCommands() {
        pendingCommands.keys.toList().forEach { command ->
            completeCommandWithError(command, "RECORDING_CARD_DISCONNECTED", "Recording-card disconnected.")
        }
    }

    private fun clearPendingCommandsExcept(retainedCommand: Int) {
        pendingCommands.keys
            .filter { command -> command != retainedCommand }
            .forEach { command ->
                completeCommandWithError(
                    command,
                    "RECORDING_CARD_DISCONNECTED",
                    "Recording-card disconnected.",
                )
            }
    }

    @SuppressLint("MissingPermission")
    private fun resetGattTransportForForceScan(): Boolean {
        val activeGatt = gatt
        if (recordingCardForceScanTransportAction(activeGatt != null) ==
            RecordingCardForceScanTransportAction.START_SCAN
        ) {
            return false
        }
        checkNotNull(activeGatt)
        forceScanDisconnectGatt = activeGatt
        cancelMtuDeadline()
        mtuNegotiationCompleted = false
        serviceDiscoveryStarted = false
        connectedSerialNumber = null
        writeCharacteristic = null
        controlCharacteristic = null
        realtimeCharacteristic = null
        offlineCharacteristic = null
        notificationSetup.reset()
        clearWifiCredentialLease()
        acceptsUnsolicitedWifiCredentials = false
        wifiBleDisconnectExpected = false
        wifiHandoffReady = false
        frameDecoder.reset()
        discoveredDevices.clear()
        discoveredRows.clear()
        connectionState = "connecting"
        connectionStage = "connecting"
        statusMessage = "正在重置旧录音卡连接"
        emitSnapshot()
        val disconnectRequested = runCatching {
            activeGatt.disconnect()
            true
        }.getOrDefault(false)
        if (disconnectRequested) {
            debugLog("force-scan awaiting active GATT disconnect")
            return true
        }
        forceScanDisconnectGatt = null
        if (gatt === activeGatt) gatt = null
        runCatching { activeGatt.close() }
        return false
    }

    @SuppressLint("MissingPermission")
    private fun completeForceScanTransportReset(disconnectedGatt: BluetoothGatt) {
        if (forceScanDisconnectGatt !== disconnectedGatt) return
        forceScanDisconnectGatt = null
        if (gatt === disconnectedGatt) gatt = null
        runCatching { disconnectedGatt.close() }
        resetRecordingRuntime("transportDisconnected")
        debugLog("force-scan active GATT disconnect completed")
        if (connectResult == null) return
        val readiness = bluetoothAccess.connectionReadiness()
        if (readiness != RecordingCardBluetoothReadiness.READY) {
            failForBluetoothReadiness(readiness)
            return
        }
        startScan()
    }

    @SuppressLint("MissingPermission")
    private fun closeGatt(preserveWifiHandoff: Boolean = false) {
        if (gattCloseInProgress) return
        gattCloseInProgress = true
        val keepPreparedWifiHandoff = recordingCardPreservesPreparedWifiHandoff(
            preserveRequested = preserveWifiHandoff,
            handoffReady = wifiHandoffReady,
            preparationInFlight = wifiPrepareResult != null,
        )
        try {
            if (!keepPreparedWifiHandoff) {
                finishWifiPreparation(
                    "RECORDING_CARD_WIFI_DISCONNECTED",
                    allowHotspotDisable = false,
                )
                forceSettleWifiHotspotDisable()
                clearWifiCredentialLease()
                acceptsUnsolicitedWifiCredentials = false
                wifiHotspotEnableMayHaveBeenDispatched = false
                wifiBleDisconnectExpected = false
                wifiHandoffReady = false
            }
            transportGeneration += 1L
            if (transportGeneration == 0L) transportGeneration += 1L
            resetHandshake()
            cancelMtuDeadline()
            mtuNegotiationCompleted = false
            serviceDiscoveryStarted = false
            cleanupOfflineCapture(deletePart = true)
            val closingGatt = gatt
            gatt = null
            forceScanDisconnectGatt = null
            connectedSerialNumber = null
            runCatching { closingGatt?.disconnect() }
            runCatching { closingGatt?.close() }
            writeCharacteristic = null
            controlCharacteristic = null
            realtimeCharacteristic = null
            offlineCharacteristic = null
            notificationSetup.reset()
            frameDecoder.reset()
        } finally {
            gattCloseInProgress = false
        }
    }

    private fun debugLog(message: String) {
        val debuggable = context.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE != 0
        if (debuggable) Log.d(DEBUG_TAG, message)
    }

    private fun runOnMain(action: () -> Unit) {
        if (Looper.myLooper() == Looper.getMainLooper()) {
            action()
        } else {
            mainHandler.post(action)
        }
    }

    private fun ensureBluetoothReady(result: MethodChannel.Result): Boolean {
        val readiness = bluetoothAccess.connectionReadiness()
        if (readiness != RecordingCardBluetoothReadiness.READY) {
            failForBluetoothReadiness(readiness, result)
            return false
        }
        permissionProblem = null
        return true
    }

    private fun ensureBluetoothScanReady(): Boolean {
        val readiness = bluetoothAccess.discoveryReadiness()
        if (readiness != RecordingCardBluetoothReadiness.READY) {
            failForBluetoothReadiness(readiness)
            return false
        }
        permissionProblem = null
        return true
    }

    private fun failForBluetoothReadiness(
        readiness: RecordingCardBluetoothReadiness,
        directResult: MethodChannel.Result? = null,
    ) {
        val failure = readiness.failureOrNull() ?: return
        permissionProblem = failure.permissionProblem
        if (directResult != null) {
            connectionState = "disconnected"
            connectionStage = "idle"
            statusMessage = failure.statusMessage
            emitSnapshot()
            directResult.error(failure.code, failure.safeMessage, null)
            return
        }
        if (scanResult != null || connectResult != null) {
            failScanAndConnect(failure.code, failure.safeMessage)
            return
        }
        cancelConnectDeadline()
        cancelGattRetry()
        stopScan()
        clearAllPendingCommands()
        closeGatt()
        resetRecordingRuntime("transportDisconnected")
        connectionState = "error"
        connectionStage = "failed"
        statusMessage = failure.statusMessage
        emitSnapshot()
    }

    private fun isReady(): Boolean =
        connectionState == "connected" && gatt != null && writeCharacteristic != null

    private fun isTransportReady(): Boolean =
        (connectionState == "connecting" || connectionState == "connected") &&
            gatt != null && writeCharacteristic != null

    private fun deviceStateMap(): Map<String, Any?> = buildMap {
        put("connectionState", connectionState)
        put("connectionStage", connectionStage)
        deviceName?.let { put("displayName", it) }
        safeFingerprint?.let { put("safeDeviceFingerprint", it) }
        if (connectionState == "connected") {
            connectedSerialNumber?.let { put("serialNumber", it) }
        }
        batteryPercent?.let { put("batteryPercent", it) }
        storageTotalBytes?.let { put("storageTotalBytes", it) }
        storageFreeBytes?.let { put("storageFreeBytes", it) }
        storageUsedBytes?.let { put("storageUsedBytes", it) }
        firmwareVersion?.let { put("firmwareVersion", it) }
        deviceModel?.let { put("deviceModel", it) }
        wifiSupported?.let { put("wifiSupported", it) }
        wifiFirmwareVersion?.let { put("wifiFirmwareVersion", it) }
        put("recordingFormat", recordingFormat)
        permissionProblem?.let { put("permissionProblem", it) }
        statusMessage?.let { put("statusMessage", it) }
        lastInfoRefreshedAt?.let { put("lastInfoRefreshedAt", it) }
    }

    private fun recordingInfoMap(): Map<String, Any?> = buildMap {
        put("state", recordingState)
        put("durationSeconds", recordingClock.durationSeconds)
        recordingClock.startedAtMillis?.let { started ->
            put("startedAt", java.time.Instant.ofEpochMilli(started).toString())
        }
        currentFileName?.let { put("currentFileName", it) }
        currentFileSizeBytes?.let { put("currentFileSizeBytes", it) }
        currentRecordingType?.let { put("currentRecordingType", it) }
        lastCompletedFileName?.let { put("lastCompletedFileName", it) }
        lastCompletedFileSizeBytes?.let { put("lastCompletedFileSizeBytes", it) }
        lastCompletedRecordingType?.let { put("lastCompletedRecordingType", it) }
        lastCompletedFileNeedsSync?.let { put("lastCompletedFileNeedsSync", it) }
        put("observationSource", recordingObservationSource)
        put("revision", recordingRevision)
        put("observedAt", recordingObservedAt)
    }

    private fun runtimeSnapshotMap(): Map<String, Any?> = mapOf(
        "deviceState" to deviceStateMap(),
        "recordingInfo" to recordingInfoMap(),
        "files" to fileDirectory.snapshot(),
        "discoveredDevices" to discoveredRows.values.toList(),
        "loadingFiles" to pendingCommands.containsKey(COMMAND_LIST_FILES),
        "downloadingFileKey" to (offlineCapture?.request?.localFileKey ?: wifiDownloadFileKey),
        "transferProgress" to (offlineCapture ?: wifiActiveCapture)?.let(::transferProgressMap),
        "lastDeviceUpdatedAt" to isoNow(),
    )

    private fun transferProgressMap(capture: OfflineCapture): Map<String, Any?> {
        val elapsedMs = (android.os.SystemClock.elapsedRealtime() - capture.startedMonotonicMs)
            .coerceAtLeast(1L)
        val wifiRate = capture.wifiRateSampler?.bytesPerSecond
        val bytesPerSecond: Number? = if (capture.transferTransport == "wifi") {
            wifiRate
        } else {
            capture.receivedBytes * 1_000L / elapsedMs
        }
        val remainingBytes = (capture.request.targetBytes - capture.receivedBytes).coerceAtLeast(0L)
        val estimatedRemainingSeconds = if (capture.transferTransport == "wifi") {
            capture.wifiRateSampler?.estimatedRemainingSeconds(
                capture.receivedBytes,
                capture.request.targetBytes,
            )
        } else {
            (bytesPerSecond as? Long)?.takeIf { it > 0L }
                ?.let { (remainingBytes + it - 1L) / it }
        }
        val showRate = capture.transferTransport != "wifi" || capture.transferStage == "transferring"
        return mapOf(
            "transport" to capture.transferTransport,
            "batchId" to capture.batchId,
            "fileIndex" to capture.batchFileIndex,
            "fileCount" to capture.batchFileCount,
            "localFileKey" to capture.request.localFileKey,
            "receivedBytes" to capture.receivedBytes,
            "totalBytes" to capture.request.targetBytes.takeIf { it > 0 },
            "aggregateReceivedBytes" to capture.aggregateReceivedBase?.plus(capture.receivedBytes),
            "aggregateTotalBytes" to capture.aggregateTotalBytes,
            "bytesPerSecond" to bytesPerSecond.takeIf { showRate },
            "estimatedRemainingSeconds" to estimatedRemainingSeconds.takeIf { showRate },
            "phase" to capture.transferStage,
            "correlationId" to capture.correlationId,
            "startedAt" to capture.startedAt,
            "updatedAt" to isoNow(),
            "directorySizeMismatch" to capture.directorySizeMismatch,
        ).filterValues { it != null }
    }

    private fun emitWifiTransferProgress(capture: OfflineCapture, force: Boolean) {
        wifiLastActivityAt = SystemClock.elapsedRealtime()
        emitTransferProgress(capture, force = force)
    }

    private fun emitSnapshot() {
        mainHandler.post {
            eventSink?.success(mapOf("type" to "runtime_snapshot", "snapshot" to runtimeSnapshotMap()))
        }
    }

    @SuppressLint("MissingPermission")
    private fun safeFingerprintFor(device: BluetoothDevice): String {
        val digest = MessageDigest.getInstance("SHA-256")
            .digest(device.address.lowercase().toByteArray(StandardCharsets.UTF_8))
            .take(8)
            .joinToString("") { byte -> "%02x".format(byte.toInt() and 0xff) }
        return "android-card-$digest"
    }

    private fun isSafeFilename(value: String): Boolean =
        value.matches(Regex("[A-Za-z0-9._-]{1,80}")) && !value.endsWith(".part")

    private fun asciiText(bytes: ByteArray): String? {
        val text = bytes.toString(StandardCharsets.US_ASCII).trim('\u0000', ' ')
        return text.takeIf(::isSafeFilename)
    }

    private fun bindingTokenBytes(value: String?): ByteArray? {
        if (value == null || !value.matches(Regex("[a-fA-F0-9]{32}"))) return null
        return runCatching {
            ByteArray(16) { index ->
                value.substring(index * 2, index * 2 + 2).toInt(16).toByte()
            }
        }.getOrNull()
    }

    private fun updateRecordingState(next: String?, source: String, fileName: String? = null): Boolean {
        if (next == null) return false
        val observedAtMillis = System.currentTimeMillis()
        recordingClock.observe(next, fileName ?: currentFileName, observedAtMillis)
        recordingState = next
        if (next == "idle") {
            currentFileName = null
            currentFileSizeBytes = null
            currentRecordingType = null
        }
        recordingRevision += 1
        recordingObservationSource = source
        recordingObservedAt = java.time.Instant.ofEpochMilli(observedAtMillis).toString()
        return true
    }

    private fun resetRecordingRuntime(source: String) {
        updateRecordingState("idle", source)
        lastCompletedFileName = null
        lastCompletedFileSizeBytes = null
        lastCompletedRecordingType = null
        lastCompletedFileNeedsSync = null
    }

    private fun isoNow(): String = java.time.Instant.now().toString()

    private fun readUInt32(bytes: ByteArray, offset: Int): Long {
        if (bytes.size < offset + 4) return 0L
        return ((bytes[offset].toLong() and 0xff) shl 24) or
            ((bytes[offset + 1].toLong() and 0xff) shl 16) or
            ((bytes[offset + 2].toLong() and 0xff) shl 8) or
            (bytes[offset + 3].toLong() and 0xff)
    }

    private fun readUInt32LittleEndian(bytes: ByteArray, offset: Int): Long {
        if (bytes.size < offset + 4) return 0L
        return (bytes[offset].toLong() and 0xff) or
            ((bytes[offset + 1].toLong() and 0xff) shl 8) or
            ((bytes[offset + 2].toLong() and 0xff) shl 16) or
            ((bytes[offset + 3].toLong() and 0xff) shl 24)
    }

    private fun fileRequestPayload(filename: String, seekOffset: Long = 0L): ByteArray =
        checkNotNull(recordingCardFileRequestPayload(filename, seekOffset))

    private fun recordingFormatFor(filename: String, requestedFormat: String?): String? {
        val lower = filename.lowercase()
        val fromFilename = when {
            lower.endsWith(".mp3") -> "mp3"
            lower.endsWith(".opus") -> "opus"
            lower.endsWith(".m4a") || lower.endsWith(".mp4") -> "m4a"
            lower.endsWith(".wav") -> "wav"
            else -> null
        }
        if (fromFilename != null) return fromFilename
        val supportedFormats = setOf("mp3", "opus", "m4a", "wav")
        val candidate = requestedFormat?.lowercase()?.takeIf { it in supportedFormats }
            ?: recordingFormat
        return candidate.takeIf { it in supportedFormats }
    }

    private fun displayNameFor(filename: String, format: String): String {
        val lower = filename.lowercase()
        return if (lower.endsWith(".mp3") ||
            lower.endsWith(".opus") ||
            lower.endsWith(".m4a") ||
            lower.endsWith(".mp4") ||
            lower.endsWith(".wav")
        ) {
            filename
        } else {
            "$filename.$format"
        }
    }

    private fun mimeTypeFor(format: String): String = when (format) {
        "mp3" -> "audio/mpeg"
        "opus" -> "audio/opus"
        "m4a" -> "audio/mp4"
        "wav" -> "audio/wav"
        else -> "application/octet-stream"
    }

    private fun asNonZeroLong(value: Any?): Long? {
        val parsed = when (value) {
            is Int -> value.toLong()
            is Long -> value
            else -> null
        }
        return parsed?.takeIf { it > 0 }
    }

    private fun asNonNegativeLong(value: Any?): Long? {
        val parsed = when (value) {
            is Int -> value.toLong()
            is Long -> value
            else -> null
        }
        return parsed?.takeIf { it >= 0L }
    }

    private fun asPositiveInt(value: Any?): Int? = asNonNegativeInt(value)?.takeIf { it > 0 }

    private fun safeBatchId(value: Any?): String? = (value as? String)
        ?.takeIf { it.matches(Regex("[A-Za-z0-9_-]{1,80}")) }

    private fun isSafeSessionId(value: String): Boolean =
        value.matches(Regex("[A-Za-z0-9_-]{1,80}"))

    private fun isSafeNativeFileId(value: String): Boolean =
        value.matches(Regex("^card-[a-f0-9]{32}$"))

    private fun isValidDeviceFileSize(value: Long): Boolean {
        return value > 0L && value <= 1024L * 1024L * 1024L
    }

    private fun asNonNegativeInt(value: Any?): Int? {
        val parsed = when (value) {
            is Int -> value
            is Long -> value.takeIf { it <= Int.MAX_VALUE }?.toInt()
            else -> null
        }
        return parsed?.takeIf { it >= 0 }
    }

    private fun downloadOverallTimeoutMs(sizeBytes: Long): Long {
        val estimated = ((sizeBytes + 59_999L) / 60_000L) * 1_000L + 15_000L
        return estimated.coerceIn(DOWNLOAD_OVERALL_MIN_MS, DOWNLOAD_OVERALL_MAX_MS)
    }

    private data class DownloadRequest(
        val deviceFilename: String,
        val localFileKey: String,
        val directorySizeBytes: Long?,
        val sizeConfidence: String?,
        val targetBytes: Long,
        val durationSeconds: Int?,
        val format: String,
    ) {
        fun withTargetBytes(value: Long): DownloadRequest = copy(targetBytes = value)

        fun withDirectorySize(value: Long, confidence: String): DownloadRequest = copy(
            directorySizeBytes = value,
            sizeConfidence = confidence,
            targetBytes = value,
        )
    }

    private data class OfflineCapture(
        var request: DownloadRequest,
        val fileId: String,
        val appPrivateUri: String,
        val displayName: String,
        val partFile: File,
        val finalFile: File,
        val output: FileOutputStream,
        val digest: MessageDigest,
        val transferTransport: String = "bluetooth",
        val bleTransportGeneration: Long? = null,
        val batchId: String? = null,
        val batchFileIndex: Int? = null,
        val batchFileCount: Int? = null,
        val aggregateReceivedBase: Long? = null,
        val aggregateTotalBytes: Long? = null,
        val correlationId: String = "transfer-${UUID.randomUUID().toString().replace("-", "")}",
        val startedAt: String = java.time.Instant.now().toString(),
        val startedMonotonicMs: Long = android.os.SystemClock.elapsedRealtime(),
        var receivedBytes: Long = 0L,
        var acknowledged: Boolean = false,
        var dataComplete: Boolean = false,
        val preAckChunks: MutableList<ByteArray> = mutableListOf(),
        var preAckBytes: Long = 0L,
        var directorySizeMismatch: Boolean = false,
        var transferStage: String = "queued",
        var lastProgressEmittedAtMs: Long = 0L,
    ) {
        val wifiRateSampler: RecordingCardWifiRateSampler? =
            if (transferTransport == "wifi") {
                RecordingCardWifiRateSampler().apply {
                    reset(startedMonotonicMs, receivedBytes)
                }
            } else {
                null
            }
    }

    private class FileRequestFailure(
        val code: String,
        val safeMessage: String,
    ) : Exception(safeMessage)

    private class BluetoothNameSetFailure(
        val code: String,
        val safeMessage: String,
    ) : Exception(safeMessage)

    private data class WifiCredentials(
        val ssid: String,
        val password: String,
    )

    private class WifiDownloadFailure(
        val code: String,
        val safeMessage: String,
        val invalidatesSession: Boolean = true,
    ) : Exception(safeMessage)

    private data class WifiDirectoryEntry(
        val filename: String,
        val sizeBytes: Long,
        val sizeConfidence: String,
    )

    private class WifiSession(
        val id: String,
        val socket: Socket,
        val mainFirmwareVersion: String?,
        val wifiFirmwareVersion: String?,
        readBufferBytes: Int,
    ) {
        lateinit var input: InputStream
        lateinit var output: OutputStream
        val decoder = RecordingCardWifiStreamDecoder(
            RecordingCardWifiCompatibility.isVerifiedFirmwareProfile(
                mainFirmwareVersion,
                wifiFirmwareVersion,
            ),
        )
        val readBuffer = ByteArray(readBufferBytes)
        val packetQueue = ArrayDeque<RecordingCardWifiPacket>()
        val dataSequenceGuard = RecordingCardWifiSequenceGuard()
        val openedAt: String = java.time.Instant.now().toString()
        var directory: Map<String, WifiDirectoryEntry> = emptyMap()
        @Volatile var ready: Boolean = false
        @Volatile var closed: Boolean = false
        @Volatile var cancelled: Boolean = false
    }

    private data class PendingCommand(
        val ownership: RecordingCardCommandOwnership,
        val frame: ByteArray,
        val result: MethodChannel.Result?,
        val onPacket: (ByteArray) -> CommandResponse,
        var dispatchCount: Int = 0,
    )

    private sealed class CommandResponse {
        data object Wait : CommandResponse()

        data class Complete(val value: Any) : CommandResponse()
    }

    private fun encodeFrame(command: Int, payload: ByteArray): ByteArray {
        return recordingCardEncodeControlFrame(command, payload)
    }

    private val COMMAND_GET_SERIAL = 0x01
    private val COMMAND_GET_BINDING_INFO = 0x02
    private val COMMAND_BIND_DEVICE = 0x03
    private val COMMAND_SET_TIME = 0x04
    private val COMMAND_DEVICE_INFO = 0x05
    private val COMMAND_START = 0x06
    private val COMMAND_STOP = 0x07
    private val COMMAND_PAUSE = 0x08
    private val COMMAND_RESUME = 0x09
    private val COMMAND_LIST_FILES = 0x0a
    private val COMMAND_REQUEST_FILE = 0x0b
    private val COMMAND_STOP_FILE_TRANSFER = 0x0c
    private val COMMAND_DELETE_FILE = 0x0d
    private val COMMAND_STATUS_CHANGED = 0x0f
    private val COMMAND_RECORDING_INFO = 0x15
    private val COMMAND_SET_PHONE_TYPE = 0x18
    private val COMMAND_ENABLE_WIFI = 0x1b
    private val COMMAND_WIFI_CREDENTIALS = 0x1f
    private val COMMAND_WIFI_SESSION_STATUS = 0x20
    private val COMMAND_SET_BLUETOOTH_NAME = 0x3a
    private val WIFI_TRANSFER_HOST = "192.168.200.1"
    private val WIFI_TRANSFER_PORT = 8475
    private val WIFI_CONNECT_TIMEOUT_MS = 10_000
    private val WIFI_RESET_RECOVERY_DELAY_MS = 400L
    private val WIFI_DIRECTORY_TIMEOUT_MS = 30_000L
    private val WIFI_NATURAL_END_WAIT_MS = 750L
    private val WIFI_VERIFIED_PROFILE_NATURAL_END_WAIT_MS = 250L
    private val WIFI_STOP_CONFIRM_TIMEOUT_MS = 2_000L
    private val WIFI_PREMATURE_END_GRACE_MS = 1_000L
    private val TRANSFER_PROGRESS_INTERVAL_MS = 250L
    private val WIFI_READ_BUFFER_BYTES = 64 * 1024
}
