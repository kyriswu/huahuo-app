package com.hangzhouchuda.huahuoai

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.io.RandomAccessFile
import java.lang.reflect.InvocationHandler
import java.lang.reflect.Proxy
import java.security.MessageDigest
import java.text.SimpleDateFormat
import java.util.ArrayDeque
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import java.util.UUID
import kotlin.math.ceil

private const val VOICE_RECORDER_LOG_TAG = "HuahuoVoiceRecorder"

private data class VoiceRecorderLevelSnapshot(
    val capturedAtMs: Long,
    val average: Double,
    val peak: Double,
)

/**
 * Owns Android's microphone permission and private MediaRecorder lifecycle.
 * Dart only receives opaque app-private references, never a native file path.
 */
internal class VoiceRecorderAndroidBridge private constructor(
    private val activity: FlutterActivity,
    messenger: BinaryMessenger,
) : EventChannel.StreamHandler {
    private val context: Context = activity.applicationContext
    private val mainHandler = Handler(Looper.getMainLooper())
    private val levelThread = HandlerThread("huahuo-voice-level-metering").apply { start() }
    private val levelHandler = Handler(levelThread.looper)
    private val levelScheduleLock = Any()
    private val recorderMeteringLock = Any()
    private val channel = MethodChannel(messenger, METHOD_CHANNEL)
    private val levelChannel = EventChannel(messenger, LEVEL_CHANNEL)
    private val pcmChannel = EventChannel(messenger, PCM_CHANNEL)
    private val preferences = context.getSharedPreferences(PREFERENCES_NAME, Context.MODE_PRIVATE)

    private var recorder: MediaRecorder? = null
    private var pcmRecorder: AudioRecord? = null
    @Volatile private var pcmCaptureThread: Thread? = null
    @Volatile private var pcmCaptureCleanupRunning = false
    @Volatile private var pcmCaptureRunning = false
    @Volatile private var pcmCapturePaused = false
    @Volatile private var pcmCaptureFailed = false
    @Volatile private var pcmAverage = 0.0
    @Volatile private var pcmPeak = 0.0
    @Volatile private var pcmCapturedBytes = 0L
    private var recordingId: String? = null
    private var recordingScene: String? = null
    private var recordingStartedAtMs: Long? = null
    private var pausedAtMs: Long? = null
    private var pausedDurationMs = 0L
    private var state = STATE_IDLE
    @Volatile private var recordingFailureCode: String? = null
    private var partFile: File? = null
    private var recordingAccountDirectory: String? = null
    private var permissionResult: MethodChannel.Result? = null
    private var permissionTimeout: Runnable? = null
    private var levelEventSink: EventChannel.EventSink? = null
    private var levelGeneration = 0L
    private val pcmFrameLock = Any()
    private var pcmEventSink: EventChannel.EventSink? = null
    private val earlyPcmFrames = PcmEarlyFrameQueue(MAX_BUFFERED_PCM_FRAMES)
    private val pcmDrainPacer = PcmFrameDrainPacer()
    private var pcmOverflowErrorScheduled = false
    private var pcmOverflowErrorDeliveredToSink = false
    private val pcmFrameBuffer = ByteArray(PCM_FRAME_BYTES)
    private var pcmFrameBufferCount = 0
    private val sharedTencentPcmSource = SharedTencentPcmSource()

    init {
        channel.setMethodCallHandler(::handleMethodCall)
        levelChannel.setStreamHandler(this)
        pcmChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                attachPcmEventSink(events)
            }

            override fun onCancel(arguments: Any?) {
                detachPcmEventSink()
            }
        })
    }

    companion object {
        private const val METHOD_CHANNEL = "huahuoai/voice_recorder"
        private const val LEVEL_CHANNEL = "huahuoai/voice_recorder_levels"
        private const val PCM_CHANNEL = "huahuoai/voice_recorder_pcm16"
        private const val PREFERENCES_NAME = "voice_recorder"
        private const val MICROPHONE_PROMPTED = "microphone_prompted"
        private const val PERMISSION_REQUEST_CODE = 0x564F
        private const val PERMISSION_TIMEOUT_MS = 30_000L
        private const val LEVEL_INTERVAL_MS = 50L
        private const val PCM_FRAME_BYTES = 1_280
        private const val MAX_BUFFERED_PCM_FRAMES = 1_125
        private const val PCM_CAPTURE_JOIN_TIMEOUT_MS = 2_000L
        private const val PCM_CAPTURE_RELEASE_GRACE_MS = 500L
        private const val STATE_IDLE = "idle"
        private const val STATE_RECORDING = "recording"
        private const val STATE_PAUSED = "paused"
        private const val STATE_FAILED = "failed"
        private const val VOICEPRINT_SCENE = "voiceprint"
        private const val VOICEPRINT_SAMPLE_RATE = 16_000
        private const val VOICEPRINT_CHANNEL_COUNT = 1
        private const val VOICEPRINT_BIT_DEPTH = 16
        private const val VOICEPRINT_BYTES_PER_SAMPLE = 2
        private const val VOICEPRINT_BYTES_PER_SECOND =
            VOICEPRINT_SAMPLE_RATE * VOICEPRINT_CHANNEL_COUNT * VOICEPRINT_BYTES_PER_SAMPLE
        private const val VOICEPRINT_MIN_DURATION_SECONDS = 10
        private const val VOICEPRINT_MAX_DURATION_SECONDS = 10
        private const val VOICEPRINT_MAX_ACCEPTED_DURATION_MILLISECONDS = 10_500L
        private const val VOICEPRINT_MAX_FILE_BYTES = 2 * 1024 * 1024
        private const val WAV_HEADER_BYTES = 44
        private const val MAX_SHARED_PCM_DATA_BYTES = Int.MAX_VALUE - WAV_HEADER_BYTES
        private val SHA_256_PATTERN = Regex("^[a-f0-9]{64}$")
        private val ACCOUNT_DIRECTORY_PATTERN = Regex("^u-[a-f0-9]{32}$")

        private var activeBridge: VoiceRecorderAndroidBridge? = null

        fun register(activity: FlutterActivity, messenger: BinaryMessenger) {
            activeBridge?.dispose()
            activeBridge = VoiceRecorderAndroidBridge(activity, messenger)
        }

        fun unregister() {
            activeBridge?.dispose()
            activeBridge = null
        }

        /** MainActivity must forward its permission callback to this method. */
        fun onRequestPermissionsResult(
            requestCode: Int,
            permissions: Array<out String>,
            grantResults: IntArray,
        ): Boolean {
            return activeBridge?.handleRequestPermissionsResult(
                requestCode,
                permissions,
                grantResults,
            ) ?: false
        }

        fun createTencentPcmDataSource(): Any? =
            activeBridge?.createTencentPcmDataSource()

        fun detachTencentPcmDataSource() {
            activeBridge?.detachTencentPcmDataSource()
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        levelEventSink = events
        if (state == STATE_RECORDING) {
            startLevelMetering()
        } else {
            emitLevel(average = 0.0, peak = 0.0)
        }
    }

    override fun onCancel(arguments: Any?) {
        stopLevelMetering(emitBaseline = false)
        levelEventSink = null
    }

    private fun handleMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "getMicrophonePermission" -> result.success(microphonePermissionMap())
            "requestMicrophonePermission" -> requestMicrophonePermission(result)
            "getRecordingState" -> result.success(recordingStateMap())
            "startRecording" -> startRecording(call.arguments as? Map<*, *>, result)
            "pauseRecording" -> pauseRecording(call.arguments as? Map<*, *>, result)
            "resumeRecording" -> resumeRecording(call.arguments as? Map<*, *>, result)
            "stopRecording" -> stopRecording(call.arguments as? Map<*, *>, result)
            "cancelRecording" -> cancelRecording(call.arguments as? Map<*, *>, result)
            else -> result.notImplemented()
        }
    }

    private fun requestMicrophonePermission(result: MethodChannel.Result) {
        val existing = microphonePermissionMap()
        if (existing["state"] == "granted") {
            result.success(existing)
            return
        }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
            result.success(permissionMap("granted", canAskAgain = false))
            return
        }
        if (permissionResult != null) {
            result.error(
                "VOICE_RECORDER_PERMISSION_REQUEST_IN_PROGRESS",
                "A microphone permission request is already active.",
                null,
            )
            return
        }
        permissionResult = result
        preferences.edit().putBoolean(MICROPHONE_PROMPTED, true).apply()
        permissionTimeout = Runnable {
            val pending = permissionResult ?: return@Runnable
            permissionResult = null
            permissionTimeout = null
            pending.error(
                "VOICE_RECORDER_PERMISSION_REQUEST_TIMEOUT",
                "Microphone permission did not return in time.",
                null,
            )
        }.also { mainHandler.postDelayed(it, PERMISSION_TIMEOUT_MS) }
        try {
            activity.requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), PERMISSION_REQUEST_CODE)
        } catch (_: RuntimeException) {
            completePermissionFailure("VOICE_RECORDER_PERMISSION_REQUEST_FAILED")
        }
    }

    private fun handleRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ): Boolean {
        if (requestCode != PERMISSION_REQUEST_CODE) return false
        val pending = permissionResult ?: return false
        clearPermissionRequest()
        val granted = permissions.indices.all { index ->
            permissions[index] != Manifest.permission.RECORD_AUDIO ||
                grantResults.getOrNull(index) == PackageManager.PERMISSION_GRANTED
        }
        val state = if (granted) {
            "granted"
        } else if (activity.shouldShowRequestPermissionRationale(Manifest.permission.RECORD_AUDIO)) {
            "denied"
        } else {
            "blocked"
        }
        pending.success(permissionMap(state, canAskAgain = state == "denied"))
        return true
    }

    private fun startRecording(arguments: Map<*, *>?, result: MethodChannel.Result) {
        if (recorder != null || pcmRecorder != null || pcmCaptureThread != null || pcmCaptureCleanupRunning) {
            result.error("VOICE_RECORDER_BUSY", "A voice recording is already active.", null)
            return
        }
        val scene = arguments?.get("scene") as? String
        if (scene != "work_ai" && scene != "feed_ai" && scene != "monologue" && scene != "internal" && scene != "meeting" && scene != "voiceprint") {
            result.error("VOICE_RECORDER_SCENE_INVALID", "Voice recording scene is invalid.", null)
            return
        }
        val accountDirectory = validAccountDirectory(arguments?.get("accountDirectory"))
        if (arguments?.containsKey("accountDirectory") == true && accountDirectory == null) {
            result.error(
                "VOICE_RECORDER_ACCOUNT_DIRECTORY_INVALID",
                "Private voice storage scope is invalid.",
                null,
            )
            return
        }
        when (microphonePermissionState()) {
            "granted" -> Unit
            "blocked" -> {
                result.error(
                    "VOICE_RECORDER_PERMISSION_BLOCKED",
                    "Microphone permission is blocked.",
                    null,
                )
                return
            }
            else -> {
                result.error(
                    "VOICE_RECORDER_PERMISSION_DENIED",
                    "Microphone permission has not been granted.",
                    null,
                )
                return
            }
        }

        val id = "voice-${UUID.randomUUID().toString().lowercase(Locale.US)}"
        val pendingFile = try {
            File(recordingDirectory(accountDirectory), partFileName(id, scene))
        } catch (_: Exception) {
            result.error(
                "VOICE_RECORDER_STORAGE_UNAVAILABLE",
                "Private voice storage is unavailable.",
                null,
            )
            return
        }
        pendingFile.delete()
        recordingAccountDirectory = accountDirectory
        try {
            if (usesPcmWav(scene)) {
                startPcmRecording(id, scene, pendingFile, result)
                return
            }
            val activeRecorder = createRecorder()
            activeRecorder.setOutputFile(pendingFile.absolutePath)
            activeRecorder.prepare()
            activeRecorder.start()
            recorder = activeRecorder
            recordingId = id
            recordingScene = scene
            recordingStartedAtMs = System.currentTimeMillis()
            pausedAtMs = null
            pausedDurationMs = 0L
            recordingFailureCode = null
            partFile = pendingFile
            state = STATE_RECORDING
            if (!VoiceRecordingForegroundService.start(context)) {
                releaseRecorder()
                clearRecordingState(deletePart = true)
                result.error(
                    "VOICE_RECORDER_FOREGROUND_SERVICE_FAILED",
                    "Microphone recording could not enter foreground mode.",
                    null,
                )
                return
            }
            startLevelMetering()
            result.success(recordingStateMap())
        } catch (_: Exception) {
            val captureStopped = stopAndReleasePcmRecorder()
            releaseRecorder()
            if (captureStopped) pendingFile.delete()
            clearRecordingState(deletePart = false)
            if (captureStopped) {
                result.error("VOICE_RECORDER_START_FAILED", "Voice recording did not start.", null)
            } else {
                result.error(
                    "VOICE_RECORDER_STOP_TIMEOUT",
                    "Voice capture did not stop before the safety deadline.",
                    null,
                )
            }
        }
    }

    private fun pauseRecording(arguments: Map<*, *>?, result: MethodChannel.Result) {
        if (!validateExpectedSession(arguments, result)) return
        if (recordingScene == VOICEPRINT_SCENE && pcmRecorder != null) {
            result.error(
                "VOICE_RECORDER_PAUSE_UNSUPPORTED",
                "Voiceprint capture cannot be paused.",
                null,
            )
            return
        }
        if (isSharedPcmScene(recordingScene) &&
            pcmRecorder != null &&
            state == STATE_RECORDING
        ) {
            val activeRecorder = pcmRecorder ?: return
            pcmCapturePaused = true
            val paused = runCatching {
                activeRecorder.stop()
                true
            }.getOrDefault(false)
            if (!paused) {
                pcmCapturePaused = false
                result.error("VOICE_RECORDER_PAUSE_FAILED", "Voice recording could not pause.", null)
                return
            }
            pausedAtMs = System.currentTimeMillis()
            state = STATE_PAUSED
            stopLevelMetering(emitBaseline = true)
            result.success(recordingStateMap())
            return
        }
        val activeRecorder = recorder
        if (activeRecorder == null || state != STATE_RECORDING) {
            result.error("VOICE_RECORDER_NOT_RECORDING", "No recording is active.", null)
            return
        }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N) {
            result.error(
                "VOICE_RECORDER_PAUSE_UNSUPPORTED",
                "Pause is unavailable on this Android version.",
                null,
            )
            return
        }
        try {
            synchronized(recorderMeteringLock) { activeRecorder.pause() }
            pausedAtMs = System.currentTimeMillis()
            state = STATE_PAUSED
            stopLevelMetering(emitBaseline = true)
            result.success(recordingStateMap())
        } catch (_: RuntimeException) {
            result.error("VOICE_RECORDER_PAUSE_FAILED", "Voice recording could not pause.", null)
        }
    }

    private fun resumeRecording(arguments: Map<*, *>?, result: MethodChannel.Result) {
        if (!validateExpectedSession(arguments, result)) return
        if (recordingScene == VOICEPRINT_SCENE && pcmRecorder != null) {
            result.error(
                "VOICE_RECORDER_PAUSE_UNSUPPORTED",
                "Voiceprint capture cannot be resumed.",
                null,
            )
            return
        }
        if (isSharedPcmScene(recordingScene) &&
            pcmRecorder != null &&
            state == STATE_PAUSED
        ) {
            val activeRecorder = pcmRecorder ?: return
            val resumed = runCatching {
                activeRecorder.startRecording()
                activeRecorder.recordingState == AudioRecord.RECORDSTATE_RECORDING
            }.getOrDefault(false)
            if (!resumed) {
                result.error("VOICE_RECORDER_RESUME_FAILED", "Voice recording could not resume.", null)
                return
            }
            pcmCapturePaused = false
            pausedAtMs?.let { pausedDurationMs += System.currentTimeMillis() - it }
            pausedAtMs = null
            state = STATE_RECORDING
            startLevelMetering()
            result.success(recordingStateMap())
            return
        }
        val activeRecorder = recorder
        if (activeRecorder == null || state != STATE_PAUSED) {
            result.error("VOICE_RECORDER_NOT_PAUSED", "Voice recording is not paused.", null)
            return
        }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N) {
            result.error(
                "VOICE_RECORDER_PAUSE_UNSUPPORTED",
                "Resume is unavailable on this Android version.",
                null,
            )
            return
        }
        try {
            synchronized(recorderMeteringLock) { activeRecorder.resume() }
            pausedAtMs?.let { pausedDurationMs += System.currentTimeMillis() - it }
            pausedAtMs = null
            state = STATE_RECORDING
            startLevelMetering()
            result.success(recordingStateMap())
        } catch (_: RuntimeException) {
            result.error("VOICE_RECORDER_RESUME_FAILED", "Voice recording could not resume.", null)
        }
    }

    private fun stopRecording(arguments: Map<*, *>?, result: MethodChannel.Result) {
        if (!validateExpectedSession(arguments, result)) return
        if (usesPcmWav(recordingScene)) {
            stopPcmRecording(result)
            return
        }
        val activeRecorder = recorder
        val id = recordingId
        val sourceFile = partFile
        if (activeRecorder == null || id == null || sourceFile == null) {
            result.error("VOICE_RECORDER_NOT_ACTIVE", "No active voice recording exists.", null)
            return
        }
        val durationSeconds = currentElapsedSeconds().coerceAtLeast(1)
        val recordedAt = recordingStartedAtMs?.let(::isoTime)
        val scene = recordingScene
        if (scene == null) {
            result.error("VOICE_RECORDER_NOT_ACTIVE", "No active voice recording exists.", null)
            return
        }
        stopLevelMetering(emitBaseline = true)
        val stopSucceeded = try {
            synchronized(recorderMeteringLock) { activeRecorder.stop() }
            true
        } catch (_: RuntimeException) {
            false
        }
        releaseRecorder()
        if (!stopSucceeded) {
            sourceFile.delete()
            clearRecordingState(deletePart = false)
            result.error("VOICE_RECORDER_EMPTY_FILE", "Voice recording did not contain audio.", null)
            return
        }
        if (!sourceFile.isFile || sourceFile.length() <= 0L) {
            sourceFile.delete()
            clearRecordingState(deletePart = false)
            result.error("VOICE_RECORDER_EMPTY_FILE", "Voice recording file is empty.", null)
            return
        }
        val finalFile = File(sourceFile.parentFile, finalFileName(id, scene))
        try {
            if (finalFile.exists()) finalFile.delete()
            if (!sourceFile.renameTo(finalFile)) {
                throw IOException("draft promotion failed")
            }
            val sha256 = sha256Hex(finalFile)
            if (!SHA_256_PATTERN.matches(sha256)) {
                throw IOException("recording checksum is invalid")
            }
            val payload = mapOf(
                "recordingId" to id,
                "scene" to scene,
                "appPrivateUri" to appPrivateUri(id, scene),
                "fileName" to finalFileName(id, scene),
                "mimeType" to "audio/mp4",
                "sizeBytes" to finalFile.length(),
                "durationSeconds" to durationSeconds,
                "sha256" to sha256,
                "recordedAt" to recordedAt,
            )
            clearRecordingState(deletePart = false)
            result.success(payload)
        } catch (_: Exception) {
            sourceFile.delete()
            finalFile.delete()
            clearRecordingState(deletePart = false)
            result.error(
                "VOICE_RECORDER_FILE_UNAVAILABLE",
                "Voice recording file is unavailable.",
                null,
            )
        }
    }

    private fun cancelRecording(arguments: Map<*, *>?, result: MethodChannel.Result) {
        if (!validateExpectedSession(arguments, result)) return
        stopLevelMetering(emitBaseline = true)
        val captureStopped = stopAndReleasePcmRecorder()
        releaseRecorder()
        clearRecordingState(deletePart = captureStopped)
        if (captureStopped) {
            result.success(recordingStateMap())
        } else {
            result.error(
                "VOICE_RECORDER_STOP_TIMEOUT",
                "Voice capture did not stop before the safety deadline.",
                null,
            )
        }
    }

    private fun validateExpectedSession(
        arguments: Map<*, *>?,
        result: MethodChannel.Result,
    ): Boolean {
        val hasExpectedScene = arguments?.containsKey("expectedScene") == true
        val hasExpectedRecordingId = arguments?.containsKey("expectedRecordingId") == true
        if (!hasExpectedScene && !hasExpectedRecordingId) return true

        val expectedScene = arguments["expectedScene"] as? String
        val expectedRecordingId = arguments["expectedRecordingId"] as? String
        if (!hasExpectedScene ||
            !hasExpectedRecordingId ||
            expectedScene != recordingScene ||
            expectedRecordingId != recordingId
        ) {
            result.error(
                "VOICE_RECORDER_SESSION_MISMATCH",
                "The active voice recording does not match the expected session.",
                null,
            )
            return false
        }
        return true
    }

    private fun microphonePermissionMap(): Map<String, Any> {
        val state = microphonePermissionState()
        return permissionMap(state, canAskAgain = state == "not_determined" || state == "denied")
    }

    private fun microphonePermissionState(): String {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M ||
            activity.checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED
        ) {
            return "granted"
        }
        val prompted = preferences.getBoolean(MICROPHONE_PROMPTED, false)
        if (!prompted) return "not_determined"
        return if (activity.shouldShowRequestPermissionRationale(Manifest.permission.RECORD_AUDIO)) {
            "denied"
        } else {
            "blocked"
        }
    }

    private fun permissionMap(state: String, canAskAgain: Boolean): Map<String, Any> = mapOf(
        "state" to state,
        "canAskAgain" to canAskAgain,
    )

    private fun recordingStateMap(): Map<String, Any> {
        val reportedState = if (state == STATE_RECORDING && pcmCaptureFailed) {
            STATE_FAILED
        } else {
            state
        }
        val result = linkedMapOf<String, Any>("state" to reportedState)
        if (reportedState == STATE_FAILED) {
            result["lastErrorCode"] =
                recordingFailureCode ?: "VOICE_RECORDER_PCM_CAPTURE_FAILED"
        }
        val id = recordingId
        val scene = recordingScene
        val startedAt = recordingStartedAtMs
        if (id != null &&
            scene != null &&
            startedAt != null &&
            reportedState != STATE_IDLE &&
            reportedState != STATE_FAILED
        ) {
            result["recordingId"] = id
            result["scene"] = scene
            result["startedAt"] = isoTime(startedAt)
            result["elapsedSeconds"] = currentElapsedSeconds()
        }
        return result
    }

    private fun currentElapsedSeconds(nowMs: Long = System.currentTimeMillis()): Int {
        val startedAt = recordingStartedAtMs ?: return 0
        val currentPause = pausedAtMs?.let { nowMs - it } ?: 0L
        val activeMs = (nowMs - startedAt - pausedDurationMs - currentPause).coerceAtLeast(0L)
        val elapsed = ceil(activeMs / 1000.0).toInt().coerceAtLeast(0)
        if (recordingScene != VOICEPRINT_SCENE) return elapsed

        // The gateway validates raw PCM bytes, not a wall-clock estimate.
        return (pcmCapturedBytes / VOICEPRINT_BYTES_PER_SECOND)
            .toInt()
            .coerceAtMost(VOICEPRINT_MAX_DURATION_SECONDS)
    }

    private fun startLevelMetering() {
        stopLevelMetering(emitBaseline = false)
        if (levelEventSink == null ||
            state != STATE_RECORDING ||
            (recorder == null && pcmRecorder == null)
        ) return
        val pcmSource = usesPcmWav(recordingScene)
        val activeRecorder = recorder
        val generation = synchronized(levelScheduleLock) {
            levelGeneration += 1
            levelGeneration
        }
        val runnable = object : Runnable {
            private var smoothedAverage = 0.0

            override fun run() {
                check(Looper.myLooper() == levelThread.looper) {
                    "Voice recorder metering must run on its worker thread."
                }
                if (!isLevelGenerationCurrent(generation)) return
                val peak = if (pcmSource) {
                    pcmPeak
                } else {
                    val amplitude = synchronized(recorderMeteringLock) {
                        if (!isLevelGenerationCurrent(generation)) return
                        runCatching { activeRecorder?.maxAmplitude ?: 0 }.getOrDefault(0)
                    }
                    (amplitude.toDouble() / 32_767.0).coerceIn(0.0, 1.0)
                }
                smoothedAverage = (smoothedAverage * 0.68 + peak * 0.32).coerceIn(0.0, 1.0)
                postLevelSnapshot(
                    generation = generation,
                    snapshot = VoiceRecorderLevelSnapshot(
                        capturedAtMs = System.currentTimeMillis(),
                        average = smoothedAverage,
                        peak = peak.coerceAtLeast(smoothedAverage),
                    ),
                    requiresRecording = true,
                )
                synchronized(levelScheduleLock) {
                    if (levelGeneration == generation) {
                        levelHandler.postDelayed(this, LEVEL_INTERVAL_MS)
                    }
                }
            }
        }
        synchronized(levelScheduleLock) {
            if (levelGeneration == generation) levelHandler.post(runnable)
        }
    }

    private fun stopLevelMetering(emitBaseline: Boolean) {
        val generation = synchronized(levelScheduleLock) {
            levelGeneration += 1
            levelHandler.removeCallbacksAndMessages(null)
            levelGeneration
        }
        // Wait for an in-flight maxAmplitude call before recorder lifecycle work continues.
        synchronized(recorderMeteringLock) {}
        if (emitBaseline) {
            postLevelSnapshot(
                generation = generation,
                snapshot = VoiceRecorderLevelSnapshot(
                    capturedAtMs = System.currentTimeMillis(),
                    average = 0.0,
                    peak = 0.0,
                ),
                requiresRecording = false,
            )
        }
    }

    private fun emitLevel(average: Double, peak: Double) {
        emitLevel(
            VoiceRecorderLevelSnapshot(
                capturedAtMs = System.currentTimeMillis(),
                average = average,
                peak = peak,
            ),
        )
    }

    private fun postLevelSnapshot(
        generation: Long,
        snapshot: VoiceRecorderLevelSnapshot,
        requiresRecording: Boolean,
    ) {
        val publish = Runnable {
            if (!isLevelGenerationCurrent(generation) ||
                levelEventSink == null ||
                (requiresRecording && state != STATE_RECORDING)
            ) return@Runnable
            emitLevel(snapshot)
        }
        if (Looper.myLooper() == Looper.getMainLooper()) {
            publish.run()
        } else {
            mainHandler.post(publish)
        }
    }

    private fun isLevelGenerationCurrent(generation: Long): Boolean =
        synchronized(levelScheduleLock) { levelGeneration == generation }

    private fun emitLevel(snapshot: VoiceRecorderLevelSnapshot) {
        check(Looper.myLooper() == Looper.getMainLooper()) {
            "Voice recorder level events must be published on the main looper."
        }
        levelEventSink?.success(
            mapOf(
                "capturedAt" to isoTime(snapshot.capturedAtMs),
                "average" to snapshot.average.coerceIn(0.0, 1.0),
                "peak" to snapshot.peak.coerceAtLeast(snapshot.average).coerceIn(0.0, 1.0),
            ),
        )
    }

    private fun attachPcmEventSink(sink: EventChannel.EventSink) {
        var drainToken: Long? = null
        var shouldScheduleOverflow = false
        synchronized(pcmFrameLock) {
            pcmEventSink = sink
            pcmOverflowErrorDeliveredToSink = false
            if (earlyPcmFrames.overflowed && !pcmOverflowErrorScheduled) {
                pcmOverflowErrorScheduled = true
                shouldScheduleOverflow = true
            } else {
                drainToken = pcmDrainPacer.request(
                    hasListener = true,
                    hasFrames = !earlyPcmFrames.isEmpty,
                    overflowed = earlyPcmFrames.overflowed,
                )
            }
        }
        if (shouldScheduleOverflow) mainHandler.post { emitPcmOverflowError() }
        drainToken?.let(::schedulePcmDrain)
    }

    private fun detachPcmEventSink() {
        synchronized(pcmFrameLock) {
            pcmEventSink = null
            pcmDrainPacer.cancel()
            pcmOverflowErrorScheduled = false
            pcmOverflowErrorDeliveredToSink = false
        }
    }

    private fun publishPcmBytes(bytes: ByteArray, count: Int) {
        sharedTencentPcmSource.append(bytes, count)
        var sourceOffset = 0
        while (sourceOffset < count) {
            val copyCount = minOf(
                PCM_FRAME_BYTES - pcmFrameBufferCount,
                count - sourceOffset,
            )
            bytes.copyInto(
                pcmFrameBuffer,
                destinationOffset = pcmFrameBufferCount,
                startIndex = sourceOffset,
                endIndex = sourceOffset + copyCount,
            )
            sourceOffset += copyCount
            pcmFrameBufferCount += copyCount
            if (pcmFrameBufferCount == PCM_FRAME_BYTES) {
                enqueuePcmFrame(pcmFrameBuffer.copyOf())
                pcmFrameBufferCount = 0
            }
        }
    }

    private fun enqueuePcmFrame(frame: ByteArray) {
        if (frame.size != PCM_FRAME_BYTES) {
            pcmCaptureFailed = true
            return
        }
        var drainToken: Long? = null
        var shouldScheduleOverflow = false
        synchronized(pcmFrameLock) {
            val accepted = earlyPcmFrames.append(frame)
            if (!accepted && earlyPcmFrames.overflowed) {
                pcmDrainPacer.cancel()
            }
            if (!accepted &&
                earlyPcmFrames.overflowed &&
                pcmEventSink != null &&
                !pcmOverflowErrorScheduled &&
                !pcmOverflowErrorDeliveredToSink
            ) {
                pcmOverflowErrorScheduled = true
                shouldScheduleOverflow = true
            } else {
                drainToken = pcmDrainPacer.request(
                    hasListener = accepted && pcmEventSink != null,
                    hasFrames = !earlyPcmFrames.isEmpty,
                    overflowed = earlyPcmFrames.overflowed,
                )
            }
        }
        if (shouldScheduleOverflow) mainHandler.post { emitPcmOverflowError() }
        drainToken?.let(::schedulePcmDrain)
    }

    private fun emitPcmOverflowError() {
        val delivery = synchronized(pcmFrameLock) {
            val sink = pcmEventSink
            if (sink == null || !earlyPcmFrames.overflowed) {
                pcmOverflowErrorScheduled = false
                null
            } else {
                pcmOverflowErrorScheduled = false
                pcmOverflowErrorDeliveredToSink = true
                Triple(
                    sink,
                    earlyPcmFrames.droppedFrameCount,
                    earlyPcmFrames.capacityFrames,
                )
            }
        } ?: return
        delivery.first.error(
            "LIVE_ASR_PCM_EARLY_BUFFER_OVERFLOW",
            "Realtime audio could not start before the early buffer filled.",
            mapOf(
                "droppedFrames" to delivery.second,
                "capacityFrames" to delivery.third,
            ),
        )
    }

    private fun schedulePcmDrain(token: Long) {
        mainHandler.postDelayed(
            { deliverNextPcmFrame(token) },
            PcmFrameDrainPacer.INTERVAL_MILLIS,
        )
    }

    private fun deliverNextPcmFrame(token: Long) {
        val delivery = synchronized(pcmFrameLock) {
            val sink = pcmEventSink
            if (!pcmDrainPacer.beginDelivery(token) ||
                sink == null ||
                earlyPcmFrames.overflowed
            ) {
                null
            } else {
                earlyPcmFrames.removeFirstOrNull()?.let { sink to it }
            }
        } ?: return
        delivery.first.success(delivery.second)

        val nextToken = synchronized(pcmFrameLock) {
            pcmDrainPacer.request(
                hasListener = pcmEventSink != null,
                hasFrames = !earlyPcmFrames.isEmpty,
                overflowed = earlyPcmFrames.overflowed,
            )
        }
        nextToken?.let(::schedulePcmDrain)
    }

    private fun resetPcmFrameBuffer() {
        synchronized(pcmFrameLock) {
            earlyPcmFrames.reset()
            pcmDrainPacer.cancel()
            pcmOverflowErrorScheduled = false
            pcmOverflowErrorDeliveredToSink = false
        }
        pcmFrameBufferCount = 0
    }

    private fun finishPcmFrameDelivery(clearBufferedFrames: Boolean) {
        pcmFrameBufferCount = 0
        if (clearBufferedFrames) {
            resetPcmFrameBuffer()
            return
        }
        val drainToken = synchronized(pcmFrameLock) {
            if (pcmEventSink == null) earlyPcmFrames.reset()
            pcmDrainPacer.request(
                hasListener = pcmEventSink != null,
                hasFrames = !earlyPcmFrames.isEmpty,
                overflowed = earlyPcmFrames.overflowed,
            )
        }
        drainToken?.let(::schedulePcmDrain)
    }

    @Suppress("DEPRECATION")
    private fun createRecorder(): MediaRecorder {
        val value = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            MediaRecorder(context)
        } else {
            MediaRecorder()
        }
        value.setAudioSource(MediaRecorder.AudioSource.MIC)
        value.setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
        value.setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
        value.setAudioSamplingRate(44_100)
        value.setAudioEncodingBitRate(96_000)
        return value
    }

    @Throws(IOException::class)
    private fun recordingDirectory(accountDirectory: String? = recordingAccountDirectory): File {
        val directory = if (accountDirectory == null) {
            File(context.filesDir, "recordings/imports")
        } else {
            File(context.filesDir, "recordings/users/$accountDirectory/imports")
        }
        if (!directory.exists() && !directory.mkdirs()) {
            throw IOException("voice recording directory unavailable")
        }
        return directory
    }

    private fun validAccountDirectory(value: Any?): String? {
        val candidate = (value as? String)?.trim() ?: return null
        return candidate.takeIf { ACCOUNT_DIRECTORY_PATTERN.matches(it) }
    }

    private fun appPrivateUri(id: String, scene: String): String {
        return "app-private://${finalFileName(id, scene)}"
    }

    private fun finalFileName(id: String, scene: String): String {
        return "$id.${if (usesPcmWav(scene)) "wav" else "m4a"}"
    }

    private fun partFileName(id: String, scene: String): String {
        val extension = if (usesPcmWav(scene)) "wav" else "m4a"
        return "$id.part.$extension"
    }

    private fun usesPcmWav(scene: String?): Boolean {
        return scene == VOICEPRINT_SCENE || isSharedPcmScene(scene)
    }

    private fun isSharedPcmScene(scene: String?): Boolean {
        return scene == "monologue" || scene == "meeting"
    }

    @Throws(IOException::class)
    private fun sha256Hex(file: File): String {
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buffer = ByteArray(64 * 1024)
            while (true) {
                val count = input.read(buffer)
                if (count <= 0) break
                digest.update(buffer, 0, count)
            }
        }
        return digest.digest().joinToString("") { byte -> "%02x".format(byte) }
    }

    private fun clearRecordingState(deletePart: Boolean) {
        stopLevelMetering(emitBaseline = false)
        VoiceRecordingForegroundService.stop(context)
        if (deletePart) partFile?.delete()
        recordingId = null
        recordingScene = null
        recordingStartedAtMs = null
        pausedAtMs = null
        pausedDurationMs = 0L
        partFile = null
        recordingAccountDirectory = null
        pcmCaptureRunning = false
        pcmCapturePaused = false
        pcmCaptureFailed = false
        pcmAverage = 0.0
        pcmPeak = 0.0
        pcmCapturedBytes = 0L
        recordingFailureCode = null
        state = STATE_IDLE
    }

    private fun releaseRecorder() {
        synchronized(recorderMeteringLock) {
            val activeRecorder = recorder ?: return
            recorder = null
            runCatching { activeRecorder.reset() }
            runCatching { activeRecorder.release() }
        }
    }

    private fun startPcmRecording(
        id: String,
        scene: String,
        pendingFile: File,
        result: MethodChannel.Result,
    ) {
        logPcmStage("foreground_start_requested")
        if (!VoiceRecordingForegroundService.start(context)) {
            logPcmStage("foreground_start_failed")
            result.error(
                "VOICE_RECORDER_FOREGROUND_SERVICE_FAILED",
                "Microphone recording could not enter foreground mode.",
                null,
            )
            return
        }
        val minimumBuffer = AudioRecord.getMinBufferSize(
            VOICEPRINT_SAMPLE_RATE,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT,
        )
        if (minimumBuffer <= 0) throw IOException("PCM buffer unavailable")
        val bufferSize = maxOf(minimumBuffer, PCM_FRAME_BYTES)
        val activeRecorder = AudioRecord(
            MediaRecorder.AudioSource.MIC,
            VOICEPRINT_SAMPLE_RATE,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT,
            bufferSize,
        )
        if (activeRecorder.state != AudioRecord.STATE_INITIALIZED) {
            activeRecorder.release()
            throw IOException("PCM recorder unavailable")
        }
        val output = FileOutputStream(pendingFile)
        output.write(ByteArray(WAV_HEADER_BYTES))
        try {
            activeRecorder.startRecording()
        } catch (error: Exception) {
            output.close()
            activeRecorder.release()
            throw error
        }
        if (activeRecorder.recordingState != AudioRecord.RECORDSTATE_RECORDING) {
            output.close()
            activeRecorder.release()
            throw IOException("PCM recorder did not start")
        }
        logPcmStage("audio_record_started")

        pcmRecorder = activeRecorder
        pcmCaptureRunning = true
        pcmCapturePaused = false
        pcmCaptureFailed = false
        pcmAverage = 0.0
        pcmPeak = 0.0
        pcmCapturedBytes = 0L
        recordingFailureCode = null
        resetPcmFrameBuffer()
        if (isSharedPcmScene(scene)) {
            sharedTencentPcmSource.beginCapture()
        } else {
            sharedTencentPcmSource.endCapture(clearBufferedSamples = true)
        }
        recordingId = id
        recordingScene = scene
        recordingStartedAtMs = System.currentTimeMillis()
        pausedAtMs = null
        pausedDurationMs = 0L
        partFile = pendingFile
        state = STATE_RECORDING
        val maximumDataBytes = if (scene == VOICEPRINT_SCENE) {
            minOf(
                VOICEPRINT_MAX_FILE_BYTES - WAV_HEADER_BYTES,
                VOICEPRINT_SAMPLE_RATE * VOICEPRINT_BYTES_PER_SAMPLE * VOICEPRINT_MAX_DURATION_SECONDS,
            )
        } else {
            MAX_SHARED_PCM_DATA_BYTES
        }
        pcmCaptureThread = Thread({
            val buffer = ByteArray(bufferSize)
            var totalBytes = 0
            try {
                output.use { sink ->
                    while (pcmCaptureRunning && totalBytes < maximumDataBytes) {
                        if (pcmCapturePaused) {
                            Thread.sleep(20)
                            continue
                        }
                        val count = activeRecorder.read(buffer, 0, buffer.size)
                        if (count <= 0) {
                            if (count < 0 && pcmCaptureRunning && !pcmCapturePaused) {
                                pcmCaptureFailed = true
                                recordingFailureCode = "VOICE_RECORDER_PCM_CAPTURE_FAILED"
                                logPcmStage("audio_record_read_failed")
                                break
                            }
                            continue
                        }
                        val accepted = minOf(count, maximumDataBytes - totalBytes).let {
                            it - (it % VOICEPRINT_BYTES_PER_SAMPLE)
                        }
                        if (accepted <= 0) continue
                        sink.write(buffer, 0, accepted)
                        totalBytes += accepted
                        if (scene == VOICEPRINT_SCENE) {
                            pcmCapturedBytes = totalBytes.toLong()
                        }
                        updatePcmLevel(buffer, accepted)
                        if (isSharedPcmScene(scene)) {
                            publishPcmBytes(buffer, accepted)
                        }
                    }
                    sink.flush()
                }
            } catch (_: Exception) {
                pcmCaptureFailed = true
                recordingFailureCode = "VOICE_RECORDER_PCM_CAPTURE_FAILED"
                logPcmStage("audio_record_loop_failed")
            } finally {
                pcmCaptureRunning = false
                if (pcmCaptureFailed) failPcmCapture(activeRecorder)
            }
        }, "huahuo-pcm-capture").also { it.start() }
        logPcmStage("pcm_capture_ready")
        startLevelMetering()
        result.success(recordingStateMap())
    }

    private fun stopPcmRecording(result: MethodChannel.Result) {
        val id = recordingId
        val scene = recordingScene
        val sourceFile = partFile
        val recordedAt = recordingStartedAtMs?.let(::isoTime)
        if (id == null || scene == null || !usesPcmWav(scene) || sourceFile == null || pcmRecorder == null) {
            result.error("VOICE_RECORDER_NOT_ACTIVE", "No active PCM recording exists.", null)
            return
        }
        stopLevelMetering(emitBaseline = true)
        val captureStopped = stopAndReleasePcmRecorder(clearBufferedFrames = false)
        if (!captureStopped) {
            clearRecordingState(deletePart = false)
            result.error(
                "VOICE_RECORDER_STOP_TIMEOUT",
                "Voice capture did not stop before the safety deadline.",
                null,
            )
            return
        }
        val finalFile = File(sourceFile.parentFile, finalFileName(id, scene))
        try {
            if (pcmCaptureFailed || !sourceFile.isFile || sourceFile.length() <= WAV_HEADER_BYTES) {
                throw IOException("PCM capture is empty")
            }
            finalizePcmWav(sourceFile)
            if (finalFile.exists()) finalFile.delete()
            if (!sourceFile.renameTo(finalFile)) throw IOException("PCM promotion failed")
            val metadata = validatePcmWav(finalFile, enforceVoiceprintBounds = scene == VOICEPRINT_SCENE)
                ?: throw IOException("PCM WAV is invalid")
            val sha256 = sha256Hex(finalFile)
            if (!SHA_256_PATTERN.matches(sha256)) throw IOException("PCM checksum is invalid")
            val payload = mapOf(
                "recordingId" to id,
                "scene" to scene,
                "appPrivateUri" to appPrivateUri(id, scene),
                "fileName" to finalFileName(id, scene),
                "mimeType" to "audio/wav",
                "sizeBytes" to finalFile.length(),
                "durationSeconds" to metadata.durationSeconds,
                "sampleRateHz" to metadata.sampleRate,
                "bitDepth" to metadata.bitDepth,
                "channelCount" to metadata.channelCount,
                "sha256" to sha256,
                "recordedAt" to recordedAt,
            )
            clearRecordingState(deletePart = false)
            result.success(payload)
        } catch (_: Exception) {
            sourceFile.delete()
            finalFile.delete()
            clearRecordingState(deletePart = false)
            val errorCode = if (scene == VOICEPRINT_SCENE) {
                "VOICEPRINT_SAMPLE_FORMAT_INVALID"
            } else {
                "VOICE_RECORDER_FILE_UNAVAILABLE"
            }
            result.error(errorCode, "PCM recording is invalid or unavailable.", null)
        }
    }

    private fun stopAndReleasePcmRecorder(clearBufferedFrames: Boolean = true): Boolean {
        if (pcmCaptureCleanupRunning) return false
        pcmCaptureRunning = false
        pcmCapturePaused = false
        val activeRecorder = pcmRecorder
        val captureThread = pcmCaptureThread
        val stagingFile = partFile
        pcmRecorder = null
        runCatching { activeRecorder?.stop() }
        val stoppedBeforeDeadline = awaitPcmCaptureThreadTermination(
            captureThread,
            PCM_CAPTURE_JOIN_TIMEOUT_MS,
        )
        runCatching { activeRecorder?.release() }
        if (stoppedBeforeDeadline) {
            if (pcmCaptureThread === captureThread) pcmCaptureThread = null
            sharedTencentPcmSource.endCapture(
                clearBufferedSamples = clearBufferedFrames,
            )
            finishPcmFrameDelivery(clearBufferedFrames)
            logPcmStage("audio_record_stopped")
            return true
        }

        pcmCaptureFailed = true
        captureThread?.interrupt()
        val stoppedAfterRelease = awaitPcmCaptureThreadTermination(
            captureThread,
            PCM_CAPTURE_RELEASE_GRACE_MS,
        )
        if (stoppedAfterRelease) {
            if (pcmCaptureThread === captureThread) pcmCaptureThread = null
            stagingFile?.delete()
            sharedTencentPcmSource.endCapture(clearBufferedSamples = true)
            finishPcmFrameDelivery(clearBufferedFrames = true)
        } else if (captureThread != null) {
            scheduleTimedOutPcmCleanup(captureThread, stagingFile)
        }
        return false
    }

    /**
     * A broken AudioRecord must not remain allocated after its capture thread
     * exits. Keeping it alive makes the next user tap inherit stale recorder
     * state while realtime ASR retries against an ended audio source.
     */
    private fun failPcmCapture(activeRecorder: AudioRecord) {
        if (pcmRecorder !== activeRecorder) return
        pcmCaptureRunning = false
        pcmCapturePaused = false
        pcmRecorder = null
        runCatching { activeRecorder.stop() }
        runCatching { activeRecorder.release() }
        if (pcmCaptureThread === Thread.currentThread()) {
            pcmCaptureThread = null
        }
        sharedTencentPcmSource.endCapture(clearBufferedSamples = true)
        finishPcmFrameDelivery(clearBufferedFrames = true)
        partFile?.delete()
        recordingId = null
        recordingScene = null
        recordingStartedAtMs = null
        pausedAtMs = null
        pausedDurationMs = 0L
        partFile = null
        recordingAccountDirectory = null
        pcmAverage = 0.0
        pcmPeak = 0.0
        pcmCapturedBytes = 0L
        recordingFailureCode = "VOICE_RECORDER_PCM_CAPTURE_FAILED"
        state = STATE_FAILED
        stopLevelMetering(emitBaseline = true)
        VoiceRecordingForegroundService.stop(context)
        logPcmStage("audio_record_capture_failed")
    }

    private fun logPcmStage(stage: String) {
        Log.i(VOICE_RECORDER_LOG_TAG, "[VoiceRecorder] stage=$stage")
    }

    private fun scheduleTimedOutPcmCleanup(captureThread: Thread, stagingFile: File?) {
        pcmCaptureCleanupRunning = true
        Thread({
            while (captureThread.isAlive) {
                try {
                    captureThread.join()
                } catch (_: InterruptedException) {
                    // Cleanup must remain responsible for the staging file.
                }
            }
            stagingFile?.delete()
            sharedTencentPcmSource.endCapture(clearBufferedSamples = true)
            finishPcmFrameDelivery(clearBufferedFrames = true)
            if (pcmCaptureThread === captureThread) pcmCaptureThread = null
            pcmCaptureCleanupRunning = false
        }, "huahuo-pcm-cleanup").start()
    }

    private fun updatePcmLevel(buffer: ByteArray, count: Int) {
        var sum = 0.0
        var peak = 0
        var samples = 0
        var index = 0
        while (index + 1 < count) {
            val sample = ((buffer[index + 1].toInt() shl 8) or (buffer[index].toInt() and 0xFF)).toShort().toInt()
            val magnitude = kotlin.math.abs(sample)
            sum += magnitude
            peak = maxOf(peak, magnitude)
            samples += 1
            index += 2
        }
        if (samples == 0) return
        pcmAverage = (sum / samples / Short.MAX_VALUE).coerceIn(0.0, 1.0)
        pcmPeak = (peak.toDouble() / Short.MAX_VALUE).coerceIn(0.0, 1.0)
    }

    private fun finalizePcmWav(file: File) {
        val dataSize = file.length() - WAV_HEADER_BYTES
        if (dataSize <= 0 || dataSize > Int.MAX_VALUE) throw IOException("voiceprint data size invalid")
        RandomAccessFile(file, "rw").use { wav ->
            wav.seek(0)
            wav.writeBytes("RIFF")
            wav.writeLittleEndianInt(36 + dataSize.toInt())
            wav.writeBytes("WAVE")
            wav.writeBytes("fmt ")
            wav.writeLittleEndianInt(16)
            wav.writeLittleEndianShort(1)
            wav.writeLittleEndianShort(VOICEPRINT_CHANNEL_COUNT)
            wav.writeLittleEndianInt(VOICEPRINT_SAMPLE_RATE)
            wav.writeLittleEndianInt(VOICEPRINT_SAMPLE_RATE * VOICEPRINT_BYTES_PER_SAMPLE)
            wav.writeLittleEndianShort(VOICEPRINT_BYTES_PER_SAMPLE)
            wav.writeLittleEndianShort(VOICEPRINT_BIT_DEPTH)
            wav.writeBytes("data")
            wav.writeLittleEndianInt(dataSize.toInt())
        }
    }

    private fun validatePcmWav(
        file: File,
        enforceVoiceprintBounds: Boolean = true,
    ): PcmWavMetadata? {
        if (!file.isFile ||
            file.length() <= WAV_HEADER_BYTES ||
            (enforceVoiceprintBounds && file.length() > VOICEPRINT_MAX_FILE_BYTES)
        ) {
            return null
        }
        return runCatching {
            RandomAccessFile(file, "r").use { wav ->
                if (wav.readAscii(4) != "RIFF") return@use null
                val riffSize = wav.readLittleEndianInt()
                if (wav.readAscii(4) != "WAVE" || wav.readAscii(4) != "fmt ") return@use null
                val formatSize = wav.readLittleEndianInt()
                val audioFormat = wav.readLittleEndianShort()
                val channelCount = wav.readLittleEndianShort()
                val sampleRate = wav.readLittleEndianInt()
                val byteRate = wav.readLittleEndianInt()
                val blockAlign = wav.readLittleEndianShort()
                val bitDepth = wav.readLittleEndianShort()
                if (formatSize != 16 ||
                    audioFormat != 1 ||
                    channelCount != VOICEPRINT_CHANNEL_COUNT ||
                    sampleRate != VOICEPRINT_SAMPLE_RATE ||
                    byteRate != VOICEPRINT_SAMPLE_RATE * VOICEPRINT_BYTES_PER_SAMPLE ||
                    blockAlign != VOICEPRINT_BYTES_PER_SAMPLE ||
                    bitDepth != VOICEPRINT_BIT_DEPTH ||
                    wav.readAscii(4) != "data"
                ) return@use null
                val dataSize = wav.readLittleEndianInt()
                if (dataSize <= 0 ||
                    dataSize % blockAlign != 0 ||
                    riffSize != 36 + dataSize ||
                    file.length() != WAV_HEADER_BYTES.toLong() + dataSize
                ) return@use null
                val duration = ceil(
                    dataSize.toDouble() /
                        VOICEPRINT_BYTES_PER_SECOND,
                ).toInt()
                val durationMilliseconds =
                    dataSize * 1_000L / VOICEPRINT_BYTES_PER_SECOND
                if (duration < 1 ||
                    (enforceVoiceprintBounds &&
                        (durationMilliseconds <
                            VOICEPRINT_MIN_DURATION_SECONDS * 1_000L ||
                            durationMilliseconds >
                                VOICEPRINT_MAX_ACCEPTED_DURATION_MILLISECONDS))
                ) return@use null
                PcmWavMetadata(
                    durationSeconds = duration,
                    sampleRate = sampleRate,
                    bitDepth = bitDepth,
                    channelCount = channelCount,
                )
            }
        }.getOrNull()
    }

    private fun completePermissionFailure(code: String) {
        val pending = permissionResult ?: return
        clearPermissionRequest()
        pending.error(code, "Microphone permission could not be requested.", null)
    }

    private fun clearPermissionRequest() {
        permissionTimeout?.let(mainHandler::removeCallbacks)
        permissionTimeout = null
        permissionResult = null
    }

    private fun dispose() {
        val pending = permissionResult
        clearPermissionRequest()
        pending?.error("VOICE_RECORDER_PERMISSION_REQUEST_CANCELLED", "Permission request was cancelled.", null)
        stopLevelMetering(emitBaseline = false)
        val captureStopped = stopAndReleasePcmRecorder()
        releaseRecorder()
        clearRecordingState(deletePart = captureStopped)
        levelEventSink = null
        detachPcmEventSink()
        sharedTencentPcmSource.endCapture(clearBufferedSamples = true)
        resetPcmFrameBuffer()
        levelChannel.setStreamHandler(null)
        pcmChannel.setStreamHandler(null)
        channel.setMethodCallHandler(null)
        levelThread.quitSafely()
    }

    private fun createTencentPcmDataSource(): Any? {
        if (!isSharedPcmScene(recordingScene) || !pcmCaptureRunning) return null
        return sharedTencentPcmSource.newProxy()
    }

    private fun detachTencentPcmDataSource() {
        sharedTencentPcmSource.detachConsumer()
    }
}

internal fun awaitPcmCaptureThreadTermination(thread: Thread?, timeoutMillis: Long): Boolean {
    if (thread == null || !thread.isAlive) return true
    if (thread === Thread.currentThread() || timeoutMillis <= 0L) return false
    return try {
        thread.join(timeoutMillis)
        !thread.isAlive
    } catch (_: InterruptedException) {
        Thread.currentThread().interrupt()
        false
    }
}

/** One Tencent consumer reads copied samples from the recorder-owned PCM loop. */
internal class SharedTencentPcmSource(
    private val maximumBufferedSamples: Int = 16_000 * 45,
) {
    private val lock = Object()
    private val samples = ArrayDeque<Short>()
    private var captureActive = false
    private var consumerActive = false

    fun beginCapture() {
        synchronized(lock) {
            samples.clear()
            captureActive = true
            consumerActive = false
            lock.notifyAll()
        }
    }

    fun append(bytes: ByteArray, count: Int) {
        if (count < 2) return
        synchronized(lock) {
            if (!captureActive) return
            var index = 0
            val limit = count - (count % 2)
            while (index < limit && samples.size < maximumBufferedSamples) {
                val sample = ((bytes[index + 1].toInt() shl 8) or
                    (bytes[index].toInt() and 0xff)).toShort()
                samples.addLast(sample)
                index += 2
            }
            lock.notifyAll()
        }
    }

    fun endCapture(clearBufferedSamples: Boolean) {
        synchronized(lock) {
            captureActive = false
            if (clearBufferedSamples || !consumerActive) {
                consumerActive = false
                samples.clear()
            }
            lock.notifyAll()
        }
    }

    fun detachConsumer() {
        synchronized(lock) {
            consumerActive = false
            samples.clear()
            lock.notifyAll()
        }
    }

    fun newProxy(): Any? {
        val sourceClass = runCatching {
            Class.forName("com.tencent.aai.audio.data.PcmAudioDataSource")
        }.getOrNull() ?: return null
        synchronized(lock) {
            if (!captureActive || consumerActive) return null
            consumerActive = true
        }
        return Proxy.newProxyInstance(
            sourceClass.classLoader,
            arrayOf(sourceClass),
            InvocationHandler { _, method, args -> invoke(method.name, args) },
        )
    }

    private fun invoke(methodName: String, args: Array<out Any?>?): Any? = when (methodName) {
        "start" -> Unit
        "stop" -> {
            detachConsumer()
            Unit
        }
        "isSetSaveAudioRecordFiles" -> false
        "read" -> read(args)
        "toString" -> "HuahuoSharedTencentPcmSource"
        "hashCode" -> System.identityHashCode(this)
        "equals" -> false
        else -> null
    }

    private fun read(args: Array<out Any?>?): Int {
        val target = args?.getOrNull(0) as? ShortArray ?: return -1
        val requested = (args?.getOrNull(1) as? Number)?.toInt() ?: return -1
        if (requested <= 0) return 0
        val count = minOf(requested, target.size)
        synchronized(lock) {
            val deadline = System.currentTimeMillis() + 500L
            while (consumerActive && captureActive && samples.size < count) {
                val remaining = deadline - System.currentTimeMillis()
                if (remaining <= 0L) break
                try {
                    lock.wait(remaining)
                } catch (_: InterruptedException) {
                    Thread.currentThread().interrupt()
                    return -1
                }
            }
            if (!consumerActive) return -1
            if (samples.size < count) {
                if (!captureActive) samples.clear()
                return if (captureActive) 0 else -1
            }
            repeat(count) { index -> target[index] = samples.removeFirst() }
            return count
        }
    }
}

internal class PcmEarlyFrameQueue(val capacityFrames: Int) {
    private val frames = ArrayDeque<ByteArray>()

    init {
        require(capacityFrames > 0)
    }

    var overflowed: Boolean = false
        private set
    var droppedFrameCount: Int = 0
        private set

    val isEmpty: Boolean get() = frames.isEmpty()
    val size: Int get() = frames.size

    fun append(frame: ByteArray): Boolean {
        if (overflowed) {
            droppedFrameCount += 1
            return false
        }
        if (frames.size >= capacityFrames) {
            overflowed = true
            droppedFrameCount = frames.size + 1
            frames.clear()
            return false
        }
        frames.addLast(frame)
        return true
    }

    fun removeFirstOrNull(): ByteArray? {
        return if (frames.isEmpty()) null else frames.removeFirst()
    }

    fun reset() {
        frames.clear()
        overflowed = false
        droppedFrameCount = 0
    }
}

internal class PcmFrameDrainPacer {
    companion object {
        const val INTERVAL_MILLIS = 20L
    }

    private var generation = 0L
    var scheduled: Boolean = false
        private set

    fun request(hasListener: Boolean, hasFrames: Boolean, overflowed: Boolean): Long? {
        if (!hasListener || !hasFrames || overflowed || scheduled) return null
        scheduled = true
        return generation
    }

    fun beginDelivery(token: Long): Boolean {
        if (!scheduled || token != generation) return false
        scheduled = false
        return true
    }

    fun cancel() {
        generation += 1
        scheduled = false
    }
}

private data class PcmWavMetadata(
    val durationSeconds: Int,
    val sampleRate: Int,
    val bitDepth: Int,
    val channelCount: Int,
)

private fun RandomAccessFile.writeLittleEndianInt(value: Int) {
    write(value and 0xFF)
    write(value ushr 8 and 0xFF)
    write(value ushr 16 and 0xFF)
    write(value ushr 24 and 0xFF)
}

private fun RandomAccessFile.writeLittleEndianShort(value: Int) {
    write(value and 0xFF)
    write(value ushr 8 and 0xFF)
}

private fun RandomAccessFile.readLittleEndianInt(): Int {
    val first = read()
    val second = read()
    val third = read()
    val fourth = read()
    if (first < 0 || second < 0 || third < 0 || fourth < 0) throw IOException("truncated WAV")
    return first or (second shl 8) or (third shl 16) or (fourth shl 24)
}

private fun RandomAccessFile.readLittleEndianShort(): Int {
    val first = read()
    val second = read()
    if (first < 0 || second < 0) throw IOException("truncated WAV")
    return first or (second shl 8)
}

private fun RandomAccessFile.readAscii(length: Int): String {
    val bytes = ByteArray(length)
    readFully(bytes)
    return bytes.toString(Charsets.US_ASCII)
}

private fun isoTime(timestampMs: Long): String {
    return SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.US).apply {
        timeZone = TimeZone.getTimeZone("UTC")
    }.format(Date(timestampMs))
}
