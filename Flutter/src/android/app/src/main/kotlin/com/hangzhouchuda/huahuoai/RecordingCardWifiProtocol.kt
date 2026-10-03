package com.hangzhouchuda.huahuoai

import java.nio.charset.StandardCharsets
import kotlin.math.ceil

internal data class RecordingCardWifiPacket(
    val command: Int,
    val sequence: Int,
    val payload: ByteArray,
)

internal class RecordingCardWifiProtocolException(
    val reason: Reason,
) : Exception(reason.name) {
    internal enum class Reason {
        BUFFER_LIMIT,
        HEADER,
        LENGTH,
        TAIL,
        CRC,
        SEQUENCE,
        OVERRUN,
    }
}

internal object RecordingCardWifiProtocol {
    private val header = "XnoteWifiHead  ".toByteArray(StandardCharsets.US_ASCII)
    private val tail = "XnoteWifiTail   ".toByteArray(StandardCharsets.US_ASCII)
    private val crc16Table = IntArray(256) { seed ->
        var value = seed
        repeat(8) {
            value = if (value and 1 == 1) (value ushr 1) xor 0xa001 else value ushr 1
        }
        value and 0xffff
    }
    internal const val MAX_PAYLOAD_BYTES = 64 * 1024 * 1024
    internal const val MAX_FRAME_BYTES = 24 + MAX_PAYLOAD_BYTES + 16

    fun encode(command: Int, sequence: Int, payload: ByteArray): ByteArray {
        require(command in 0..0xff)
        require(sequence in 0..0xffff)
        require(payload.size <= MAX_PAYLOAD_BYTES)
        val frame = ByteArray(24 + payload.size + tail.size)
        header.copyInto(frame)
        frame[15] = command.toByte()
        frame[16] = ((sequence ushr 8) and 0xff).toByte()
        frame[17] = (sequence and 0xff).toByte()
        val crc = crc16(payload)
        frame[18] = ((crc ushr 8) and 0xff).toByte()
        frame[19] = (crc and 0xff).toByte()
        val length = payload.size
        frame[20] = ((length ushr 24) and 0xff).toByte()
        frame[21] = ((length ushr 16) and 0xff).toByte()
        frame[22] = ((length ushr 8) and 0xff).toByte()
        frame[23] = (length and 0xff).toByte()
        payload.copyInto(frame, destinationOffset = 24)
        tail.copyInto(frame, destinationOffset = 24 + payload.size)
        return frame
    }

    fun decode(frame: ByteArray, allowOmittedDataCrc: Boolean = false): RecordingCardWifiPacket =
        decode(
            frame,
            offset = 0,
            length = frame.size,
            allowOmittedDataCrc = allowOmittedDataCrc,
        )

    internal fun decode(
        frame: ByteArray,
        offset: Int,
        length: Int,
        allowOmittedDataCrc: Boolean,
    ): RecordingCardWifiPacket {
        if (offset < 0 || length < 0 || offset > frame.size - length) {
            fail(RecordingCardWifiProtocolException.Reason.LENGTH)
        }
        if (length < 24 + tail.size) fail(RecordingCardWifiProtocolException.Reason.LENGTH)
        if (!matches(frame, offset, header)) {
            fail(RecordingCardWifiProtocolException.Reason.HEADER)
        }
        val payloadLength = readUInt32(frame, offset + 20, offset + length)
        if (payloadLength !in 0..MAX_PAYLOAD_BYTES.toLong()) {
            fail(RecordingCardWifiProtocolException.Reason.LENGTH)
        }
        val expectedFrameLength = 24L + payloadLength + tail.size
        if (expectedFrameLength != length.toLong()) {
            fail(RecordingCardWifiProtocolException.Reason.LENGTH)
        }
        val payloadStart = offset + 24
        val payloadEnd = payloadStart + payloadLength.toInt()
        if (!matches(frame, payloadEnd, tail)) {
            fail(RecordingCardWifiProtocolException.Reason.TAIL)
        }
        val declaredCrc = ((frame[offset + 18].toInt() and 0xff) shl 8) or
            (frame[offset + 19].toInt() and 0xff)
        val actualCrc = crc16(frame, payloadStart, payloadLength.toInt())
        if (declaredCrc != actualCrc && !(allowOmittedDataCrc && declaredCrc == 0)) {
            fail(RecordingCardWifiProtocolException.Reason.CRC)
        }
        val payload = frame.copyOfRange(payloadStart, payloadEnd)
        return RecordingCardWifiPacket(
            command = frame[offset + 15].toInt() and 0xff,
            sequence = ((frame[offset + 16].toInt() and 0xff) shl 8) or
                (frame[offset + 17].toInt() and 0xff),
            payload = payload,
        )
    }

    fun frameLength(pending: ByteArray): Int? =
        frameLength(pending, offset = 0, availableBytes = pending.size)

    internal fun frameLength(
        pending: ByteArray,
        offset: Int,
        availableBytes: Int,
    ): Int? {
        if (offset < 0 || availableBytes < 0 || offset > pending.size - availableBytes) {
            fail(RecordingCardWifiProtocolException.Reason.LENGTH)
        }
        if (availableBytes < header.size) return null
        if (!matches(pending, offset, header)) {
            fail(RecordingCardWifiProtocolException.Reason.HEADER)
        }
        if (availableBytes < 24) return null
        val payloadLength = readUInt32(pending, offset + 20, offset + availableBytes)
        if (payloadLength !in 0..MAX_PAYLOAD_BYTES.toLong()) {
            fail(RecordingCardWifiProtocolException.Reason.LENGTH)
        }
        return (24L + payloadLength + tail.size).toInt()
    }

    fun crc16(bytes: ByteArray): Int = crc16(bytes, offset = 0, length = bytes.size)

    private fun crc16(bytes: ByteArray, offset: Int, length: Int): Int {
        var crc = 0
        for (index in offset until offset + length) {
            val tableIndex = (crc xor (bytes[index].toInt() and 0xff)) and 0xff
            crc = (crc ushr 8) xor crc16Table[tableIndex]
        }
        return crc and 0xffff
    }

    private fun matches(bytes: ByteArray, offset: Int, expected: ByteArray): Boolean {
        for (index in expected.indices) {
            if (bytes[offset + index] != expected[index]) return false
        }
        return true
    }

    private fun readUInt32(bytes: ByteArray, offset: Int, limitExclusive: Int = bytes.size): Long {
        if (offset < 0 || limitExclusive > bytes.size || offset > limitExclusive - 4) {
            fail(RecordingCardWifiProtocolException.Reason.LENGTH)
        }
        return ((bytes[offset].toLong() and 0xff) shl 24) or
            ((bytes[offset + 1].toLong() and 0xff) shl 16) or
            ((bytes[offset + 2].toLong() and 0xff) shl 8) or
            (bytes[offset + 3].toLong() and 0xff)
    }

    private fun fail(reason: RecordingCardWifiProtocolException.Reason): Nothing {
        throw RecordingCardWifiProtocolException(reason)
    }
}

internal object RecordingCardWifiCompatibility {
    fun isVerifiedFirmwareProfile(mainFirmware: String?, wifiFirmware: String?): Boolean =
        mainFirmware == "1.0.6" && wifiFirmware == "1.0.2"

    fun acceptsQuietBoundary(
        mainFirmware: String?,
        wifiFirmware: String?,
        connectionHealthy: Boolean,
        queuedPackets: Int,
        pendingBytes: Int,
    ): Boolean =
        isVerifiedFirmwareProfile(mainFirmware, wifiFirmware) &&
            connectionHealthy &&
            queuedPackets == 0 &&
            pendingBytes == 0

    fun acceptsQuietStopBoundary(
        mainFirmware: String?,
        wifiFirmware: String?,
        stopWriteSucceeded: Boolean,
        connectionHealthy: Boolean,
        queuedPackets: Int,
        pendingBytes: Int,
    ): Boolean =
        stopWriteSucceeded && acceptsQuietBoundary(
            mainFirmware = mainFirmware,
            wifiFirmware = wifiFirmware,
            connectionHealthy = connectionHealthy,
            queuedPackets = queuedPackets,
            pendingBytes = pendingBytes,
        )
}

internal enum class RecordingCardWifiBoundaryMode {
    INTER_FILE_QUIET,
    REQUEST_STOP,
}

internal val RecordingCardWifiBoundaryMode.requiresStopRequest: Boolean
    get() = this == RecordingCardWifiBoundaryMode.REQUEST_STOP

internal fun recordingCardWifiBoundaryMode(
    allowQuietBoundary: Boolean,
    fileIndex: Int?,
    fileCount: Int?,
): RecordingCardWifiBoundaryMode {
    if (!allowQuietBoundary || fileIndex == null || fileCount == null ||
        fileIndex < 0 || fileCount <= 1 || fileIndex >= fileCount
    ) {
        return RecordingCardWifiBoundaryMode.REQUEST_STOP
    }
    return if (fileIndex + 1 < fileCount) {
        RecordingCardWifiBoundaryMode.INTER_FILE_QUIET
    } else {
        RecordingCardWifiBoundaryMode.REQUEST_STOP
    }
}

internal enum class RecordingCardWifiEndDecision {
    COMPLETE,
    AWAIT_TRAILING_DATA,
    FAIL_INCOMPLETE,
}

internal fun recordingCardWifiEndDecision(
    receivedBytes: Long,
    targetBytes: Long,
    graceExpired: Boolean,
): RecordingCardWifiEndDecision {
    if (targetBytes <= 0L || receivedBytes < 0L) {
        return RecordingCardWifiEndDecision.FAIL_INCOMPLETE
    }
    if (receivedBytes == targetBytes) return RecordingCardWifiEndDecision.COMPLETE
    if (receivedBytes > targetBytes) return RecordingCardWifiEndDecision.FAIL_INCOMPLETE
    return if (graceExpired) {
        RecordingCardWifiEndDecision.FAIL_INCOMPLETE
    } else {
        RecordingCardWifiEndDecision.AWAIT_TRAILING_DATA
    }
}

internal fun recordingCardWifiTailGapIsRecoverable(remainingBytes: Long): Boolean =
    remainingBytes in 1..4_040L

internal fun recordingCardWifiTailResumeOffset(
    profileAllowed: Boolean,
    receivedBytes: Long,
    targetBytes: Long,
    alreadyAttempted: Boolean,
): Long? {
    if (!profileAllowed || alreadyAttempted || receivedBytes < 4_040L ||
        receivedBytes > 0xffff_ffffL || targetBytes <= receivedBytes
    ) {
        return null
    }
    val remainingBytes = targetBytes - receivedBytes
    if (!recordingCardWifiTailGapIsRecoverable(remainingBytes)) return null
    return receivedBytes
}

internal fun recordingCardWifiTailPayloadMatches(
    remainingBytes: Long,
    payloadBytes: Int,
): Boolean =
    recordingCardWifiTailGapIsRecoverable(remainingBytes) &&
        payloadBytes.toLong() == remainingBytes

internal fun recordingCardFileRequestPayload(
    filename: String,
    seekOffset: Long = 0L,
): ByteArray? {
    val filenameBytes = filename.toByteArray(StandardCharsets.US_ASCII)
    if (filename.isEmpty() || filenameBytes.size > 14 ||
        filename.any { it.code !in 0x20..0x7e } ||
        seekOffset !in 0..0xffff_ffffL
    ) {
        return null
    }
    return ByteArray(18).also { payload ->
        filenameBytes.copyInto(payload)
        payload[14] = ((seekOffset ushr 24) and 0xff).toByte()
        payload[15] = ((seekOffset ushr 16) and 0xff).toByte()
        payload[16] = ((seekOffset ushr 8) and 0xff).toByte()
        payload[17] = (seekOffset and 0xff).toByte()
    }
}

internal class RecordingCardWifiRateSampler(
    private val minimumSampleIntervalMs: Long = 250L,
) {
    var bytesPerSecond: Double? = null
        private set
    private var sampleTimeMs: Long? = null
    private var sampleBytes = 0L

    init {
        require(minimumSampleIntervalMs > 0L)
    }

    fun reset(nowMs: Long, receivedBytes: Long = 0L) {
        sampleTimeMs = nowMs
        sampleBytes = receivedBytes.coerceAtLeast(0L)
        bytesPerSecond = null
    }

    fun observe(nowMs: Long, receivedBytes: Long): Double? {
        val previousTime = sampleTimeMs
        if (previousTime == null) {
            reset(nowMs, receivedBytes)
            return null
        }
        val elapsedMs = nowMs - previousTime
        if (elapsedMs < minimumSampleIntervalMs) return bytesPerSecond
        val deltaBytes = receivedBytes - sampleBytes
        sampleTimeMs = nowMs
        sampleBytes = receivedBytes
        if (elapsedMs <= 0L || deltaBytes <= 0L) return bytesPerSecond
        val instant = deltaBytes.toDouble() * 1_000.0 / elapsedMs.toDouble()
        if (!instant.isFinite() || instant <= 0.0) return bytesPerSecond
        bytesPerSecond = bytesPerSecond?.let { previous ->
            (previous * 0.65) + (instant * 0.35)
        } ?: instant
        return bytesPerSecond
    }

    fun estimatedRemainingSeconds(receivedBytes: Long, targetBytes: Long): Long? {
        val rate = bytesPerSecond?.takeIf { it.isFinite() && it > 0.0 } ?: return null
        val remaining = (targetBytes - receivedBytes).coerceAtLeast(0L)
        return ceil(remaining.toDouble() / rate).toLong()
    }
}

internal class RecordingCardWifiStreamDecoder(
    private val allowOmittedDataCrc: Boolean,
    private val maximumPendingBytes: Int = RecordingCardWifiProtocol.MAX_FRAME_BYTES,
) {
    private var pending = ByteArray(
        minOf(INITIAL_BUFFER_BYTES, maximumPendingBytes.coerceAtLeast(1)),
    )
    private var readCursor = 0
    private var writeCursor = 0

    init {
        require(maximumPendingBytes > 0)
    }

    val pendingBytes: Int get() = writeCursor - readCursor

    fun push(
        bytes: ByteArray,
        length: Int = bytes.size,
    ): List<RecordingCardWifiPacket> {
        require(length in 0..bytes.size)
        if (length == 0) return emptyList()
        if (length > maximumPendingBytes - pendingBytes) {
            throw RecordingCardWifiProtocolException(
                RecordingCardWifiProtocolException.Reason.BUFFER_LIMIT,
            )
        }
        ensureWritableBytes(length)
        bytes.copyInto(
            pending,
            destinationOffset = writeCursor,
            startIndex = 0,
            endIndex = length,
        )
        writeCursor += length

        val packets = mutableListOf<RecordingCardWifiPacket>()
        while (readCursor < writeCursor) {
            val availableBytes = pendingBytes
            val frameLength = RecordingCardWifiProtocol.frameLength(
                pending,
                offset = readCursor,
                availableBytes = availableBytes,
            ) ?: break
            if (availableBytes < frameLength) break
            packets += RecordingCardWifiProtocol.decode(
                pending,
                offset = readCursor,
                length = frameLength,
                allowOmittedDataCrc = allowOmittedDataCrc,
            )
            readCursor += frameLength
        }
        if (readCursor == writeCursor) {
            readCursor = 0
            writeCursor = 0
        }
        return packets
    }

    fun clear() {
        readCursor = 0
        writeCursor = 0
    }

    private fun ensureWritableBytes(byteCount: Int) {
        if (byteCount <= pending.size - writeCursor) return

        val unreadBytes = pendingBytes
        if (readCursor > 0 && byteCount <= pending.size - unreadBytes) {
            pending.copyInto(
                pending,
                destinationOffset = 0,
                startIndex = readCursor,
                endIndex = writeCursor,
            )
            readCursor = 0
            writeCursor = unreadBytes
            return
        }

        val requiredCapacity = unreadBytes + byteCount
        var nextCapacity = pending.size
        while (nextCapacity < requiredCapacity) {
            nextCapacity = minOf(
                maximumPendingBytes.toLong(),
                maxOf(requiredCapacity.toLong(), nextCapacity.toLong() * 2),
            ).toInt()
        }
        val replacement = ByteArray(nextCapacity)
        pending.copyInto(
            replacement,
            destinationOffset = 0,
            startIndex = readCursor,
            endIndex = writeCursor,
        )
        pending = replacement
        readCursor = 0
        writeCursor = unreadBytes
    }

    private companion object {
        const val INITIAL_BUFFER_BYTES = 64 * 1024
    }
}

internal class RecordingCardWifiSequenceGuard {
    private var expected: Int? = null

    fun reset() {
        expected = null
    }

    fun accept(sequence: Int) {
        require(sequence in 0..0xffff)
        expected?.let { value ->
            if (sequence != value) {
                throw RecordingCardWifiProtocolException(
                    RecordingCardWifiProtocolException.Reason.SEQUENCE,
                )
            }
        }
        expected = (sequence + 1) and 0xffff
    }
}

internal class RecordingCardWifiPayloadBudget(
    val totalBytes: Long,
) {
    var acceptedBytes: Long = 0L
        private set

    init {
        require(totalBytes > 0L)
    }

    fun accept(byteCount: Int) {
        require(byteCount >= 0)
        if (byteCount.toLong() > totalBytes - acceptedBytes) {
            throw RecordingCardWifiProtocolException(
                RecordingCardWifiProtocolException.Reason.OVERRUN,
            )
        }
        acceptedBytes += byteCount.toLong()
    }
}
