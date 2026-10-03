package com.hangzhouchuda.huahuoai

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.Context
import android.content.SharedPreferences
import android.content.res.Configuration
import android.content.pm.PackageManager
import android.media.projection.MediaProjectionManager
import android.media.projection.MediaProjectionConfig
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.net.Uri
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import java.util.concurrent.CopyOnWriteArraySet
import java.util.UUID
import org.json.JSONObject

internal object ScreenCaptureSessionRegistry {
    private val listeners = CopyOnWriteArraySet<(Map<String, Any?>) -> Unit>()
    private val lock = Any()
    private var state = "idle"
    private var startedAtMillis: Long? = null
    private var fixedElapsedSeconds = 0
    private var media: Map<String, Any?>? = null
    private var errorCode: String? = null
    private var sessionId: String? = null
    private var preferences: SharedPreferences? = null

    fun initialize(context: Context) = synchronized(lock) {
        if (preferences != null) return@synchronized
        val store = context.getSharedPreferences("internal_screen_capture", Context.MODE_PRIVATE)
        preferences = store
        val saved = runCatching { JSONObject(store.getString("snapshot", null) ?: "{}") }.getOrNull()
            ?: return@synchronized
        sessionId = saved.optString("sessionId").takeIf { it.isNotBlank() }
        if (sessionId == null) return@synchronized
        if (saved.optString("state") == "completed") {
            val storedMedia = saved.optJSONObject("media") ?: return@synchronized
            media = storedMedia.keys().asSequence().associateWith { storedMedia.get(it) }
            fixedElapsedSeconds = saved.optInt("elapsedSeconds").coerceIn(0, MAX_DURATION_SECONDS)
            state = "completed"
        } else {
            state = "failed"
            errorCode = "SCREEN_CAPTURE_SESSION_INTERRUPTED"
        }
    }

    fun snapshot(): Map<String, Any?> = synchronized(lock) { snapshotLocked() }

    fun session(id: String): Map<String, Any?> = synchronized(lock) {
        if (id == sessionId) return@synchronized snapshotLocked()
        val raw = preferences?.getString("session:$id", null)
            ?: return@synchronized mapOf("state" to "idle", "sessionId" to id, "elapsedSeconds" to 0)
        decode(JSONObject(raw))
    }

    fun retain(payload: Map<String, Any?>) = synchronized(lock) {
        val id = payload["sessionId"] as? String ?: error("Missing session")
        check(preferences?.edit()?.putString("session:$id", JSONObject(payload).toString())?.commit() == true)
    }

    fun forget(id: String) = synchronized(lock) {
        check(!(id == sessionId && isActive()))
        val editor = checkNotNull(preferences).edit().remove("session:$id")
        if (id == sessionId) editor.remove("snapshot")
        check(editor.commit())
        if (id == sessionId) {
            state = "idle"; sessionId = null; media = null; errorCode = null
            startedAtMillis = null; fixedElapsedSeconds = 0
        }
    }

    private fun decode(value: JSONObject): Map<String, Any?> = value.keys().asSequence().associateWith {
        when (val item = value.get(it)) {
            is JSONObject -> decode(item)
            JSONObject.NULL -> null
            else -> item
        }
    }

    fun isActive(): Boolean = synchronized(lock) {
        state == "starting" || state == "recording" || state == "stopping"
    }

    fun markStarting(id: String) {
        synchronized(lock) {
            if (media != null) retain(snapshotLocked())
            sessionId = id
        }
        publish("starting")
    }

    fun markRecording(startedAt: Long) = publish(
        nextState = "recording",
        nextStartedAtMillis = startedAt,
    )

    fun markStopping() = publish(
        nextState = "stopping",
        nextStartedAtMillis = synchronized(lock) { startedAtMillis },
    )

    fun markCompleted(
        elapsedSeconds: Int,
        completedMedia: Map<String, Any?>,
    ) = publish(
        nextState = "completed",
        nextElapsedSeconds = elapsedSeconds,
        nextMedia = completedMedia,
    )

    fun markFailed(code: String) = publish(
        nextState = "failed",
        nextErrorCode = code,
    )

    fun addListener(listener: (Map<String, Any?>) -> Unit) {
        listeners.add(listener)
    }

    fun removeListener(listener: (Map<String, Any?>) -> Unit) {
        listeners.remove(listener)
    }

    private fun publish(
        nextState: String,
        nextStartedAtMillis: Long? = null,
        nextElapsedSeconds: Int = 0,
        nextMedia: Map<String, Any?>? = null,
        nextErrorCode: String? = null,
    ) {
        val value = synchronized(lock) {
            state = nextState
            startedAtMillis = nextStartedAtMillis
            fixedElapsedSeconds = nextElapsedSeconds.coerceIn(0, MAX_DURATION_SECONDS)
            media = nextMedia
            errorCode = nextErrorCode
            val snapshot = snapshotLocked()
            val editor = checkNotNull(preferences).edit()
            val encoded = JSONObject(snapshot).toString()
            editor.putString("snapshot", encoded)
            if (nextState == "completed" || nextState == "failed") {
                sessionId?.let { editor.putString("session:$it", encoded) }
            }
            if (!editor.commit() && nextState == "completed") {
                state = "failed"
                errorCode = "SCREEN_CAPTURE_STORAGE_FAILED"
                snapshotLocked()
            } else snapshot
        }
        listeners.forEach { it(value) }
    }

    private fun snapshotLocked(): Map<String, Any?> {
        val elapsed = when {
            state == "recording" || state == "stopping" -> startedAtMillis?.let {
                ((System.currentTimeMillis() - it).coerceAtLeast(0L) / 1000L)
                    .coerceAtMost(MAX_DURATION_SECONDS.toLong())
                    .toInt()
            } ?: fixedElapsedSeconds
            else -> fixedElapsedSeconds
        }
        return buildMap {
            put("state", state)
            put("elapsedSeconds", elapsed)
            sessionId?.let { put("sessionId", it) }
            startedAtMillis?.let { put("startedAt", isoDate(it)) }
            media?.let { put("media", it) }
            errorCode?.let { put("errorCode", it) }
        }
    }

    private fun isoDate(millis: Long): String = synchronized(isoFormatter) {
        isoFormatter.format(Date(millis))
    }

    private const val MAX_DURATION_SECONDS = 1800
    private val isoFormatter = SimpleDateFormat(
        "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'",
        Locale.US,
    ).apply { timeZone = TimeZone.getTimeZone("UTC") }
}

internal class ScreenCaptureAndroidBridge private constructor(
    private val activity: MainActivity,
    messenger: BinaryMessenger,
) : EventChannel.StreamHandler {
    private val mainHandler = Handler(Looper.getMainLooper())
    private val methodChannel = MethodChannel(messenger, METHOD_CHANNEL)
    private val eventChannel = EventChannel(messenger, EVENT_CHANNEL)
    private var eventSink: EventChannel.EventSink? = null
    private var pendingStart: PendingStart? = null
    private var consentTimeout: Runnable? = null
    private val registryListener: (Map<String, Any?>) -> Unit = { snapshot ->
        mainHandler.post { eventSink?.success(snapshot) }
    }

    init {
        ScreenCaptureSessionRegistry.initialize(activity.applicationContext)
        methodChannel.setMethodCallHandler(::handleMethodCall)
        eventChannel.setStreamHandler(this)
        ScreenCaptureSessionRegistry.addListener(registryListener)
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
        events?.success(ScreenCaptureSessionRegistry.snapshot())
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    private fun handleMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "getCapability" -> result.success(capability())
            "getState" -> result.success(pendingImport?.let { importingSnapshot(it.sessionId) }
                ?: ScreenCaptureSessionRegistry.snapshot())
            "getSession" -> {
                val id = validSessionId(call.arguments)
                if (id == null) result.error("SCREEN_CAPTURE_REQUEST_INVALID", "Invalid session.", null)
                else runCatching {
                    if (pendingImport?.sessionId == id) importingSnapshot(id) else ScreenCaptureSessionRegistry.session(id)
                }.fold(result::success) { result.error("SCREEN_CAPTURE_STATE_UNAVAILABLE", "Could not recover session.", null) }
            }
            "importVideo" -> importVideo(call.arguments, result)
            "releaseSession" -> releaseSession(call.arguments, result)
            "startCapture" -> startCapture(call.arguments as? Map<*, *>, result)
            "stopCapture" -> stopCapture(call.arguments as? Map<*, *>, result)
            "extractAudio" -> extractAudio(call.arguments as? Map<*, *>, result)
            else -> result.notImplemented()
        }
    }

    private fun validSessionId(arguments: Any?): String? = ((arguments as? Map<*, *>)?.get("sessionId") as? String)
        ?.takeIf { Regex("^[A-Za-z0-9_-]{1,100}$").matches(it) }

    private fun importingSnapshot(id: String): Map<String, Any?> =
        mapOf("state" to "importing", "sessionId" to id, "elapsedSeconds" to 0)

    private fun importVideo(arguments: Any?, result: MethodChannel.Result) {
        val id = validSessionId(arguments)
        if (id == null) { result.error("SCREEN_CAPTURE_REQUEST_INVALID", "Invalid session.", null); return }
        if (pendingImport != null || pendingStart != null || ScreenCaptureSessionRegistry.isActive()) {
            result.error("SCREEN_CAPTURE_ALREADY_ACTIVE", "Another capture or picker is active.", null); return
        }
        val pending = PendingImport(id, nextRequestCode(), result)
        runCatching {
            check(ScreenCaptureSessionRegistry.session(id)["state"] == "idle")
            ScreenCaptureSessionRegistry.retain(mapOf("state" to "failed", "sessionId" to id,
                "elapsedSeconds" to 0, "errorCode" to "SCREEN_CAPTURE_IMPORT_INTERRUPTED"))
            pendingImport = pending
            activity.startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                addCategory(Intent.CATEGORY_OPENABLE)
                type = "video/mp4"
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }, pending.requestCode)
            mainHandler.postDelayed({
                if (pendingImport === pending && !pending.copying) finishImport(pending, null)
            }, 300_000L)
        }.onFailure {
            pendingImport = null
            result.error("SCREEN_CAPTURE_IMPORT_FAILED", "Video picker could not open.", null)
        }
    }

    private fun finishImport(pending: PendingImport, uri: Uri?) {
        if (pending.copying) return
        if (uri == null) {
            val payload = mapOf("state" to "failed", "sessionId" to pending.sessionId,
                "elapsedSeconds" to 0, "errorCode" to "SCREEN_CAPTURE_CONSENT_CANCELLED")
            runCatching { ScreenCaptureSessionRegistry.retain(payload) }
            pendingImport = null
            pending.result?.success(payload)
            pending.result = null
            return
        }
        pending.copying = true
        Thread({
            val outcome = runCatching {
                val media = ScreenCaptureService.importVideo(activity.applicationContext, uri, pending.sessionId)
                val payload = mapOf("state" to "completed", "sessionId" to pending.sessionId,
                    "elapsedSeconds" to media["durationSeconds"], "media" to media)
                ScreenCaptureSessionRegistry.retain(payload)
                payload
            }
            mainHandler.post {
                pendingImport = null
                outcome.fold({ pending.result?.success(it) }) {
                    runCatching { ScreenCaptureService.releaseMedia(activity.applicationContext,
                        "app-private-media://screen-capture/import-${pending.sessionId}.mp4") }
                    pending.result?.error("SCREEN_CAPTURE_IMPORT_FAILED", "Could not import this MP4 video.", null)
                }
                pending.result = null
            }
        }, "screen-capture-import").start()
    }

    private fun releaseSession(arguments: Any?, result: MethodChannel.Result) {
        val id = validSessionId(arguments)
        if (id == null) { result.error("SCREEN_CAPTURE_REQUEST_INVALID", "Invalid session.", null); return }
        if (pendingImport?.sessionId == id || (ScreenCaptureSessionRegistry.snapshot()["sessionId"] == id && ScreenCaptureSessionRegistry.isActive())) {
            result.error("SCREEN_CAPTURE_CLEANUP_BUSY", "Session is active.", null); return
        }
        Thread({
            runCatching {
                val saved = ScreenCaptureSessionRegistry.session(id)
                val media = saved["media"] as? Map<*, *>
                ScreenCaptureService.releaseMedia(activity.applicationContext, media?.get("appPrivateUri") as? String)
                ScreenCaptureSessionRegistry.forget(id)
            }.fold(
                onSuccess = { mainHandler.post { result.success(true) } },
                onFailure = { mainHandler.post { result.error("SCREEN_CAPTURE_CLEANUP_FAILED", "Could not remove session media.", null) } },
            )
        }, "screen-capture-cleanup").start()
    }

    private fun capability(): Map<String, Any> {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            return mapOf(
                "supported" to false,
                "canCaptureSystemAudio" to false,
                "requiresSystemPicker" to true,
                "reasonCode" to "SCREEN_CAPTURE_ANDROID_VERSION_UNSUPPORTED",
            )
        }
        return mapOf(
            "supported" to true,
            "canCaptureSystemAudio" to true,
            "requiresSystemPicker" to true,
        )
    }

    private fun startCapture(arguments: Map<*, *>?, result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            result.error(
                "SCREEN_CAPTURE_ANDROID_VERSION_UNSUPPORTED",
                "Screen capture requires Android 10 or newer.",
                null,
            )
            return
        }
        if (pendingImport != null || pendingStart != null || ScreenCaptureSessionRegistry.isActive()) {
            result.error(
                "SCREEN_CAPTURE_ALREADY_ACTIVE",
                "A screen capture is already active.",
                null,
            )
            return
        }
        val request = CaptureRequest.parse(arguments)?.oriented(
            activity.resources.configuration.orientation == Configuration.ORIENTATION_LANDSCAPE,
        )
        if (request == null) {
            result.error(
                "SCREEN_CAPTURE_REQUEST_INVALID",
                "Screen capture options are invalid.",
                null,
            )
            return
        }

        if (runCatching { ScreenCaptureSessionRegistry.markStarting(request.sessionId) }.isFailure) {
            result.error("SCREEN_CAPTURE_STORAGE_FAILED", "Previous capture must be retained first.", null)
            return
        }
        pendingStart = PendingStart(request, nextRequestCode(), nextRequestCode())
        result.success(ScreenCaptureSessionRegistry.snapshot())
        val timeout = Runnable { failPendingStart("SCREEN_CAPTURE_CONSENT_CANCELLED") }
        consentTimeout = timeout
        mainHandler.postDelayed(timeout, 60_000L)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M &&
            activity.checkSelfPermission(Manifest.permission.RECORD_AUDIO) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            runCatching {
                activity.requestPermissions(
                    arrayOf(Manifest.permission.RECORD_AUDIO),
                    checkNotNull(pendingStart).permissionCode,
                )
            }.onFailure {
                failPendingStart("SCREEN_CAPTURE_AUDIO_PERMISSION_FAILED")
            }
            return
        }
        launchConsentPicker()
    }

    private fun launchConsentPicker() {
        val pending = pendingStart ?: return
        runCatching {
            val manager = activity.getSystemService(MediaProjectionManager::class.java)
            activity.startActivityForResult(
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                    manager.createScreenCaptureIntent(MediaProjectionConfig.createConfigForDefaultDisplay())
                } else {
                    manager.createScreenCaptureIntent()
                },
                pending.projectionCode,
            )
        }.onFailure {
            failPendingStart("SCREEN_CAPTURE_PICKER_UNAVAILABLE")
        }
    }

    private fun stopCapture(arguments: Map<*, *>?, result: MethodChannel.Result) {
        val expected = arguments?.get("expectedSessionId") as? String
        if (expected != null && ScreenCaptureSessionRegistry.snapshot()["sessionId"] != expected) {
            result.error("SCREEN_CAPTURE_SESSION_MISMATCH", "Another screen capture owns this session.", null)
            return
        }
        if (!ScreenCaptureSessionRegistry.isActive()) {
            result.error(
                "SCREEN_CAPTURE_NOT_ACTIVE",
                "No screen capture is active.",
                null,
            )
            return
        }
        pendingStart?.let {
            pendingStart = null
            clearConsentTimeout()
            ScreenCaptureSessionRegistry.markFailed("SCREEN_CAPTURE_CONSENT_CANCELLED")
            result.success(ScreenCaptureSessionRegistry.snapshot())
            return
        }
        ScreenCaptureSessionRegistry.markStopping()
        runCatching { ScreenCaptureService.requestStop(activity) }.onFailure {
            result.error("SCREEN_CAPTURE_STOP_REQUEST_FAILED", "Screen capture could not be stopped.", null)
            return
        }
        result.success(ScreenCaptureSessionRegistry.snapshot())
    }

    private fun extractAudio(arguments: Map<*, *>?, result: MethodChannel.Result) {
        val appPrivateUri = arguments?.get("appPrivateUri") as? String
        if (appPrivateUri.isNullOrBlank()) {
            result.error("SCREEN_CAPTURE_AUDIO_REQUEST_INVALID", "Screen-capture media reference is invalid.", null)
            return
        }
        Thread({
            runCatching { ScreenCaptureService.extractAudio(activity, appPrivateUri) }
                .fold(
                    onSuccess = { payload -> mainHandler.post { result.success(payload) } },
                    onFailure = { error ->
                        val code = (error as? ScreenCaptureAudioExtractionException)?.code
                            ?: "SCREEN_CAPTURE_AUDIO_EXPORT_FAILED"
                        mainHandler.post {
                            result.error(code, "Audio could not be exported from the screen capture.", null)
                        }
                    },
                )
        }, "screen-capture-audio-export").start()
    }

    fun onRequestPermissionsResult(
        requestCode: Int,
        grantResults: IntArray,
    ): Boolean {
        if (requestCode !in 0x6000..0x7fff) return false
        if (pendingStart?.permissionCode != requestCode) return true
        if (grantResults.isNotEmpty() &&
            grantResults.all { it == PackageManager.PERMISSION_GRANTED }
        ) {
            launchConsentPicker()
        } else {
            failPendingStart("SCREEN_CAPTURE_AUDIO_PERMISSION_DENIED")
        }
        return true
    }

    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode !in 0x6000..0x7fff) return false
        pendingImport?.takeIf { it.requestCode == requestCode }?.let {
            finishImport(it, if (resultCode == Activity.RESULT_OK) data?.data else null)
            return true
        }
        val pending = pendingStart ?: return true
        if (pending.projectionCode != requestCode) return true
        pendingStart = null
        clearConsentTimeout()
        if (resultCode != Activity.RESULT_OK || data == null) {
            ScreenCaptureSessionRegistry.markFailed("SCREEN_CAPTURE_CONSENT_CANCELLED")
            return true
        }
        runCatching {
            ScreenCaptureService.start(
                context = activity,
                resultCode = resultCode,
                projectionData = data,
                request = pending.request,
            )
        }.onFailure {
                ScreenCaptureSessionRegistry.markFailed("SCREEN_CAPTURE_SERVICE_START_FAILED")
        }
        return true
    }

    private fun failPendingStart(code: String) {
        if (pendingStart == null) return
        pendingStart = null
        clearConsentTimeout()
        ScreenCaptureSessionRegistry.markFailed(code)
    }

    private fun clearConsentTimeout() {
        consentTimeout?.let(mainHandler::removeCallbacks)
        consentTimeout = null
    }

    private fun detach() {
        pendingImport?.result?.error("SCREEN_CAPTURE_IMPORT_INTERRUPTED", "Picker detached.", null)
        pendingImport?.result = null
        val pending = pendingStart
        clearConsentTimeout()
        if (pending != null) {
            ScreenCaptureSessionRegistry.markFailed("SCREEN_CAPTURE_ENGINE_DETACHED")
        }
        pendingStart = null
        ScreenCaptureSessionRegistry.removeListener(registryListener)
        methodChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
        eventSink = null
    }

    internal data class CaptureRequest(
        val maxDurationSeconds: Int,
        val maxSizeBytes: Long,
        val targetWidth: Int,
        val targetHeight: Int,
        val sessionId: String = UUID.randomUUID().toString(),
    ) {
        fun oriented(isLandscape: Boolean): CaptureRequest {
            val shortEdge = minOf(targetWidth, targetHeight)
            val longEdge = maxOf(targetWidth, targetHeight)
            return copy(
                targetWidth = if (isLandscape) longEdge else shortEdge,
                targetHeight = if (isLandscape) shortEdge else longEdge,
            )
        }

        companion object {
            fun parse(arguments: Map<*, *>?): CaptureRequest? {
                val duration = (arguments?.get("maxDurationSeconds") as? Number)?.toInt()
                    ?: DEFAULT_MAX_DURATION_SECONDS
                val size = (arguments?.get("maxSizeBytes") as? Number)?.toLong()
                    ?: DEFAULT_MAX_SIZE_BYTES
                val width = (arguments?.get("targetWidth") as? Number)?.toInt()
                    ?: DEFAULT_WIDTH
                val height = (arguments?.get("targetHeight") as? Number)?.toInt()
                    ?: DEFAULT_HEIGHT
                val sessionId = arguments?.get("sessionId") as? String ?: UUID.randomUUID().toString()
                if (!Regex("^[A-Za-z0-9_-]{1,100}$").matches(sessionId)) return null
                if (duration !in 1..DEFAULT_MAX_DURATION_SECONDS ||
                    size !in MIN_CAPTURE_SIZE_BYTES..DEFAULT_MAX_SIZE_BYTES ||
                    width !in 320..1920 || height !in 320..1920
                ) {
                    return null
                }
                return CaptureRequest(duration, size, width, height, sessionId)
            }
        }
    }

    private data class PendingStart(
        val request: CaptureRequest,
        val permissionCode: Int,
        val projectionCode: Int,
    )

    private data class PendingImport(val sessionId: String, val requestCode: Int,
        var result: MethodChannel.Result?, var copying: Boolean = false)

    companion object {
        const val DEFAULT_MAX_DURATION_SECONDS = 1800
        const val DEFAULT_MAX_SIZE_BYTES = 500L * 1024L * 1024L
        const val MIN_CAPTURE_SIZE_BYTES = 1024L * 1024L
        const val DEFAULT_WIDTH = 720
        const val DEFAULT_HEIGHT = 1280
        private const val METHOD_CHANNEL = "huahuoai/screen_capture"
        private const val EVENT_CHANNEL = "huahuoai/screen_capture/events"
        private var requestSequence = 0
        private var pendingImport: PendingImport? = null
        private fun nextRequestCode(): Int = 0x6000 + (requestSequence++ and 0x1fff)
        private var instance: ScreenCaptureAndroidBridge? = null

        fun register(activity: MainActivity, messenger: BinaryMessenger) {
            instance?.detach()
            instance = ScreenCaptureAndroidBridge(activity, messenger)
        }

        fun unregister() {
            instance?.detach()
            instance = null
        }

        fun onRequestPermissionsResult(
            requestCode: Int,
            grantResults: IntArray,
        ): Boolean = instance?.onRequestPermissionsResult(requestCode, grantResults) ?: false

        fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean =
            instance?.onActivityResult(requestCode, resultCode, data) ?: false
    }
}
