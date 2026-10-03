package com.hangzhouchuda.huahuoai

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.drawable.Icon
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioPlaybackCaptureConfiguration
import android.media.AudioRecord
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMuxer
import android.media.MediaMetadataRetriever
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.net.Uri
import android.view.Surface
import android.view.WindowManager
import android.util.DisplayMetrics
import java.io.File
import java.io.FileInputStream
import java.nio.file.AtomicMoveNotSupportedException
import java.nio.ByteBuffer
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.security.MessageDigest
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.ceil
import kotlin.math.max
import kotlin.math.min

internal class ScreenCaptureService : Service() {
    private val mainHandler = Handler(Looper.getMainLooper())
    private val finishing = AtomicBoolean(false)
    private var projection: MediaProjection? = null
    private var recorder: ProjectionMp4Recorder? = null
    private var worker: Thread? = null
    private var partFile: File? = null
    private var request: ScreenCaptureAndroidBridge.CaptureRequest? = null
    private var startedAtMillis = 0L
    private var stopReason = StopReason.USER
    private var watchdog: Runnable? = null

    private val projectionCallback = object : MediaProjection.Callback() {
        override fun onStop() {
            if (!finishing.get()) requestStopInternal(StopReason.SYSTEM)
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        ScreenCaptureSessionRegistry.initialize(applicationContext)
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> handleStart(intent)
            ACTION_STOP -> requestStopInternal(StopReason.USER)
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        cancelWatchdog()
        recorder?.requestStop()
        super.onDestroy()
    }

    private fun handleStart(intent: Intent) {
        if (worker?.isAlive == true || ScreenCaptureSessionRegistry.snapshot()["state"] == "recording") {
            return
        }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            fail("SCREEN_CAPTURE_ANDROID_VERSION_UNSUPPORTED")
            return
        }
        if (ScreenCaptureSessionRegistry.snapshot()["sessionId"] != intent.getStringExtra(EXTRA_SESSION_ID) ||
            ScreenCaptureSessionRegistry.snapshot()["state"] != "starting"
        ) {
            stopSelf()
            return
        }
        try {
            startForegroundCompat()
        } catch (_: Exception) {
            fail("SCREEN_CAPTURE_FOREGROUND_SERVICE_FAILED")
            return
        }

        val projectionData = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            intent.getParcelableExtra(EXTRA_PROJECTION_DATA, Intent::class.java)
        } else {
            @Suppress("DEPRECATION")
            intent.getParcelableExtra(EXTRA_PROJECTION_DATA)
        }
        val captureRequest = ScreenCaptureAndroidBridge.CaptureRequest(
            maxDurationSeconds = intent.getIntExtra(
                EXTRA_MAX_DURATION_SECONDS,
                ScreenCaptureAndroidBridge.DEFAULT_MAX_DURATION_SECONDS,
            ),
            maxSizeBytes = intent.getLongExtra(
                EXTRA_MAX_SIZE_BYTES,
                ScreenCaptureAndroidBridge.DEFAULT_MAX_SIZE_BYTES,
            ),
            targetWidth = intent.getIntExtra(
                EXTRA_TARGET_WIDTH,
                ScreenCaptureAndroidBridge.DEFAULT_WIDTH,
            ),
            targetHeight = intent.getIntExtra(
                EXTRA_TARGET_HEIGHT,
                ScreenCaptureAndroidBridge.DEFAULT_HEIGHT,
            ),
            sessionId = intent.getStringExtra(EXTRA_SESSION_ID) ?: "",
        )
        if (projectionData == null) {
            fail("SCREEN_CAPTURE_CONSENT_MISSING")
            return
        }

        val output = runCatching { createPartFile() }.getOrElse {
            fail("SCREEN_CAPTURE_STORAGE_FAILED")
            return
        }
        val manager = getSystemService(MediaProjectionManager::class.java)
        val activeProjection = runCatching {
            manager.getMediaProjection(
                intent.getIntExtra(EXTRA_RESULT_CODE, 0),
                projectionData,
            )
        }.getOrNull()
        if (activeProjection == null) {
            output.delete()
            fail("SCREEN_CAPTURE_CONSENT_INVALID")
            return
        }

        request = captureRequest
        partFile = output
        projection = activeProjection
        startedAtMillis = System.currentTimeMillis()
        finishing.set(false)
        stopReason = StopReason.USER
        activeProjection.registerCallback(projectionCallback, mainHandler)
        val activeRecorder = ProjectionMp4Recorder(
            context = this,
            projection = activeProjection,
            output = output,
            width = captureRequest.targetWidth and -2,
            height = captureRequest.targetHeight and -2,
        )
        recorder = activeRecorder
        worker = Thread({ runCapture(activeRecorder, output, captureRequest) }, "screen-capture")
            .also { it.start() }
    }

    private fun runCapture(
        activeRecorder: ProjectionMp4Recorder,
        output: File,
        captureRequest: ScreenCaptureAndroidBridge.CaptureRequest,
    ) {
        val hasVideo = runCatching {
            activeRecorder.recordUntilStopped {
                ScreenCaptureSessionRegistry.markRecording(startedAtMillis)
                mainHandler.post { startWatchdog(captureRequest, output) }
            }
        }.getOrElse { error ->
            finishFailure(
                (error as? ScreenCaptureRecorderException)?.code
                    ?: "SCREEN_CAPTURE_CODEC_FAILED",
            )
            return
        }
        if (!hasVideo) {
            finishFailure(
                if (stopReason == StopReason.SYSTEM) {
                    "SCREEN_CAPTURE_SYSTEM_STOPPED"
                } else {
                    "SCREEN_CAPTURE_EMPTY_FILE"
                },
            )
            return
        }
        finishSuccess(output, captureRequest)
    }

    private fun requestStopInternal(reason: StopReason) {
        if (finishing.get()) return
        stopReason = reason
        if (ScreenCaptureSessionRegistry.isActive()) {
            ScreenCaptureSessionRegistry.markStopping()
        }
        recorder?.requestStop() ?: finishFailure(
            if (reason == StopReason.SYSTEM) {
                "SCREEN_CAPTURE_SYSTEM_STOPPED"
            } else {
                "SCREEN_CAPTURE_NOT_ACTIVE"
            },
        )
    }

    private fun startWatchdog(
        captureRequest: ScreenCaptureAndroidBridge.CaptureRequest,
        output: File,
    ) {
        cancelWatchdog()
        val sizeMargin = min(2L * 1024L * 1024L, captureRequest.maxSizeBytes / 10L)
        val sizeStopThreshold = max(1L, captureRequest.maxSizeBytes - sizeMargin)
        val task = object : Runnable {
            override fun run() {
                if (finishing.get()) return
                val elapsed = System.currentTimeMillis() - startedAtMillis
                when {
                    elapsed >= captureRequest.maxDurationSeconds * 1000L ->
                        requestStopInternal(StopReason.DURATION_LIMIT)
                    output.length() >= sizeStopThreshold ->
                        requestStopInternal(StopReason.SIZE_LIMIT)
                    else -> mainHandler.postDelayed(this, WATCHDOG_INTERVAL_MS)
                }
            }
        }
        watchdog = task
        mainHandler.postDelayed(task, WATCHDOG_INTERVAL_MS)
    }

    private fun finishSuccess(
        output: File,
        captureRequest: ScreenCaptureAndroidBridge.CaptureRequest,
    ) {
        if (!finishing.compareAndSet(false, true)) return
        cancelWatchdog()
        releaseProjection()
        val elapsed = ceil(
            (System.currentTimeMillis() - startedAtMillis).coerceAtLeast(1L) / 1000.0,
        ).toInt().coerceIn(1, captureRequest.maxDurationSeconds)
        val size = output.length()
        if (size <= 0L) {
            output.delete()
            completeFailure("SCREEN_CAPTURE_EMPTY_FILE")
            return
        }
        if (size > captureRequest.maxSizeBytes ||
            size > ScreenCaptureAndroidBridge.DEFAULT_MAX_SIZE_BYTES
        ) {
            output.delete()
            completeFailure("SCREEN_CAPTURE_SIZE_LIMIT_EXCEEDED")
            return
        }

        val finalFile = File(output.parentFile, output.name.removeSuffix(".part"))
        val finalized = runCatching {
            atomicMove(output, finalFile)
            val checksum = sha256(finalFile)
            check(checksum.length == 64)
            checksum
        }
        finalized.fold(
            onSuccess = { checksum ->
                val media = mapOf(
                    "appPrivateUri" to "app-private-media://screen-capture/${finalFile.name}",
                    "fileName" to finalFile.name,
                    "mimeType" to "video/mp4",
                    "sizeBytes" to finalFile.length(),
                    "durationSeconds" to elapsed,
                    "sha256" to checksum,
                    "recordedAt" to isoDate(startedAtMillis),
                )
                ScreenCaptureSessionRegistry.markCompleted(elapsed, media)
                finishService()
            },
            onFailure = {
                output.delete()
                finalFile.delete()
                completeFailure("SCREEN_CAPTURE_STORAGE_FAILED")
            },
        )
    }

    private fun finishFailure(code: String) {
        if (!finishing.compareAndSet(false, true)) return
        cancelWatchdog()
        releaseProjection()
        partFile?.delete()
        completeFailure(code)
    }

    private fun completeFailure(code: String) {
        ScreenCaptureSessionRegistry.markFailed(code)
        finishService()
    }

    private fun fail(code: String) {
        if (!finishing.compareAndSet(false, true)) return
        completeFailure(code)
    }

    private fun releaseProjection() {
        val activeProjection = projection
        projection = null
        if (activeProjection != null) {
            runCatching { activeProjection.unregisterCallback(projectionCallback) }
            runCatching { activeProjection.stop() }
        }
        recorder = null
    }

    private fun finishService() {
        worker = null
        request = null
        partFile = null
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun cancelWatchdog() {
        watchdog?.let(mainHandler::removeCallbacks)
        watchdog = null
    }

    private fun createPartFile(): File {
        val directory = File(filesDir, "HuahuoAI/ScreenCaptures")
        check(directory.exists() || directory.mkdirs())
        val id = UUID.randomUUID().toString().replace("-", "").lowercase(Locale.US)
        val name = "screen-${System.currentTimeMillis()}-$id.mp4.part"
        return File(directory, name).also {
            check(it.createNewFile())
        }
    }

    private fun startForegroundCompat() {
        val stopIntent = Intent(this, ScreenCaptureService::class.java).apply {
            action = ACTION_STOP
        }
        val stopAction = PendingIntent.getService(
            this,
            0,
            stopIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val notificationStopAction = Notification.Action.Builder(
            Icon.createWithResource(this, android.R.drawable.ic_media_pause),
            "停止",
            stopAction,
        ).build()
        val notification: Notification = Notification.Builder(this, NOTIFICATION_CHANNEL)
            .setSmallIcon(android.R.drawable.ic_menu_camera)
            .setContentTitle("花火 AI 正在内录")
            .setContentText("停止后分离音频并上传转写")
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .addAction(notificationStopAction)
            .build()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(
                NOTIFICATION_CHANNEL,
                "内录",
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description = "显示正在进行的系统录屏"
                setSound(null, null)
            },
        )
    }

    private enum class StopReason { USER, SYSTEM, DURATION_LIMIT, SIZE_LIMIT }

    companion object {
        private const val ACTION_START = "com.hangzhouchuda.huahuoai.screen_capture.START"
        private const val ACTION_STOP = "com.hangzhouchuda.huahuoai.screen_capture.STOP"
        private const val EXTRA_RESULT_CODE = "projectionResultCode"
        private const val EXTRA_PROJECTION_DATA = "projectionData"
        private const val EXTRA_MAX_DURATION_SECONDS = "maxDurationSeconds"
        private const val EXTRA_MAX_SIZE_BYTES = "maxSizeBytes"
        private const val EXTRA_TARGET_WIDTH = "targetWidth"
        private const val EXTRA_TARGET_HEIGHT = "targetHeight"
        private const val EXTRA_SESSION_ID = "sessionId"
        private const val NOTIFICATION_CHANNEL = "huahuoai-screen-capture"
        private const val NOTIFICATION_ID = 0x5343
        private const val WATCHDOG_INTERVAL_MS = 250L

        fun start(
            context: Context,
            resultCode: Int,
            projectionData: Intent,
            request: ScreenCaptureAndroidBridge.CaptureRequest,
        ) {
            val intent = Intent(context, ScreenCaptureService::class.java).apply {
                action = ACTION_START
                putExtra(EXTRA_RESULT_CODE, resultCode)
                putExtra(EXTRA_PROJECTION_DATA, projectionData)
                putExtra(EXTRA_MAX_DURATION_SECONDS, request.maxDurationSeconds)
                putExtra(EXTRA_MAX_SIZE_BYTES, request.maxSizeBytes)
                putExtra(EXTRA_TARGET_WIDTH, request.targetWidth)
                putExtra(EXTRA_TARGET_HEIGHT, request.targetHeight)
                putExtra(EXTRA_SESSION_ID, request.sessionId)
            }
            context.startForegroundService(intent)
        }

        fun requestStop(context: Context) {
            context.startService(Intent(context, ScreenCaptureService::class.java).apply {
                action = ACTION_STOP
            })
        }

        @Synchronized
        fun importVideo(context: Context, uri: Uri, sessionId: String): Map<String, Any> {
            check(Regex("^[A-Za-z0-9_-]{1,100}$").matches(sessionId))
            val directory = File(context.filesDir, "HuahuoAI/ScreenCaptures")
            check(directory.isDirectory || directory.mkdirs())
            val output = File(directory, "import-$sessionId.mp4")
            val part = File(directory, "${output.name}.part")
            try {
                checkNotNull(context.contentResolver.openInputStream(uri)).use { input ->
                    part.outputStream().use { sink ->
                        val buffer = ByteArray(1024 * 1024)
                        var total = 0L
                        while (true) {
                            val count = input.read(buffer)
                            if (count < 0) break
                            total += count
                            check(total <= ScreenCaptureAndroidBridge.DEFAULT_MAX_SIZE_BYTES)
                            sink.write(buffer, 0, count)
                        }
                        sink.fd.sync()
                    }
                }
                val payload = videoPayload(part, output.name)
                atomicMove(part, output)
                return payload
            } finally {
                part.delete()
            }
        }

        private fun videoPayload(source: File, name: String): Map<String, Any> {
            check(source.length() in 1L..ScreenCaptureAndroidBridge.DEFAULT_MAX_SIZE_BYTES)
            source.inputStream().use {
                val header = ByteArray(12)
                check(it.read(header) == header.size && String(header, 4, 4, Charsets.US_ASCII) == "ftyp")
            }
            val extractor = MediaExtractor()
            val metadata = MediaMetadataRetriever()
            try {
                extractor.setDataSource(source.absolutePath)
                val types = (0 until extractor.trackCount).map { extractor.getTrackFormat(it).getString(MediaFormat.KEY_MIME) ?: "" }
                check(types.any { it.startsWith("video/") } && types.any { it == MediaFormat.MIMETYPE_AUDIO_AAC })
                metadata.setDataSource(source.absolutePath)
                val duration = metadata.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull() ?: 0L
                check(duration in 3000L..1_800_000L)
                return mapOf(
                    "appPrivateUri" to "app-private-media://screen-capture/$name", "fileName" to name,
                    "mimeType" to "video/mp4", "sizeBytes" to source.length(),
                    "durationSeconds" to (duration / 1000L).toInt(), "sha256" to sha256(source),
                    "recordedAt" to isoDate(System.currentTimeMillis()),
                )
            } finally {
                runCatching { extractor.release() }
                runCatching { metadata.release() }
            }
        }

        @Synchronized
        fun releaseMedia(context: Context, uri: String?) {
            if (uri == null) return
            val name = Regex("^app-private-media://screen-capture/([A-Za-z0-9][A-Za-z0-9._-]*\\.mp4)$")
                .matchEntire(uri)?.groupValues?.get(1) ?: error("Invalid capture file")
            val directory = File(context.filesDir, "HuahuoAI/ScreenCaptures")
            val stem = name.removeSuffix(".mp4")
            for (file in listOf(name, "$name.part", "$stem.m4a", "$stem.m4a.part")) {
                val target = File(directory, file)
                check(!target.exists() || target.delete())
            }
        }

        @Synchronized
        fun extractAudio(context: Context, appPrivateUri: String): Map<String, Any> {
            val fileName = Regex("^app-private-media://screen-capture/([A-Za-z0-9][A-Za-z0-9._-]*\\.mp4)$")
                .matchEntire(appPrivateUri)?.groupValues?.getOrNull(1)
                ?: throw ScreenCaptureAudioExtractionException("SCREEN_CAPTURE_AUDIO_REQUEST_INVALID")
            val directory = File(context.filesDir, "HuahuoAI/ScreenCaptures")
            val source = File(directory, fileName)
            if (!source.isFile || source.length() <= 0L) {
                throw ScreenCaptureAudioExtractionException("SCREEN_CAPTURE_AUDIO_SOURCE_MISSING")
            }
            val outputName = fileName.removeSuffix(".mp4") + ".m4a"
            val output = File(directory, outputName)
            cachedAudioPayload(output, source)?.let { return it }
            val part = File(directory, "$outputName.part")
            part.delete()
            val extractor = MediaExtractor()
            var muxer: MediaMuxer? = null
            try {
                extractor.setDataSource(source.absolutePath)
                val inputTrack = (0 until extractor.trackCount).firstOrNull { index ->
                    extractor.getTrackFormat(index).getString(MediaFormat.KEY_MIME) == MediaFormat.MIMETYPE_AUDIO_AAC
                } ?: throw ScreenCaptureAudioExtractionException("SCREEN_CAPTURE_AUDIO_UNAVAILABLE")
                val format = extractor.getTrackFormat(inputTrack)
                val declaredDuration = if (format.containsKey(MediaFormat.KEY_DURATION)) format.getLong(MediaFormat.KEY_DURATION) else 0L
                val sampleRate = if (format.containsKey(MediaFormat.KEY_SAMPLE_RATE)) format.getInteger(MediaFormat.KEY_SAMPLE_RATE) else 44_100
                val frameDurationUs = 1024L * 1_000_000L / sampleRate.coerceAtLeast(1)
                extractor.selectTrack(inputTrack)
                muxer = MediaMuxer(part.absolutePath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
                val outputTrack = muxer.addTrack(format)
                muxer.start()
                val buffer = ByteBuffer.allocate(1024 * 1024)
                val info = MediaCodec.BufferInfo()
                var writtenSamples = 0
                var firstTimeUs = -1L
                var lastTimeUs = 0L
                while (true) {
                    buffer.clear()
                    val size = extractor.readSampleData(buffer, 0)
                    if (size < 0) break
                    val timestamp = extractor.sampleTime.coerceAtLeast(0L)
                    if (firstTimeUs < 0) firstTimeUs = timestamp
                    val normalizedTime = (timestamp - firstTimeUs).coerceAtLeast(0L)
                    if (normalizedTime > 1801L * 1_000_000L || part.length() > 500L * 1024L * 1024L) {
                        throw ScreenCaptureAudioExtractionException("SCREEN_CAPTURE_AUDIO_LIMIT_EXCEEDED")
                    }
                    info.set(0, size, normalizedTime, if (extractor.sampleFlags and MediaExtractor.SAMPLE_FLAG_SYNC != 0) MediaCodec.BUFFER_FLAG_KEY_FRAME else 0)
                    buffer.position(0)
                    buffer.limit(size)
                    muxer.writeSampleData(outputTrack, buffer, info)
                    lastTimeUs = normalizedTime
                    writtenSamples++
                    if (!extractor.advance()) break
                }
                muxer.stop()
                muxer.release()
                muxer = null
                if (writtenSamples == 0 || !part.isFile || part.length() <= 0L) {
                    throw ScreenCaptureAudioExtractionException("SCREEN_CAPTURE_AUDIO_UNAVAILABLE")
                }
                val measuredDuration = lastTimeUs + frameDurationUs
                val durationUs = if (declaredDuration > 0) min(declaredDuration, measuredDuration) else measuredDuration
                if (durationUs < 3_000_000L) {
                    throw ScreenCaptureAudioExtractionException("SCREEN_CAPTURE_AUDIO_TOO_SHORT")
                }
                val checksum = sha256(part)
                atomicMove(part, output)
                return mapOf(
                    "appPrivateUri" to "app-private-media://screen-capture/$outputName",
                    "fileName" to outputName,
                    "mimeType" to "audio/mp4",
                    "sizeBytes" to output.length(),
                    "durationSeconds" to (durationUs / 1_000_000L).coerceIn(1L, 1800L).toInt(),
                    "sha256" to checksum,
                    "recordedAt" to isoDate(source.lastModified()),
                )
            } catch (error: ScreenCaptureAudioExtractionException) {
                throw error
            } catch (_: Exception) {
                throw ScreenCaptureAudioExtractionException("SCREEN_CAPTURE_AUDIO_EXPORT_FAILED")
            } finally {
                runCatching { muxer?.stop() }
                runCatching { muxer?.release() }
                extractor.release()
                part.delete()
            }
        }

        private fun cachedAudioPayload(output: File, source: File): Map<String, Any>? {
            if (!output.isFile || output.length() !in 1L..(500L * 1024L * 1024L)) return null
            val metadata = MediaMetadataRetriever()
            val extractor = MediaExtractor()
            return try {
                extractor.setDataSource(output.absolutePath)
                val audioTrack = (0 until extractor.trackCount).firstOrNull {
                    extractor.getTrackFormat(it).getString(MediaFormat.KEY_MIME) == MediaFormat.MIMETYPE_AUDIO_AAC
                } ?: return null
                extractor.selectTrack(audioTrack)
                if (extractor.sampleTime < 0) return null
                metadata.setDataSource(output.absolutePath)
                val durationMs = metadata.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull()
                    ?: return null
                if (durationMs !in 3000L..1_801_000L) return null
                mapOf(
                    "appPrivateUri" to "app-private-media://screen-capture/${output.name}",
                    "fileName" to output.name,
                    "mimeType" to "audio/mp4",
                    "sizeBytes" to output.length(),
                    "durationSeconds" to (durationMs / 1000L).coerceAtMost(1800L).toInt(),
                    "sha256" to sha256(output),
                    "recordedAt" to isoDate(source.lastModified()),
                )
            } catch (_: Exception) {
                null
            } finally {
                runCatching { metadata.release() }
                runCatching { extractor.release() }
            }
        }

        private fun atomicMove(source: File, destination: File) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
                check(source.renameTo(destination))
                return
            }
            try {
                Files.move(
                    source.toPath(),
                    destination.toPath(),
                    StandardCopyOption.ATOMIC_MOVE,
                    StandardCopyOption.REPLACE_EXISTING,
                )
            } catch (_: AtomicMoveNotSupportedException) {
                Files.move(
                    source.toPath(),
                    destination.toPath(),
                    StandardCopyOption.REPLACE_EXISTING,
                )
            }
        }

        private fun sha256(file: File): String {
            val digest = MessageDigest.getInstance("SHA-256")
            FileInputStream(file).use { input ->
                val buffer = ByteArray(64 * 1024)
                while (true) {
                    val count = input.read(buffer)
                    if (count <= 0) break
                    digest.update(buffer, 0, count)
                }
            }
            return digest.digest().joinToString("") { byte -> "%02x".format(byte) }
        }

        private val isoFormatter = SimpleDateFormat(
            "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'",
            Locale.US,
        ).apply { timeZone = TimeZone.getTimeZone("UTC") }

        private fun isoDate(millis: Long): String = synchronized(isoFormatter) {
            isoFormatter.format(Date(millis))
        }
    }
}

internal class ScreenCaptureAudioExtractionException(val code: String) : Exception(code)

private class ScreenCaptureRecorderException(val code: String) :
    IllegalStateException(code)

private class ProjectionMp4Recorder(
    private val context: Context,
    private val projection: MediaProjection,
    private val output: File,
    private val width: Int,
    private val height: Int,
) {
    private val stopRequested = AtomicBoolean(false)
    private var virtualDisplay: VirtualDisplay? = null
    private var inputSurface: Surface? = null
    private var videoFrameGate: ScreenCaptureVideoFrameGate? = null
    private var videoCodec: MediaCodec? = null
    private var audioCodec: MediaCodec? = null
    private var audioRecord: AudioRecord? = null
    private var audioThread: Thread? = null
    private var muxer: MediaMuxer? = null
    private var muxerStarted = false
    private var videoTrack = -1
    private var audioTrack = -1
    private var firstVideoPts = -1L
    private var firstAudioPts = -1L
    private var wroteVideo = false
    private var wroteAudio = false
    private val hasAudioSignal = AtomicBoolean(false)
    @Volatile private var audioFailureCode: String? = null
    private var audioInputEnded = false

    fun requestStop() {
        stopRequested.set(true)
        runCatching { audioRecord?.stop() }
    }

    fun recordUntilStopped(onReady: () -> Unit): Boolean {
        var completed = false
        try {
            setup()
            if (!stopRequested.get()) onReady()
            val videoInfo = MediaCodec.BufferInfo()
            val audioInfo = MediaCodec.BufferInfo()
            var videoEnded = false
            var audioEnded = audioCodec == null
            var videoEndSignalled = false
            var stopDeadline = Long.MAX_VALUE

            while (!(videoEnded && audioEnded)) {
                if (stopRequested.get() && !videoEndSignalled) {
                    virtualDisplay?.release()
                    virtualDisplay = null
                    videoFrameGate?.drawPendingFrame(force = true)
                    videoFrameGate?.close()
                    videoFrameGate = null
                    videoCodec?.signalEndOfInputStream()
                    videoEndSignalled = true
                    stopDeadline = System.currentTimeMillis() + DRAIN_TIMEOUT_MS
                }
                if (!videoEndSignalled) videoFrameGate?.drawPendingFrame()
                videoEnded = drainVideo(videoInfo) || videoEnded
                audioEnded = drainAudio(audioInfo) || audioEnded
                if (videoEndSignalled && System.currentTimeMillis() >= stopDeadline) break
            }
            audioFailureCode?.let { throw ScreenCaptureRecorderException(it) }
            if (!wroteAudio) throw ScreenCaptureRecorderException("SCREEN_CAPTURE_AUDIO_UNAVAILABLE")
            if (!hasAudioSignal.get()) throw ScreenCaptureRecorderException("SCREEN_CAPTURE_AUDIO_SILENT")
            completed = wroteVideo && output.length() > 0L
        } finally {
            release()
        }
        return completed
    }

    private fun setup() {
        muxer = MediaMuxer(output.absolutePath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)

        val encoding = startVideoEncoder()
        val frameGate = ScreenCaptureVideoFrameGate(
            encoderSurface = checkNotNull(inputSurface),
            width = encoding.width,
            height = encoding.height,
            maximumFrameRate = encoding.frameRate,
            readPowerState = ::screenCapturePowerState,
        )
        videoFrameGate = frameGate

        if (!setupAudioCapture()) {
            throw ScreenCaptureRecorderException(
                "SCREEN_CAPTURE_SYSTEM_AUDIO_UNAVAILABLE",
            )
        }
        val density = context.resources.displayMetrics.densityDpi
        virtualDisplay = projection.createVirtualDisplay(
            "HuahuoAI-ScreenCapture",
            encoding.width,
            encoding.height,
            density,
            DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
            frameGate.surface,
            null,
            null,
        )
    }

    private data class VideoEncoding(val codecName: String, val width: Int, val height: Int, val frameRate: Int, val bitRate: Int)

    private fun startVideoEncoder(): VideoEncoding {
        for (encoding in videoEncodings()) {
            if (stopRequested.get()) throw ScreenCaptureRecorderException("SCREEN_CAPTURE_SYSTEM_STOPPED")
            var candidate: MediaCodec? = null
            var surface: Surface? = null
            try {
                val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, encoding.width, encoding.height).apply {
                    setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
                    setInteger(MediaFormat.KEY_BIT_RATE, encoding.bitRate)
                    setInteger(MediaFormat.KEY_FRAME_RATE, encoding.frameRate)
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                        setFloat(MediaFormat.KEY_MAX_FPS_TO_ENCODER, encoding.frameRate.toFloat())
                    }
                    setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, VIDEO_I_FRAME_INTERVAL)
                }
                candidate = MediaCodec.createByCodecName(encoding.codecName)
                candidate.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
                surface = candidate.createInputSurface()
                candidate.start()
                videoCodec = candidate
                inputSurface = surface
                return encoding
            } catch (_: Exception) {
                runCatching { candidate?.stop() }
                runCatching { candidate?.release() }
                runCatching { surface?.release() }
            }
        }
        throw ScreenCaptureRecorderException("SCREEN_CAPTURE_CODEC_UNSUPPORTED")
    }

    private fun videoEncodings(): List<VideoEncoding> {
        val manager = context.getSystemService(WindowManager::class.java)
        val dimensions = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            manager.maximumWindowMetrics.bounds.let { it.width() to it.height() }
        } else {
            val metrics = DisplayMetrics()
            @Suppress("DEPRECATION")
            manager.defaultDisplay.getRealMetrics(metrics)
            metrics.widthPixels to metrics.heightPixels
        }
        val displayWidth = dimensions.first.coerceAtLeast(1)
        val displayHeight = dimensions.second.coerceAtLeast(1)
        val scale = min(min(width, height).toDouble() / min(displayWidth, displayHeight),
            1920.0 / max(displayWidth, displayHeight)).coerceAtMost(1.0)
        val encoders = MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos.filter {
            it.isEncoder && it.supportedTypes.any { type -> type.equals(MediaFormat.MIMETYPE_VIDEO_AVC, true) }
        }
        val frameRateBudget = videoFrameRateBudget()
        val frameRates = listOf(frameRateBudget, 10, 5).filter { it <= frameRateBudget }.distinct()
        val candidates = mutableListOf<VideoEncoding>()
        for (factor in listOf(1.0, 0.75, 0.5)) {
            for (encoder in encoders) {
                val capabilities = runCatching { encoder.getCapabilitiesForType(MediaFormat.MIMETYPE_VIDEO_AVC) }
                    .getOrNull() ?: continue
                if (!capabilities.colorFormats.contains(MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)) continue
                val video = capabilities.videoCapabilities ?: continue
                val targetWidth = ((displayWidth * scale * factor).toInt() / video.widthAlignment * video.widthAlignment).coerceAtLeast(video.widthAlignment)
                val targetHeight = ((displayHeight * scale * factor).toInt() / video.heightAlignment * video.heightAlignment).coerceAtLeast(video.heightAlignment)
                for (rate in frameRates) {
                    if (video.areSizeAndRateSupported(targetWidth, targetHeight, rate.toDouble())) {
                        candidates.add(VideoEncoding(encoder.name, targetWidth, targetHeight, rate,
                            video.bitrateRange.clamp(min(VIDEO_BIT_RATE, targetWidth * targetHeight * 4))))
                    }
                }
            }
        }
        return candidates.distinct()
    }

    private fun videoFrameRateBudget(): Int =
        ScreenCaptureFrameBudget.frameRateFor(screenCapturePowerState())

    private fun screenCapturePowerState(): ScreenCapturePowerState {
        val powerManager = context.getSystemService(PowerManager::class.java)
            ?: return ScreenCapturePowerState(ScreenCaptureThermalLevel.normal, lowPower = false)
        val thermalStatus = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            powerManager.currentThermalStatus
        } else {
            PowerManager.THERMAL_STATUS_NONE
        }
        val level = when {
            thermalStatus >= PowerManager.THERMAL_STATUS_CRITICAL -> ScreenCaptureThermalLevel.critical
            thermalStatus >= PowerManager.THERMAL_STATUS_SEVERE -> ScreenCaptureThermalLevel.severe
            thermalStatus >= PowerManager.THERMAL_STATUS_LIGHT -> ScreenCaptureThermalLevel.warm
            else -> ScreenCaptureThermalLevel.normal
        }
        return ScreenCapturePowerState(level, powerManager.isPowerSaveMode)
    }

    private fun setupAudioCapture(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return false
        val minBuffer = AudioRecord.getMinBufferSize(
            AUDIO_SAMPLE_RATE,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT,
        )
        if (minBuffer <= 0) return false
        val bufferSize = max(minBuffer * 2, AUDIO_BUFFER_BYTES)
        val playbackConfig = AudioPlaybackCaptureConfiguration.Builder(projection)
            .addMatchingUsage(AudioAttributes.USAGE_UNKNOWN)
            .addMatchingUsage(AudioAttributes.USAGE_MEDIA)
            .addMatchingUsage(AudioAttributes.USAGE_GAME)
            .build()
        val record = runCatching {
            AudioRecord.Builder()
                .setAudioFormat(
                    AudioFormat.Builder()
                        .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                        .setSampleRate(AUDIO_SAMPLE_RATE)
                        .setChannelMask(AudioFormat.CHANNEL_IN_MONO)
                        .build(),
                )
                .setBufferSizeInBytes(bufferSize)
                .setAudioPlaybackCaptureConfig(playbackConfig)
                .build()
        }.getOrNull()?.takeIf { it.state == AudioRecord.STATE_INITIALIZED }
            ?: return false

        val format = MediaFormat.createAudioFormat(
            MediaFormat.MIMETYPE_AUDIO_AAC,
            AUDIO_SAMPLE_RATE,
            AUDIO_CHANNEL_COUNT,
        ).apply {
            setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC)
            setInteger(MediaFormat.KEY_BIT_RATE, AUDIO_BIT_RATE)
            setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, bufferSize)
        }
        val codec = runCatching {
            MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_AUDIO_AAC).also {
                it.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
                it.start()
            }
        }.getOrElse {
            record.release()
            return false
        }
        val started = runCatching {
            record.startRecording()
            record.recordingState == AudioRecord.RECORDSTATE_RECORDING
        }.getOrDefault(false)
        if (!started) {
            codec.stop()
            codec.release()
            record.release()
            return false
        }

        audioRecord = record
        audioCodec = codec
        audioThread = Thread({ feedAudio(record, codec, bufferSize) }, "screen-capture-audio")
            .also { it.start() }
        return true
    }

    private fun feedAudio(record: AudioRecord, codec: MediaCodec, bufferSize: Int) {
        val pcm = ByteArray(bufferSize)
        var samplesWritten = 0L
        try {
            while (!stopRequested.get()) {
                val inputIndex = codec.dequeueInputBuffer(CODEC_TIMEOUT_US)
                if (inputIndex < 0) continue
                val input = checkNotNull(codec.getInputBuffer(inputIndex))
                input.clear()
                val count = record.read(pcm, 0, min(pcm.size, input.remaining()) and -2)
                if (count <= 0) {
                    codec.queueInputBuffer(inputIndex, 0, 0, 0L, 0)
                    if (count < 0 && !stopRequested.get()) {
                        audioFailureCode = "SCREEN_CAPTURE_AUDIO_READ_FAILED"
                        stopRequested.set(true)
                    }
                    continue
                }
                if (!hasAudioSignal.get()) {
                    for (offset in 0 until count - 1 step 2) {
                        val value = ((pcm[offset].toInt() and 0xff) or (pcm[offset + 1].toInt() shl 8)).toShort().toInt()
                        if (kotlin.math.abs(value) > 8) { hasAudioSignal.set(true); break }
                    }
                }
                input.put(pcm, 0, count)
                val pts = samplesWritten * 1_000_000L / AUDIO_SAMPLE_RATE
                codec.queueInputBuffer(inputIndex, 0, count, pts, 0)
                samplesWritten += count / (2L * AUDIO_CHANNEL_COUNT)
            }
            val deadline = System.currentTimeMillis() + DRAIN_TIMEOUT_MS
            while (!audioInputEnded && System.currentTimeMillis() < deadline) {
                val index = codec.dequeueInputBuffer(CODEC_TIMEOUT_US)
                if (index >= 0) {
                    val pts = samplesWritten * 1_000_000L / AUDIO_SAMPLE_RATE
                    codec.queueInputBuffer(index, 0, 0, pts, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                    audioInputEnded = true
                }
            }
        } catch (_: RuntimeException) {
            if (!stopRequested.get()) audioFailureCode = "SCREEN_CAPTURE_AUDIO_READ_FAILED"
            stopRequested.set(true)
        }
    }

    private fun drainVideo(info: MediaCodec.BufferInfo): Boolean {
        val codec = videoCodec ?: return true
        return when (val index = codec.dequeueOutputBuffer(info, CODEC_TIMEOUT_US)) {
            MediaCodec.INFO_TRY_AGAIN_LATER -> false
            MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                check(videoTrack < 0)
                videoTrack = checkNotNull(muxer).addTrack(codec.outputFormat)
                maybeStartMuxer()
                false
            }
            else -> {
                if (index < 0) return false
                val buffer = codec.getOutputBuffer(index)
                if (buffer != null && info.size > 0 &&
                    info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG == 0 && muxerStarted
                ) {
                    if (firstVideoPts < 0) firstVideoPts = info.presentationTimeUs
                    info.presentationTimeUs = max(0L, info.presentationTimeUs - firstVideoPts)
                    buffer.position(info.offset)
                    buffer.limit(info.offset + info.size)
                    checkNotNull(muxer).writeSampleData(videoTrack, buffer, info)
                    wroteVideo = true
                }
                val ended = info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0
                codec.releaseOutputBuffer(index, false)
                ended
            }
        }
    }

    private fun drainAudio(info: MediaCodec.BufferInfo): Boolean {
        val codec = audioCodec ?: return true
        return when (val index = codec.dequeueOutputBuffer(info, CODEC_TIMEOUT_US)) {
            MediaCodec.INFO_TRY_AGAIN_LATER -> false
            MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                check(audioTrack < 0)
                audioTrack = checkNotNull(muxer).addTrack(codec.outputFormat)
                maybeStartMuxer()
                false
            }
            else -> {
                if (index < 0) return false
                val buffer = codec.getOutputBuffer(index)
                if (buffer != null && info.size > 0 &&
                    info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG == 0 && muxerStarted
                ) {
                    if (firstAudioPts < 0) firstAudioPts = info.presentationTimeUs
                    info.presentationTimeUs = max(0L, info.presentationTimeUs - firstAudioPts)
                    buffer.position(info.offset)
                    buffer.limit(info.offset + info.size)
                    checkNotNull(muxer).writeSampleData(audioTrack, buffer, info)
                    wroteAudio = true
                }
                val ended = info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0
                codec.releaseOutputBuffer(index, false)
                ended
            }
        }
    }

    private fun maybeStartMuxer() {
        if (muxerStarted || videoTrack < 0) return
        if (audioCodec != null && audioTrack < 0) return
        checkNotNull(muxer).start()
        muxerStarted = true
    }

    private fun release() {
        stopRequested.set(true)
        runCatching { audioRecord?.stop() }
        runCatching { audioThread?.join(1_000L) }
        runCatching { virtualDisplay?.release() }
        virtualDisplay = null
        runCatching { videoFrameGate?.close() }
        videoFrameGate = null
        runCatching { inputSurface?.release() }
        inputSurface = null
        runCatching { videoCodec?.stop() }
        runCatching { videoCodec?.release() }
        videoCodec = null
        runCatching { audioCodec?.stop() }
        runCatching { audioCodec?.release() }
        audioCodec = null
        runCatching { audioRecord?.release() }
        audioRecord = null
        val muxerFailure = if (muxerStarted) runCatching { muxer?.stop() }.exceptionOrNull() else null
        runCatching { muxer?.release() }
        muxer = null
        if (muxerFailure != null) throw ScreenCaptureRecorderException("SCREEN_CAPTURE_FINALIZE_FAILED")
    }

    companion object {
        private const val VIDEO_BIT_RATE = 2_000_000
        private const val VIDEO_FRAME_RATE = 15
        private const val VIDEO_I_FRAME_INTERVAL = 2
        private const val AUDIO_SAMPLE_RATE = 44_100
        private const val AUDIO_CHANNEL_COUNT = 1
        private const val AUDIO_BIT_RATE = 128_000
        private const val AUDIO_BUFFER_BYTES = 16 * 1024
        private const val CODEC_TIMEOUT_US = 10_000L
        private const val DRAIN_TIMEOUT_MS = 5_000L
    }
}
