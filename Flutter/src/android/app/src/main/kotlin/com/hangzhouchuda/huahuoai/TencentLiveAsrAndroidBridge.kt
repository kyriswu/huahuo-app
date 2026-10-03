package com.hangzhouchuda.huahuoai

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.lang.reflect.InvocationHandler
import java.lang.reflect.Method
import java.lang.reflect.Proxy
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import org.json.JSONObject

private const val MAX_TENCENT_RECOGNITION_TEXT_LENGTH = 100_000
private const val MAX_TENCENT_RAW_RESPONSE_LENGTH = 1_000_000
private const val MAX_TENCENT_SENTENCE_EVENTS = 1_000
private const val TENCENT_LIVE_ASR_LOG_TAG = "HuahuoLiveAsr"

private val TENCENT_LIVE_ASR_DIAGNOSTIC_STAGES = setOf(
    "start_requested",
    "client_created",
    "pcm_attached",
    "recognition_start_invoked",
    "recognizer_ready",
    "ready_timeout",
    "sdk_unavailable",
    "pcm_unavailable",
    "start_failed",
    "recognition_failed",
    "recognition_completed",
    "stop_requested",
    "stop_completed",
    "stop_failed",
    "release_requested",
    "release_completed",
)

internal fun formatTencentLiveAsrDiagnostic(
    stage: String,
    cause: Throwable? = null,
): String {
    val safeStage = if (stage in TENCENT_LIVE_ASR_DIAGNOSTIC_STAGES) stage else "unknown"
    val causeType = when (cause) {
        null -> null
        is ClassNotFoundException -> "ClassNotFoundException"
        is NoSuchMethodException -> "NoSuchMethodException"
        is IllegalArgumentException -> "IllegalArgumentException"
        is IllegalStateException -> "IllegalStateException"
        is SecurityException -> "SecurityException"
        is java.lang.reflect.InvocationTargetException -> "InvocationTargetException"
        else -> "UnknownThrowable"
    }
    return buildString {
        append("[TencentLiveAsr] stage=")
        append(safeStage)
        if (causeType != null) {
            append(" cause=")
            append(causeType)
        }
    }
}

internal fun formatTencentLiveAsrFailureDiagnostic(
    clientCode: Int?,
    hasServerFailure: Boolean,
    providerCode: Int? = null,
): String = buildString {
    append("[TencentLiveAsr] stage=recognition_failed")
    if (clientCode != null) {
        append(" clientCode=")
        append(clientCode)
    }
    append(" serverFailure=")
    append(hasServerFailure)
    if (hasServerFailure && providerCode != null && providerCode > 0) {
        append(" providerCode=")
        append(providerCode)
    }
}

internal fun classifyTencentRecognitionFailure(
    clientCode: Int?,
    hasServerFailure: Boolean,
    providerCode: Int? = null,
): String = when (clientCode) {
    -102 -> "TENCENT_LIVE_ASR_MICROPHONE_BUSY"
    -100, -101, -103, -104 -> "TENCENT_LIVE_ASR_AUDIO_SOURCE_START_FAILED"
    -106, -108 -> "TENCENT_LIVE_ASR_NETWORK_FAILED"
    else -> if (hasServerFailure) {
        when (providerCode) {
            4001, 4010 -> "TENCENT_LIVE_ASR_PROVIDER_REQUEST_INVALID"
            4002 -> "TENCENT_LIVE_ASR_PROVIDER_AUTH_FAILED"
            4003 -> "TENCENT_LIVE_ASR_PROVIDER_NOT_ENABLED"
            4004 -> "TENCENT_LIVE_ASR_PROVIDER_QUOTA_EXHAUSTED"
            4005 -> "TENCENT_LIVE_ASR_PROVIDER_SUSPENDED"
            4006 -> "TENCENT_LIVE_ASR_PROVIDER_RATE_LIMITED"
            4007 -> "TENCENT_LIVE_ASR_PROVIDER_AUDIO_INVALID"
            4008 -> "TENCENT_LIVE_ASR_AUDIO_SOURCE_TIMEOUT"
            4009 -> "TENCENT_LIVE_ASR_NETWORK_FAILED"
            5000, 5001, 5002 -> "TENCENT_LIVE_ASR_PROVIDER_UNAVAILABLE"
            6001 -> "TENCENT_LIVE_ASR_PROVIDER_REGION_RESTRICTED"
            else -> "TENCENT_LIVE_ASR_PROVIDER_REJECTED"
        }
    } else {
        "TENCENT_LIVE_ASR_RECOGNITION_FAILED"
    }
}

internal fun parseTencentProviderFailureCode(rawResponse: Any?): Int? {
    val raw = rawResponse as? String ?: return null
    if (raw.isEmpty() || raw.length > MAX_TENCENT_RAW_RESPONSE_LENGTH) return null
    val envelope = runCatching { JSONObject(raw) }.getOrNull() ?: return null
    return strictJsonInt(envelope.opt("code"))?.takeIf { it > 0 }
}

internal fun isTencentRecognizerReadyCallback(methodName: String): Boolean =
    methodName == "onStartRecord"

internal fun parseTencentRawRecognitionEvent(rawResponse: Any?): Map<String, Any>? {
    val events = parseTencentRawRecognitionEvents(rawResponse)
    return events.singleOrNull()
}

internal fun parseTencentRawRecognitionEvents(
    rawResponse: Any?,
    acceptFinalEnvelope: Boolean = false,
): List<Map<String, Any>> {
    val raw = rawResponse as? String ?: return emptyList()
    if (raw.isEmpty() || raw.length > MAX_TENCENT_RAW_RESPONSE_LENGTH) return emptyList()
    val envelope = runCatching { JSONObject(raw) }.getOrNull() ?: return emptyList()
    if (!acceptFinalEnvelope && isTencentFinalEnvelope(envelope.opt("final"))) return emptyList()
    if (strictJsonInt(envelope.opt("code")) != 0) return emptyList()

    val separated = envelope.opt("sentences") as? JSONObject
    if (separated != null) return parseTencentSeparatedSentences(separated)

    val result = envelope.opt("result") as? JSONObject ?: return emptyList()
    val text = result.opt("voice_text_str") as? String ?: return emptyList()
    val sliceType = strictJsonInt(result.opt("slice_type")) ?: return emptyList()
    val sequence = strictJsonInt(result.opt("index")) ?: return emptyList()
    if (text.isBlank() || text.length > MAX_TENCENT_RECOGNITION_TEXT_LENGTH) return emptyList()
    if (sliceType !in 0..2 || sequence < 0) return emptyList()

    val event = mutableMapOf<String, Any>(
        "type" to if (sliceType == 2) "segment" else "partial",
        "sequence" to sequence,
        "text" to text,
    )
    for ((sourceKey, eventKey) in listOf("start_time" to "startMs", "end_time" to "endMs")) {
        if (!result.has(sourceKey) || result.isNull(sourceKey)) continue
        val time = strictJsonInt(result.opt(sourceKey)) ?: return emptyList()
        if (time < 0) return emptyList()
        event[eventKey] = time
    }
    return listOf(event)
}

internal fun parseTencentSuccessRecognitionEvents(
    rawResponse: Any?,
    acceptPlainText: Boolean = true,
): List<Map<String, Any>> {
    val parsed = parseTencentRawRecognitionEvents(
        rawResponse,
        acceptFinalEnvelope = true,
    )
    if (parsed.isNotEmpty() || !acceptPlainText) return parsed
    val text = (rawResponse as? String)?.trim() ?: return emptyList()
    if (
        text.isEmpty() ||
        text.length > MAX_TENCENT_RECOGNITION_TEXT_LENGTH ||
        text.startsWith("{") ||
        text.startsWith("[")
    ) return emptyList()
    return listOf(
        mapOf(
            "type" to "segment",
            "sequence" to 0,
            "text" to text,
        ),
    )
}

private fun parseTencentSeparatedSentences(sentences: JSONObject): List<Map<String, Any>> {
    val rawList = sentences.optJSONArray("sentence_list") ?: return emptyList()
    if (rawList.length() !in 1..MAX_TENCENT_SENTENCE_EVENTS) return emptyList()
    val events = ArrayList<Map<String, Any>>(rawList.length())
    for (index in 0 until rawList.length()) {
        val item = rawList.optJSONObject(index) ?: return emptyList()
        val text = item.opt("sentence") as? String ?: return emptyList()
        val sequence = strictJsonInt(item.opt("sentence_id")) ?: return emptyList()
        val sentenceType = strictJsonInt(item.opt("sentence_type")) ?: return emptyList()
        val speakerId = strictJsonInt(item.opt("speaker_id")) ?: return emptyList()
        if (text.isBlank() ||
            text.length > MAX_TENCENT_RECOGNITION_TEXT_LENGTH ||
            sequence < 0 ||
            sentenceType !in 0..1 ||
            speakerId !in -1..9
        ) return emptyList()
        events += mutableMapOf<String, Any>(
            "type" to if (sentenceType == 1) "segment" else "partial",
            "sequence" to sequence,
            "text" to text,
        ).also { event ->
            if (speakerId >= 0) event["speakerId"] = speakerId
        }
    }
    return events
}

private fun isTencentFinalEnvelope(value: Any?): Boolean =
    value == "1" || strictJsonInt(value) == 1

private fun strictJsonInt(value: Any?): Int? = when (value) {
    is Byte -> value.toInt()
    is Short -> value.toInt()
    is Int -> value
    is Long -> value
        .takeIf { it >= Int.MIN_VALUE.toLong() && it <= Int.MAX_VALUE.toLong() }
        ?.toInt()
    else -> null
}

internal fun findTencentTokenClientConstructor(
    clientClass: Class<*>,
    contextClass: Class<*> = Context::class.java,
): java.lang.reflect.Constructor<*>? {
    val expectedTypes = arrayOf(
        contextClass,
        Integer.TYPE,
        Integer.TYPE,
        String::class.java,
        String::class.java,
        String::class.java,
    )
    return clientClass.constructors.singleOrNull {
        it.parameterTypes.contentEquals(expectedTypes)
    }
}

/**
 * Owns one official Tencent realtime-ASR session. Tencent distributes the
 * Android AAR through its console, so reflection keeps ordinary builds working
 * when the authorized artifact has not been installed yet.
 */
internal class TencentLiveAsrAndroidBridge private constructor(
    private val activity: FlutterActivity,
    messenger: io.flutter.plugin.common.BinaryMessenger,
) : EventChannel.StreamHandler {
    private val mainHandler = Handler(Looper.getMainLooper())
    private val worker: ExecutorService = Executors.newSingleThreadExecutor()
    private val methodChannel = MethodChannel(messenger, METHOD_CHANNEL)
    private val eventChannel = EventChannel(messenger, EVENT_CHANNEL)
    private var eventSink: EventChannel.EventSink? = null
    private var pendingReady: PendingReady? = null
    @Volatile private var client: Any? = null
    @Volatile private var generation = 0
    private var recognitionEventGeneration: Int? = null

    init {
        methodChannel.setMethodCallHandler(::handleMethodCall)
        eventChannel.setStreamHandler(this)
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    fun dispose() {
        methodChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
        pendingReady?.timeout?.let(mainHandler::removeCallbacks)
        pendingReady?.result?.error(
            "TENCENT_LIVE_ASR_SESSION_SUPERSEDED",
            "Realtime ASR session was superseded.",
            null,
        )
        pendingReady = null
        releaseClient()
        worker.shutdown()
        activeBridge = null
    }

    @Suppress("UNUSED_PARAMETER")
    fun onRequestPermissionsResult(
        requestCode: Int,
        grantResults: IntArray,
    ): Boolean = false

    private fun handleMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "start" -> {
                val command = parseStartCommand(call.arguments as? Map<*, *>)
                if (command == null) {
                    result.error(
                        "TENCENT_LIVE_ASR_REQUEST_INVALID",
                        "Realtime ASR request is invalid.",
                        null,
                    )
                    return
                }
                if (client != null || pendingReady != null) {
                    result.error(
                        "TENCENT_LIVE_ASR_SESSION_BUSY",
                        "Realtime ASR session is already active.",
                        null,
                    )
                    return
                }
                start(command, result)
            }
            "stop" -> stop(result)
            "release" -> release(result)
            else -> result.notImplemented()
        }
    }

    private fun start(command: StartCommand, result: MethodChannel.Result) {
        val sessionGeneration = ++generation
        val timeout = Runnable {
            if (failPendingStart(
                    sessionGeneration,
                    "TENCENT_LIVE_ASR_START_TIMEOUT",
                    "Tencent realtime ASR did not become ready in time.",
                )
            ) {
                logDiagnostic("ready_timeout")
            }
        }
        pendingReady = PendingReady(sessionGeneration, result, timeout)
        mainHandler.postDelayed(timeout, START_READY_TIMEOUT_MS)
        logDiagnostic("start_requested")
        worker.execute {
            var initializedClient: Any? = null
            try {
                val activeClient = createClient(command)
                initializedClient = activeClient
                if (sessionGeneration != generation) {
                    releaseClientInstance(activeClient)
                    return@execute
                }
                client = activeClient
                if (sessionGeneration != generation) {
                    client = null
                    releaseClientInstance(activeClient)
                    return@execute
                }
                logDiagnostic("client_created")
                startRecognition(activeClient, sessionGeneration)
                if (sessionGeneration != generation) {
                    if (client === activeClient) client = null
                    releaseClientInstance(activeClient)
                    return@execute
                }
                logDiagnostic("recognition_start_invoked")
            } catch (error: ClassNotFoundException) {
                discardClientAfterFailedStart(initializedClient)
                logDiagnostic("sdk_unavailable", error)
                postPendingStartFailure(
                    sessionGeneration,
                    "TENCENT_LIVE_ASR_SDK_UNAVAILABLE",
                    "Tencent realtime ASR SDK is not installed.",
                )
            } catch (error: SharedPcmUnavailableException) {
                discardClientAfterFailedStart(initializedClient)
                logDiagnostic("pcm_unavailable", error)
                postPendingStartFailure(
                    sessionGeneration,
                    "TENCENT_LIVE_ASR_SHARED_PCM_UNAVAILABLE",
                    "Realtime recorder audio is unavailable.",
                )
            } catch (error: Throwable) {
                discardClientAfterFailedStart(initializedClient)
                logDiagnostic("start_failed", error)
                postPendingStartFailure(
                    sessionGeneration,
                    "TENCENT_LIVE_ASR_START_FAILED",
                    "Tencent realtime ASR could not start.",
                )
            }
        }
    }

    private fun completePendingStart(sessionGeneration: Int) {
        mainHandler.post {
            val pending = pendingReady
            if (
                pending == null ||
                pending.generation != sessionGeneration ||
                generation != sessionGeneration ||
                client == null
            ) return@post
            mainHandler.removeCallbacks(pending.timeout)
            pendingReady = null
            logDiagnostic("recognizer_ready")
            pending.result.success(null)
        }
    }

    private fun postPendingStartFailure(
        sessionGeneration: Int,
        code: String,
        message: String,
    ) {
        mainHandler.post { failPendingStart(sessionGeneration, code, message) }
    }

    private fun failPendingStart(
        sessionGeneration: Int,
        code: String,
        message: String,
    ): Boolean {
        val pending = pendingReady
        if (pending == null || pending.generation != sessionGeneration) return false
        mainHandler.removeCallbacks(pending.timeout)
        pendingReady = null
        if (generation == sessionGeneration) generation += 1
        worker.execute {
            val activeClient = client
            client = null
            releaseClientInstance(activeClient)
            VoiceRecorderAndroidBridge.detachTencentPcmDataSource()
        }
        pending.result.error(code, message, null)
        return true
    }

    private fun handleRecognitionFailure(
        sessionGeneration: Int,
        code: String,
    ) {
        mainHandler.post {
            if (
                failPendingStart(
                    sessionGeneration,
                    code,
                    "Tencent realtime ASR could not become ready.",
                )
            ) return@post
            emit(mapOf("type" to "error", "code" to code), sessionGeneration)
        }
    }

    private fun stop(result: MethodChannel.Result) {
        val pending = pendingReady
        if (pending != null) {
            failPendingStart(
                pending.generation,
                "TENCENT_LIVE_ASR_SESSION_SUPERSEDED",
                "Realtime ASR startup was stopped.",
            )
            logDiagnostic("stop_completed")
            result.success(null)
            return
        }
        val activeClient = client
        if (activeClient == null) {
            result.success(null)
            return
        }
        logDiagnostic("stop_requested")
        worker.execute {
            try {
                invokeNoArg(activeClient, "stopAudioRecognize")
                logDiagnostic("stop_completed")
                mainHandler.post { result.success(null) }
            } catch (error: Throwable) {
                logDiagnostic("stop_failed", error)
                mainHandler.post {
                    result.error(
                        "TENCENT_LIVE_ASR_STOP_FAILED",
                        "Tencent realtime ASR could not stop.",
                        null,
                    )
                }
            }
        }
    }

    private fun release(result: MethodChannel.Result) {
        pendingReady?.let { pending ->
            failPendingStart(
                pending.generation,
                "TENCENT_LIVE_ASR_SESSION_SUPERSEDED",
                "Realtime ASR startup was released.",
            )
        }
        val activeClient = client
        client = null
        generation += 1
        logDiagnostic("release_requested")
        if (activeClient == null) {
            VoiceRecorderAndroidBridge.detachTencentPcmDataSource()
            logDiagnostic("release_completed")
            result.success(null)
            return
        }
        worker.execute {
            runCatching { invokeNoArg(activeClient, "cancelAudioRecognize") }
            runCatching { invokeNoArg(activeClient, "release") }
            VoiceRecorderAndroidBridge.detachTencentPcmDataSource()
            logDiagnostic("release_completed")
            mainHandler.post { result.success(null) }
        }
    }

    private fun releaseClient() {
        val activeClient = client
        client = null
        generation += 1
        worker.execute {
            releaseClientInstance(activeClient)
            VoiceRecorderAndroidBridge.detachTencentPcmDataSource()
        }
    }

    private fun createClient(command: StartCommand): Any {
        val configurationClass = Class.forName("com.tencent.aai.config.ClientConfiguration")
        configurationClass.getMethod(
            "setAudioRecognizeConnectTimeout",
            java.lang.Integer.TYPE,
        ).invoke(null, PROVIDER_CONNECT_TIMEOUT_MS)
        val clientClass = Class.forName("com.tencent.aai.AAIClient")
        val constructor = findTencentTokenClientConstructor(clientClass)
            ?: throw IllegalStateException("Tencent client constructor unavailable")
        return constructor.newInstance(
            activity.applicationContext,
            command.appId,
            command.projectId,
            command.tmpSecretId,
            command.tmpSecretKey,
            command.token,
        )
    }

    private fun startRecognition(activeClient: Any, sessionGeneration: Int) {
        val requestBuilderClass = Class.forName("com.tencent.aai.model.AudioRecognizeRequest\$Builder")
        val requestBuilder = requestBuilderClass.getConstructor().newInstance()
        val dataSource = VoiceRecorderAndroidBridge.createTencentPcmDataSource()
            ?: throw SharedPcmUnavailableException()
        invokeOneArg(requestBuilder, "pcmAudioDataSource", dataSource)
        logDiagnostic("pcm_attached")
        invokeOptionalOneArg(requestBuilder, "setEngineModelType", "16k_zh")
        invokeOptionalOneArg(requestBuilder, "setNeedvad", 1)
        val request = invokeNoArg(requestBuilder, "build")

        val resultListener = listenerProxy(
            "com.tencent.aai.listener.AudioRecognizeResultListener",
            sessionGeneration,
        )
        val stateListener = listenerProxy(
            "com.tencent.aai.listener.AudioRecognizeStateListener",
            sessionGeneration,
        )
        val configurationBuilderClass =
            Class.forName("com.tencent.aai.model.AudioRecognizeConfiguration\$Builder")
        val configurationBuilder = configurationBuilderClass.getConstructor().newInstance()
        invokeOptionalOneArg(configurationBuilder, "setSilentDetectTimeOut", false)
        val configuration = invokeNoArg(configurationBuilder, "build")

        val method = activeClient.javaClass.methods.firstOrNull {
            it.name == "startAudioRecognize" && it.parameterTypes.size == 4
        } ?: throw IllegalStateException("Tencent start method unavailable")
        method.invoke(activeClient, request, resultListener, stateListener, configuration)
    }

    private fun listenerProxy(interfaceName: String, sessionGeneration: Int): Any {
        val listenerClass = Class.forName(interfaceName)
        var providerCode: Int? = null
        return Proxy.newProxyInstance(
            listenerClass.classLoader,
            arrayOf(listenerClass),
            InvocationHandler { _, method, args ->
                if (isTencentRecognizerReadyCallback(method.name)) {
                    completePendingStart(sessionGeneration)
                }
                when (method.name) {
                    "onSliceSuccess" -> emitRecognitionResult(args?.getOrNull(1), false, sessionGeneration)
                    "onSegmentSuccess" -> emitRecognitionResult(args?.getOrNull(1), true, sessionGeneration)
                    "onRawResponse" -> {
                        val rawResponse = args?.getOrNull(1)
                        providerCode = parseTencentProviderFailureCode(rawResponse)
                        if (providerCode == null) {
                            parseTencentRawRecognitionEvents(rawResponse)
                                .forEach { emit(it, sessionGeneration) }
                        }
                    }
                    "onSuccess" -> {
                        parseTencentSuccessRecognitionEvents(
                            args?.getOrNull(1),
                            acceptPlainText = recognitionEventGeneration != sessionGeneration,
                        ).forEach { emit(it, sessionGeneration) }
                        logDiagnostic("recognition_completed")
                        emit(mapOf("type" to "completed"), sessionGeneration)
                    }
                    "onFailure" -> {
                        val clientCode = tencentClientExceptionCode(args?.getOrNull(1))
                        val hasServerFailure = args?.getOrNull(2) != null
                        val failureCode = classifyTencentRecognitionFailure(
                            clientCode,
                            hasServerFailure,
                            providerCode,
                        )
                        Log.i(
                            TENCENT_LIVE_ASR_LOG_TAG,
                            formatTencentLiveAsrFailureDiagnostic(
                                clientCode,
                                hasServerFailure,
                                providerCode,
                            ),
                        )
                        handleRecognitionFailure(sessionGeneration, failureCode)
                    }
                }
                null
            },
        )
    }

    private fun emitRecognitionResult(rawResult: Any?, stable: Boolean, sessionGeneration: Int) {
        val text = invokeOptionalNoArg(rawResult, "getText") as? String ?: return
        val sequence = (invokeOptionalNoArg(rawResult, "getSeq") as? Number)?.toInt() ?: return
        if (
            text.isBlank() ||
            text.length > MAX_TENCENT_RECOGNITION_TEXT_LENGTH ||
            sequence < 0
        ) return
        val event = mutableMapOf<String, Any>(
            "type" to if (stable) "segment" else "partial",
            "sequence" to sequence,
            "text" to text,
        )
        (invokeOptionalNoArg(rawResult, "getStartTime") as? Number)?.toInt()
            ?.takeIf { it >= 0 }
            ?.let { event["startMs"] = it }
        (invokeOptionalNoArg(rawResult, "getEndTime") as? Number)?.toInt()
            ?.takeIf { it >= 0 }
            ?.let { event["endMs"] = it }
        emit(event, sessionGeneration)
    }

    private fun emit(event: Map<String, Any>, sessionGeneration: Int) {
        if (sessionGeneration != generation || client == null) return
        if (event["type"] == "partial" || event["type"] == "segment") {
            recognitionEventGeneration = sessionGeneration
        }
        mainHandler.post {
            if (sessionGeneration == generation && client != null) {
                eventSink?.success(event)
            }
        }
    }

    private fun invokeNoArg(target: Any, name: String): Any? {
        val method = target.javaClass.methods.firstOrNull {
            it.name == name && it.parameterTypes.isEmpty()
        } ?: throw IllegalStateException("Tencent method unavailable")
        return method.invoke(target)
    }

    private fun invokeOptionalNoArg(target: Any?, name: String): Any? {
        target ?: return null
        return runCatching { invokeNoArg(target, name) }.getOrNull()
    }

    private fun tencentClientExceptionCode(value: Any?): Int? =
        (invokeOptionalNoArg(value, "getCode") as? Number)?.toInt()

    private fun invokeOneArg(target: Any, name: String, argument: Any) {
        val method = target.javaClass.methods.firstOrNull {
            it.name == name && it.parameterTypes.size == 1
        } ?: throw IllegalStateException("Tencent method unavailable")
        method.invoke(target, argument)
    }

    private fun invokeOptionalOneArg(target: Any, name: String, argument: Any) {
        target.javaClass.methods.firstOrNull {
            it.name == name && it.parameterTypes.size == 1
        }?.invoke(target, argument)
    }

    private fun discardClientAfterFailedStart(initializedClient: Any?) {
        if (client === initializedClient) client = null
        releaseClientInstance(initializedClient)
        VoiceRecorderAndroidBridge.detachTencentPcmDataSource()
    }

    private fun releaseClientInstance(activeClient: Any?) {
        runCatching { activeClient?.let { invokeNoArg(it, "cancelAudioRecognize") } }
        runCatching { activeClient?.let { invokeNoArg(it, "release") } }
    }

    private fun logDiagnostic(stage: String, cause: Throwable? = null) {
        Log.i(TENCENT_LIVE_ASR_LOG_TAG, formatTencentLiveAsrDiagnostic(stage, cause))
    }

    private fun parseStartCommand(raw: Map<*, *>?): StartCommand? {
        val sessionId = raw?.get("sessionId") as? String ?: return null
        val appId = raw["appId"] as? Int ?: return null
        val projectId = raw["projectId"] as? Int ?: return null
        val tmpSecretId = raw["tmpSecretId"] as? String ?: return null
        val tmpSecretKey = raw["tmpSecretKey"] as? String ?: return null
        val token = raw["token"] as? String ?: return null
        if (!safeOpaqueId(sessionId) ||
            appId <= 0 ||
            projectId < 0 ||
            !safeCredentialPart(tmpSecretId) ||
            !safeCredentialPart(tmpSecretKey) ||
            !safeCredentialPart(token)
        ) {
            return null
        }
        return StartCommand(sessionId, appId, projectId, tmpSecretId, tmpSecretKey, token)
    }

    private fun safeOpaqueId(value: String): Boolean =
        value.length in 3..128 && value.matches(Regex("^[A-Za-z0-9][A-Za-z0-9_-]{2,127}$"))

    private fun safeCredentialPart(value: String): Boolean =
        value.length in 1..8192 && value.none { it.code < 0x21 || it.code == 0x7f }

    private data class StartCommand(
        val sessionId: String,
        val appId: Int,
        val projectId: Int,
        val tmpSecretId: String,
        val tmpSecretKey: String,
        val token: String,
    )

    private data class PendingReady(
        val generation: Int,
        val result: MethodChannel.Result,
        val timeout: Runnable,
    )

    companion object {
        private const val METHOD_CHANNEL = "huahuoai/tencent_live_asr"
        private const val EVENT_CHANNEL = "huahuoai/tencent_live_asr/events"
        private const val PROVIDER_CONNECT_TIMEOUT_MS = 10_000
        private const val START_READY_TIMEOUT_MS = 15_000L
        private var activeBridge: TencentLiveAsrAndroidBridge? = null

        fun register(
            activity: FlutterActivity,
            messenger: io.flutter.plugin.common.BinaryMessenger,
        ) {
            activeBridge?.dispose()
            activeBridge = TencentLiveAsrAndroidBridge(activity, messenger)
        }

        fun unregister() {
            activeBridge?.dispose()
            activeBridge = null
        }

        fun onRequestPermissionsResult(requestCode: Int, grantResults: IntArray): Boolean =
            activeBridge?.onRequestPermissionsResult(requestCode, grantResults) ?: false
    }
}

private class SharedPcmUnavailableException : IllegalStateException()
