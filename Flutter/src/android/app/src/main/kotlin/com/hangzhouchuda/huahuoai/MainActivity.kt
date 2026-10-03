package com.hangzhouchuda.huahuoai

import android.Manifest
import android.app.Activity
import android.bluetooth.BluetoothAdapter
import android.content.ClipData
import android.content.ContentValues
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.OpenableColumns
import android.provider.MediaStore
import android.provider.Settings
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.EventChannel
import java.io.File
import java.io.FileOutputStream
import java.security.MessageDigest
import java.util.TimeZone
import java.util.UUID
import org.json.JSONObject

class MainActivity : FlutterActivity() {
    private var permissionsChannel: MethodChannel? = null
    private var deviceTimeZoneChannel: MethodChannel? = null
    private var nativeFileChannel: MethodChannel? = null
    private var knowledgeExportChannel: MethodChannel? = null
    private var runtimePerformanceBridge: RuntimePerformanceBridge? = null
    private var recordingCardBridge: RecordingCardAndroidBridge? = null
    private var incomingMaterialEventChannel: EventChannel? = null
    private var incomingMaterialEventSink: EventChannel.EventSink? = null
    private val pendingIncomingMaterials = mutableListOf<Map<String, Any>>()
    private val pendingIncomingMaterialErrors = mutableListOf<String>()
    private val mainHandler = Handler(Looper.getMainLooper())
    private var pendingBluetoothPermissionResult: MethodChannel.Result? = null
    private var pendingBluetoothActivationResult: MethodChannel.Result? = null
    private var bluetoothPermissionTimeout: Runnable? = null
    private var pendingLocalNetworkPermissionResult: MethodChannel.Result? = null
    private var localNetworkPermissionTimeout: Runnable? = null
    private var pendingNotificationPermissionResult: MethodChannel.Result? = null
    private var notificationPermissionTimeout: Runnable? = null
    private var pendingGeneralPermissionResult: MethodChannel.Result? = null
    private var pendingGeneralPermissionKind: String? = null
    private var generalPermissionTimeout: Runnable? = null
    private var pendingDocumentPickerResult: MethodChannel.Result? = null
    private var pendingAudioPickerResult: MethodChannel.Result? = null
    private var pendingMediaPicker: PendingMediaPicker? = null
    private var pendingRecordingExportSave: PendingRecordingExportSave? = null
    private var pendingImageGallerySave: PendingImageGallerySave? = null
    private val recordingCardBluetoothAccess by lazy {
        RecordingCardBluetoothAccess(this)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        HuahuoNotificationChannels.create(this)
        super.configureFlutterEngine(flutterEngine)
        restoreIncomingMaterials()
        permissionsChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            PERMISSIONS_CHANNEL,
        ).also { channel ->
            channel.setMethodCallHandler(::handlePermissionCall)
        }
        deviceTimeZoneChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            DEVICE_TIME_ZONE_CHANNEL,
        ).also { channel ->
            channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "getTimeZone" -> result.success(TimeZone.getDefault().id)
                    else -> result.notImplemented()
                }
            }
        }
        nativeFileChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            NATIVE_FILE_CHANNEL,
        ).also { channel ->
            channel.setMethodCallHandler(::handleNativeFileCall)
        }
        incomingMaterialEventChannel = EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            INCOMING_MATERIAL_EVENT_CHANNEL,
        ).also { channel ->
            channel.setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    incomingMaterialEventSink = events
                    if (pendingIncomingMaterials.isNotEmpty() ||
                        pendingIncomingMaterialErrors.isNotEmpty()
                    ) {
                        events?.success("pending")
                    }
                }

                override fun onCancel(arguments: Any?) {
                    incomingMaterialEventSink = null
                }
            })
        }
        knowledgeExportChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            KNOWLEDGE_EXPORT_CHANNEL,
        ).also { channel ->
            channel.setMethodCallHandler(::handleKnowledgeExportCall)
        }
        runtimePerformanceBridge = RuntimePerformanceBridge(
            context = this,
            messenger = flutterEngine.dartExecutor.binaryMessenger,
        )
        recordingCardBridge?.unregister()
        recordingCardBridge = RecordingCardAndroidBridge.register(
            activity = this,
            messenger = flutterEngine.dartExecutor.binaryMessenger,
        )
        VoiceRecorderAndroidBridge.register(
            activity = this,
            messenger = flutterEngine.dartExecutor.binaryMessenger,
        )
        TencentLiveAsrAndroidBridge.register(
            activity = this,
            messenger = flutterEngine.dartExecutor.binaryMessenger,
        )
        ScreenCaptureAndroidBridge.register(
            activity = this,
            messenger = flutterEngine.dartExecutor.binaryMessenger,
        )
        HomeWidgetBridge.register(
            context = this,
            messenger = flutterEngine.dartExecutor.binaryMessenger,
        )
        PaymentBridge.register(
            activity = this,
            messenger = flutterEngine.dartExecutor.binaryMessenger,
        )
        acceptIncomingMaterialIntent(intent)
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        RecordingCardSyncService.stopForDetachedRuntime(this)
        recordingCardBridge?.unregister()
        recordingCardBridge = null
        HomeWidgetBridge.unregister()
        PaymentBridge.unregister()
        ScreenCaptureAndroidBridge.unregister()
        TencentLiveAsrAndroidBridge.unregister()
        VoiceRecorderAndroidBridge.unregister()
        cancelBluetoothPermissionRequest()
        pendingBluetoothActivationResult?.error(
            "PLATFORM_BLUETOOTH_ACTIVATION_CANCELLED",
            "Bluetooth activation was cancelled because the activity detached.",
            null,
        )
        pendingBluetoothActivationResult = null
        cancelLocalNetworkPermissionRequest()
        cancelNotificationPermissionRequest()
        cancelGeneralPermissionRequest()
        cancelAudioPickerRequest()
        cancelDocumentPickerRequest()
        cancelMediaPickerRequest()
        cancelRecordingExportSaveRequest()
        cancelImageGallerySaveRequest()
        permissionsChannel?.setMethodCallHandler(null)
        permissionsChannel = null
        deviceTimeZoneChannel?.setMethodCallHandler(null)
        deviceTimeZoneChannel = null
        nativeFileChannel?.setMethodCallHandler(null)
        nativeFileChannel = null
        incomingMaterialEventChannel?.setStreamHandler(null)
        incomingMaterialEventChannel = null
        incomingMaterialEventSink = null
        knowledgeExportChannel?.setMethodCallHandler(null)
        knowledgeExportChannel = null
        runtimePerformanceBridge?.unregister()
        runtimePerformanceBridge = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        acceptIncomingMaterialIntent(intent)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        if (ScreenCaptureAndroidBridge.onRequestPermissionsResult(requestCode, grantResults)) {
            return
        }
        if (VoiceRecorderAndroidBridge.onRequestPermissionsResult(
                requestCode,
                permissions,
                grantResults,
            )
        ) {
            return
        }
        if (TencentLiveAsrAndroidBridge.onRequestPermissionsResult(requestCode, grantResults)) {
            return
        }
        if (requestCode == RECORDING_CARD_BLUETOOTH_PERMISSION_REQUEST_CODE) {
            completeBluetoothPermissionRequest()
            return
        }
        if (requestCode == RECORDING_CARD_WIFI_PERMISSION_REQUEST_CODE) {
            completeLocalNetworkPermissionRequest()
            return
        }
        if (requestCode == NOTIFICATION_PERMISSION_REQUEST_CODE) {
            completeNotificationPermissionRequest()
            return
        }
        if (requestCode == GENERAL_PERMISSION_REQUEST_CODE) {
            completeGeneralPermissionRequest()
            return
        }
        if (requestCode == CAMERA_MEDIA_PERMISSION_REQUEST_CODE) {
            completeCameraMediaPermissionRequest()
            return
        }
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
    }

    override fun onActivityResult(
        requestCode: Int,
        resultCode: Int,
        data: Intent?,
    ) {
        if (ScreenCaptureAndroidBridge.onActivityResult(requestCode, resultCode, data)) {
            return
        }
        if (requestCode == DOCUMENT_PICKER_REQUEST_CODE) {
            completeDocumentPickerRequest(resultCode, data)
            return
        }
        if (requestCode == AUDIO_PICKER_REQUEST_CODE) {
            completeAudioPickerRequest(resultCode, data)
            return
        }
        if (requestCode == MEDIA_GALLERY_PICKER_REQUEST_CODE) {
            completeMediaGalleryPickerRequest(resultCode, data)
            return
        }
        if (requestCode == MEDIA_CAMERA_PICKER_REQUEST_CODE) {
            completeMediaCameraPickerRequest(resultCode)
            return
        }
        if (requestCode == RECORDING_EXPORT_SAVE_REQUEST_CODE) {
            completeRecordingExportSaveRequest(resultCode, data)
            return
        }
        if (requestCode == BLUETOOTH_ACTIVATION_REQUEST_CODE) {
            val pending = pendingBluetoothActivationResult
            pendingBluetoothActivationResult = null
            val enabled = runCatching {
                recordingCardBluetoothAccess.adapter?.isEnabled == true
            }.getOrDefault(false)
            pending?.success(
                if (enabled || resultCode == Activity.RESULT_OK) "enabled" else "cancelled",
            )
            return
        }
        super.onActivityResult(requestCode, resultCode, data)
    }

    private fun handlePermissionCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "getPermissionStatuses" -> result.success(permissionStatuses())
            "isJPushConfigured" -> result.success(
                isJPushConfigured(call.arguments as? Map<*, *>),
            )
            "requestPermissions" -> requestPlatformPermissions(
                call.arguments as? Map<*, *>,
                result,
            )
            "requestBluetoothActivation" -> requestBluetoothActivation(result)
            "openBluetoothSettings" -> result.success(
                openBluetoothSettings(call.arguments as? Map<*, *>),
            )
            "openAppSettings" -> result.success(openAppSettings())
            else -> result.notImplemented()
        }
    }

    private fun isJPushConfigured(arguments: Map<*, *>?): Boolean {
        val expectedAppKey = (arguments?.get("appKey") as? String)?.trim().orEmpty()
        if (!expectedAppKey.matches(Regex("^[A-Za-z0-9_-]{8,128}$"))) return false
        return runCatching {
            val metadata = packageManager
                .getApplicationInfo(packageName, PackageManager.GET_META_DATA)
                .metaData
            val manifestAppKey = metadata?.get("JPUSH_APPKEY")?.toString()?.trim()
            manifestAppKey == expectedAppKey
        }.getOrDefault(false)
    }

    private fun handleNativeFileCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "consumeIncomingMaterials" -> consumeIncomingMaterials(result)
            "consumeIncomingMaterialErrors" -> consumeIncomingMaterialErrors(result)
            "acknowledgeIncomingMaterials" -> acknowledgeIncomingMaterials(
                call.arguments as? Map<*, *>,
                result,
            )
            "setRecordingCardAutoSyncBackgroundEnabled" -> {
                val arguments = call.arguments as? Map<*, *>
                val legacyEnabled = arguments?.get("enabled") as? Boolean
                val keepAlive = if (arguments?.containsKey("keepAlive") == true) {
                    arguments["keepAlive"] as? Boolean
                } else {
                    legacyEnabled
                }
                val transferActive = if (arguments?.containsKey("transferActive") == true) {
                    arguments["transferActive"] as? Boolean
                } else {
                    false
                }
                val transportValue = arguments?.get("transport")
                val transportWire = transportValue as? String
                val transport = RecordingCardSyncTransport.fromWire(transportWire)
                val invalid = keepAlive == null ||
                    transferActive == null ||
                    (transportValue != null && transportWire == null) ||
                    !RecordingCardSyncTransport.isValidWire(transportWire) ||
                    (transferActive && transport == null) ||
                    (!transferActive && transport != null)
                if (invalid) {
                    result.error(
                        "RECORDING_CARD_AUTO_SYNC_BACKGROUND_INVALID",
                        "Background recording-card execution state is invalid.",
                        null,
                    )
                } else {
                    runCatching {
                        RecordingCardSyncService.setExecutionState(
                            context = this,
                            keepAlive = keepAlive,
                            transferActive = transferActive,
                            transport = transport,
                        )
                    }
                        .fold(
                            onSuccess = result::success,
                            onFailure = {
                                result.error(
                                    "RECORDING_CARD_AUTO_SYNC_BACKGROUND_FAILED",
                                    "Background auto-sync service could not be updated.",
                                    null,
                                )
                            },
                        )
                }
            }
            "pickAudioFiles" -> pickAudioFiles(result)
            "pickDocumentFiles" -> pickDocumentFiles(result)
            "pickMediaFiles" -> pickMediaFiles(call.arguments as? Map<*, *>, result)
            "saveImageToGallery" -> saveImageToGallery(
                call.arguments as? Map<*, *>,
                result,
            )
            "savePreparedAudioExport" -> savePreparedAudioExport(
                call.arguments as? Map<*, *>,
                result,
            )
            "openPreparedAudioExport" -> openPreparedAudioExport(
                call.arguments as? Map<*, *>,
                result,
            )
            else -> result.notImplemented()
        }
    }

    private fun handleKnowledgeExportCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "shareKnowledgeText" -> shareKnowledgeText(
                call.arguments as? Map<*, *>,
                result,
            )
            "openPreparedKnowledgeExport" -> openPreparedKnowledgeExport(
                call.arguments as? Map<*, *>,
                result,
            )
            "sharePreparedKnowledgeExport" -> openPreparedKnowledgeExport(
                call.arguments as? Map<*, *>,
                result,
                share = true,
            )
            else -> result.notImplemented()
        }
    }

    private fun shareKnowledgeText(
        arguments: Map<*, *>?,
        result: MethodChannel.Result,
    ) {
        val text = arguments?.get("text") as? String
        if (!KnowledgeExportContract.isSafeShareText(text)) {
            result.error(
                "NATIVE_KNOWLEDGE_SHARE_INVALID",
                "Knowledge share content is invalid.",
                null,
            )
            return
        }
        try {
            val intent = Intent(Intent.ACTION_SEND).apply {
                type = "text/plain"
                putExtra(Intent.EXTRA_TEXT, text)
            }
            startActivity(Intent.createChooser(intent, "分享知识"))
            result.success(true)
        } catch (_: RuntimeException) {
            result.error(
                "NATIVE_KNOWLEDGE_SHARE_FAILED",
                "No application could share this knowledge.",
                null,
            )
        }
    }

    private fun openPreparedKnowledgeExport(
        arguments: Map<*, *>?,
        result: MethodChannel.Result,
        share: Boolean = false,
    ) {
        val requestedDisplayName = arguments?.get("displayName") as? String
        val location = KnowledgeExportContract.resolve(
            arguments?.get("opaqueExportRef") as? String,
        )
        if (location == null ||
            (arguments?.get("mimeType") as? String) != location.mimeType ||
            !KnowledgeExportContract.isValidDisplayName(
                requestedDisplayName,
                location,
            )
        ) {
            result.error(
                "NATIVE_KNOWLEDGE_EXPORT_INVALID",
                "Prepared knowledge export metadata is invalid.",
                null,
            )
            return
        }
        val source = KnowledgeExportContract.resolveSourceFile(cacheDir, location)
        val sourceFile = source.sourceFile
        if (sourceFile == null) {
            val code = when (source.error) {
                KnowledgeExportSourceError.UNSAFE ->
                    "NATIVE_KNOWLEDGE_EXPORT_SOURCE_UNSAFE"
                KnowledgeExportSourceError.MISSING ->
                    "NATIVE_KNOWLEDGE_EXPORT_SOURCE_MISSING"
                KnowledgeExportSourceError.EMPTY ->
                    "NATIVE_KNOWLEDGE_EXPORT_SOURCE_EMPTY"
                KnowledgeExportSourceError.UNAVAILABLE, null ->
                    "NATIVE_KNOWLEDGE_EXPORT_SOURCE_UNAVAILABLE"
            }
            result.error(code, "Prepared knowledge export is unavailable.", null)
            return
        }
        try {
            val contentUri = FileProvider.getUriForFile(
                this,
                "$packageName.fileprovider",
                sourceFile,
                checkNotNull(requestedDisplayName),
            )
            val openIntent = if (share || location.mimeType == "application/zip") {
                Intent(Intent.ACTION_SEND).apply {
                    type = location.mimeType
                    putExtra(Intent.EXTRA_STREAM, contentUri)
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    clipData = ClipData.newRawUri("knowledge-export", contentUri)
                }
            } else {
                Intent(Intent.ACTION_VIEW).apply {
                    setDataAndType(contentUri, location.mimeType)
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    clipData = ClipData.newRawUri("knowledge-export", contentUri)
                }
            }
            val chooser = Intent.createChooser(
                openIntent,
                if (share) "分享文件" else "保存或打开",
            ).apply {
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                clipData = openIntent.clipData
            }
            startActivity(chooser)
            result.success(true)
        } catch (_: RuntimeException) {
            result.error(
                "NATIVE_KNOWLEDGE_EXPORT_OPEN_FAILED",
                "No application could open this knowledge document.",
                null,
            )
        }
    }

    private fun savePreparedAudioExport(
        arguments: Map<*, *>?,
        result: MethodChannel.Result,
    ) {
        if (hasPendingNativeFileInteraction()) {
            result.error(
                "NATIVE_AUDIO_EXPORT_SAVE_BUSY",
                "Another native file interaction is already active.",
                null,
            )
            return
        }
        val prepared = try {
            resolvePreparedRecordingExport(arguments)
        } catch (error: RecordingExportException) {
            result.error(error.code, error.safeMessage, null)
            return
        }
        val pending = PendingRecordingExportSave(
            result = result,
            location = prepared.location,
            displayName = prepared.displayName,
        )
        pendingRecordingExportSave = pending
        try {
            val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                addCategory(Intent.CATEGORY_OPENABLE)
                type = prepared.location.mimeType
                putExtra(Intent.EXTRA_TITLE, prepared.displayName)
                addFlags(
                    Intent.FLAG_GRANT_READ_URI_PERMISSION or
                        Intent.FLAG_GRANT_WRITE_URI_PERMISSION,
                )
            }
            startActivityForResult(intent, RECORDING_EXPORT_SAVE_REQUEST_CODE)
        } catch (_: RuntimeException) {
            if (pendingRecordingExportSave === pending) {
                pendingRecordingExportSave = null
                result.error(
                    "NATIVE_AUDIO_EXPORT_SAVE_PICKER_FAILED",
                    "The recording save destination picker could not be opened.",
                    null,
                )
            }
        }
    }

    private fun completeRecordingExportSaveRequest(resultCode: Int, data: Intent?) {
        val pending = pendingRecordingExportSave ?: return
        if (resultCode != RESULT_OK) {
            pendingRecordingExportSave = null
            pending.result.success(false)
            return
        }
        val destination = data?.data
        if (destination == null) {
            pendingRecordingExportSave = null
            pending.result.error(
                "NATIVE_AUDIO_EXPORT_SAVE_DESTINATION_MISSING",
                "The recording save destination is unavailable.",
                null,
            )
            return
        }
        val prepared = try {
            resolvePreparedRecordingExport(pending.location, pending.displayName)
        } catch (error: RecordingExportException) {
            pendingRecordingExportSave = null
            pending.result.error(error.code, error.safeMessage, null)
            return
        }

        Thread(
            {
                val saved = runCatching {
                    val expectedBytes = prepared.sourceFile.length()
                    val copiedBytes = prepared.sourceFile.inputStream().buffered().use { input ->
                        val stream = checkNotNull(
                            contentResolver.openOutputStream(destination, "w"),
                        ) { "Destination stream unavailable" }
                        stream.buffered().use { output ->
                            val copied = input.copyTo(output)
                            output.flush()
                            copied
                        }
                    }
                    check(copiedBytes == expectedBytes) { "Recording export length mismatch" }
                }
                if (saved.isFailure) {
                    runCatching { contentResolver.delete(destination, null, null) }
                }
                runOnUiThread {
                    if (pendingRecordingExportSave !== pending) return@runOnUiThread
                    pendingRecordingExportSave = null
                    saved.fold(
                        onSuccess = { pending.result.success(true) },
                        onFailure = {
                            pending.result.error(
                                "NATIVE_AUDIO_EXPORT_SAVE_FAILED",
                                "The recording could not be saved to the selected destination.",
                                null,
                            )
                        },
                    )
                }
            },
            "huahuo-recording-export-save",
        ).start()
    }

    private fun openPreparedAudioExport(
        arguments: Map<*, *>?,
        result: MethodChannel.Result,
    ) {
        if (hasPendingNativeFileInteraction()) {
            result.error(
                "NATIVE_AUDIO_EXPORT_OPEN_BUSY",
                "Another native file interaction is already active.",
                null,
            )
            return
        }
        val prepared = try {
            resolvePreparedRecordingExport(arguments)
        } catch (error: RecordingExportException) {
            result.error(error.code, error.safeMessage, null)
            return
        }
        try {
            val contentUri = FileProvider.getUriForFile(
                this,
                "$packageName.fileprovider",
                prepared.sourceFile,
            )
            val openIntent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(contentUri, prepared.location.mimeType)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                clipData = ClipData.newRawUri("recording-export", contentUri)
            }
            val chooser = Intent.createChooser(openIntent, "用其他应用打开").apply {
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                clipData = openIntent.clipData
            }
            startActivity(chooser)
            result.success(true)
        } catch (_: RuntimeException) {
            result.error(
                "NATIVE_AUDIO_EXPORT_OPEN_FAILED",
                "No application could open this recording.",
                null,
            )
        }
    }

    private fun resolvePreparedRecordingExport(
        arguments: Map<*, *>?,
    ): PreparedRecordingExport {
        val location = RecordingExportContract.resolve(
            arguments?.get("opaqueExportRef") as? String,
        ) ?: throw RecordingExportException(
            code = "NATIVE_AUDIO_EXPORT_REFERENCE_INVALID",
            safeMessage = "The prepared recording export reference is invalid.",
        )
        val displayName = RecordingExportContract.preferredDisplayName(
            arguments?.get("displayName") as? String,
            location.fileName,
        )
        return resolvePreparedRecordingExport(location, displayName)
    }

    private fun resolvePreparedRecordingExport(
        location: RecordingExportLocation,
        displayName: String,
    ): PreparedRecordingExport {
        val source = RecordingExportContract.resolveSourceFile(filesDir, location)
        val sourceFile = source.sourceFile ?: throw when (source.error) {
            RecordingExportSourceError.UNSAFE -> RecordingExportException(
                code = "NATIVE_AUDIO_EXPORT_SOURCE_UNSAFE",
                safeMessage = "The prepared recording export path is unsafe.",
            )
            RecordingExportSourceError.MISSING -> RecordingExportException(
                code = "NATIVE_AUDIO_EXPORT_SOURCE_MISSING",
                safeMessage = "The prepared recording export is missing.",
            )
            RecordingExportSourceError.EMPTY -> RecordingExportException(
                code = "NATIVE_AUDIO_EXPORT_SOURCE_EMPTY",
                safeMessage = "The prepared recording export is empty.",
            )
            RecordingExportSourceError.UNAVAILABLE, null -> RecordingExportException(
                code = "NATIVE_AUDIO_EXPORT_SOURCE_UNAVAILABLE",
                safeMessage = "The prepared recording export is unavailable.",
            )
        }
        return PreparedRecordingExport(
            location = location,
            sourceFile = sourceFile,
            displayName = displayName,
        )
    }

    private fun cancelRecordingExportSaveRequest() {
        val pending = pendingRecordingExportSave
        pendingRecordingExportSave = null
        pending?.result?.error(
            "NATIVE_AUDIO_EXPORT_SAVE_CANCELLED",
            "The recording save request was cancelled.",
            null,
        )
    }

    private fun hasPendingNativeFileInteraction(): Boolean {
        return pendingAudioPickerResult != null ||
            pendingDocumentPickerResult != null ||
            pendingMediaPicker != null ||
            pendingRecordingExportSave != null ||
            pendingImageGallerySave != null
    }

    private fun saveImageToGallery(
        arguments: Map<*, *>?,
        result: MethodChannel.Result,
    ) {
        if (hasPendingNativeFileInteraction()) {
            result.error(
                "NATIVE_IMAGE_SAVE_BUSY",
                "Another native file interaction is already active.",
                null,
            )
            return
        }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            result.error(
                "NATIVE_IMAGE_SAVE_UNAVAILABLE",
                "Saving images requires Android 10 or newer.",
                null,
            )
            return
        }
        val bytes = arguments?.get("bytes") as? ByteArray
        val mimeType = (arguments?.get("mimeType") as? String)?.trim()?.lowercase()
        val displayName = safeImageGalleryDisplayName(
            arguments?.get("displayName") as? String,
            mimeType,
        )
        if (bytes == null || displayName == null || mimeType == null ||
            bytes.isEmpty() || bytes.size > MAX_IMAGE_GALLERY_SAVE_BYTES ||
            mimeType !in IMAGE_GALLERY_MIME_TYPES ||
            !hasImageGallerySignature(bytes, mimeType)
        ) {
            result.error(
                "NATIVE_IMAGE_SAVE_INVALID",
                "Image save request is invalid.",
                null,
            )
            return
        }
        val pending = PendingImageGallerySave(result)
        pendingImageGallerySave = pending
        Thread(
            {
                var destination: Uri? = null
                val saved = runCatching {
                    val values = ContentValues().apply {
                        put(MediaStore.Images.Media.DISPLAY_NAME, displayName)
                        put(MediaStore.Images.Media.MIME_TYPE, mimeType)
                        put(
                            MediaStore.Images.Media.RELATIVE_PATH,
                            "${Environment.DIRECTORY_PICTURES}/无限花火",
                        )
                        put(MediaStore.Images.Media.IS_PENDING, 1)
                    }
                    destination = checkNotNull(
                        contentResolver.insert(
                            MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
                            values,
                        ),
                    ) { "Photo library destination is unavailable" }
                    checkNotNull(contentResolver.openOutputStream(destination!!, "w")) {
                        "Photo library output stream is unavailable"
                    }.use { output ->
                        output.write(bytes)
                        output.flush()
                    }
                    values.clear()
                    values.put(MediaStore.Images.Media.IS_PENDING, 0)
                    check(contentResolver.update(destination!!, values, null, null) == 1) {
                        "Photo library destination could not be finalized"
                    }
                }
                if (saved.isFailure) {
                    destination?.let { uri -> runCatching { contentResolver.delete(uri, null, null) } }
                }
                runOnUiThread {
                    if (pendingImageGallerySave !== pending) return@runOnUiThread
                    pendingImageGallerySave = null
                    saved.fold(
                        onSuccess = { pending.result.success(true) },
                        onFailure = {
                            pending.result.error(
                                "NATIVE_IMAGE_SAVE_FAILED",
                                "Image could not be saved to the photo library.",
                                null,
                            )
                        },
                    )
                }
            },
            "huahuo-image-gallery-save",
        ).start()
    }

    private fun cancelImageGallerySaveRequest() {
        val pending = pendingImageGallerySave
        pendingImageGallerySave = null
        pending?.result?.error(
            "NATIVE_IMAGE_SAVE_CANCELLED",
            "The image save request was cancelled.",
            null,
        )
    }

    private fun safeImageGalleryDisplayName(value: String?, mimeType: String?): String? {
        val name = value?.trim()
        if (name.isNullOrEmpty() || name.length > 128 ||
            name.contains('/') || name.contains('\\') || name.contains("..") ||
            name.any { it.code < 32 }
        ) return null
        val extension = name.substringAfterLast('.', "").lowercase()
        val validExtension = when (mimeType) {
            "image/jpeg" -> extension == "jpg" || extension == "jpeg"
            "image/png" -> extension == "png"
            "image/webp" -> extension == "webp"
            else -> false
        }
        return name.takeIf { validExtension }
    }

    private fun hasImageGallerySignature(bytes: ByteArray, mimeType: String): Boolean = when (mimeType) {
        "image/jpeg" -> bytes.size >= 3 &&
            bytes[0] == 0xFF.toByte() && bytes[1] == 0xD8.toByte() && bytes[2] == 0xFF.toByte()
        "image/png" -> bytes.size >= 8 &&
            bytes.copyOfRange(0, 8).contentEquals(
                byteArrayOf(0x89.toByte(), 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A),
            )
        "image/webp" -> bytes.size >= 12 &&
            bytes.copyOfRange(0, 4).contentEquals(byteArrayOf(0x52, 0x49, 0x46, 0x46)) &&
            bytes.copyOfRange(8, 12).contentEquals(byteArrayOf(0x57, 0x45, 0x42, 0x50))
        else -> false
    }

    private fun pickAudioFiles(result: MethodChannel.Result) {
        if (hasPendingNativeFileInteraction()) {
            result.error(
                "NATIVE_FILE_PICKER_BUSY",
                "Another native file interaction is already active.",
                null,
            )
            return
        }
        pendingAudioPickerResult = result
        try {
            val pickerIntent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                addCategory(Intent.CATEGORY_OPENABLE)
                type = "audio/*"
                putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
                putExtra(Intent.EXTRA_MIME_TYPES, AUDIO_MIME_TYPES)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            startActivityForResult(pickerIntent, AUDIO_PICKER_REQUEST_CODE)
        } catch (_: RuntimeException) {
            val pending = pendingAudioPickerResult
            pendingAudioPickerResult = null
            pending?.error(
                "NATIVE_FILE_PICKER_FAILED",
                "Native audio picker could not be opened.",
                null,
            )
        }
    }

    private fun completeAudioPickerRequest(resultCode: Int, data: Intent?) {
        val pending = pendingAudioPickerResult ?: return
        pendingAudioPickerResult = null
        if (resultCode != RESULT_OK) {
            pending.success(null)
            return
        }
        val uris = selectedDocumentUris(data).take(MAX_PICKED_AUDIO_FILES)
        if (uris.isEmpty()) {
            pending.success(null)
            return
        }

        Thread(
            {
                val prepared = mutableListOf<Map<String, Any>>()
                val copied = runCatching {
                    uris.forEach { uri -> prepared.add(copyPickedAudio(uri)) }
                    prepared.toList()
                }.onFailure {
                    prepared.forEach { payload ->
                        (payload["sourcePath"] as? String)?.let { path ->
                            runCatching { File(path).delete() }
                        }
                    }
                }
                runOnUiThread {
                    copied.fold(
                        onSuccess = pending::success,
                        onFailure = {
                            pending.error(
                                "NATIVE_FILE_PICKER_FAILED",
                                "Native audio picker could not prepare selected files.",
                                null,
                            )
                        },
                    )
                }
            },
            "huahuo-audio-import",
        ).start()
    }

    private fun copyPickedAudio(uri: Uri): Map<String, Any> {
        val metadata = checkNotNull(
            NativeAudioImportContract.resolve(
                documentDisplayName(uri),
                contentResolver.getType(uri),
            ),
        ) { "Unsupported audio metadata" }
        val importDirectory = File(cacheDir, "huahuoai-native-file-picker")
        check(importDirectory.exists() || importDirectory.mkdirs()) {
            "Could not create import cache directory"
        }
        val destination = File(importDirectory, "${UUID.randomUUID()}.${metadata.extension}")
        try {
            val copiedBytes = contentResolver.openInputStream(uri).use { input ->
                val readableInput = checkNotNull(input) { "Could not read selected audio" }
                FileOutputStream(destination).use { output ->
                    val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
                    var total = 0L
                    while (true) {
                        val read = readableInput.read(buffer)
                        if (read < 0) break
                        if (read == 0) continue
                        total += read
                        check(total <= MAX_PICKED_AUDIO_BYTES) { "Selected audio is too large" }
                        output.write(buffer, 0, read)
                    }
                    output.flush()
                    total
                }
            }
            check(copiedBytes > 0 && destination.length() == copiedBytes) {
                "Selected audio is empty or incomplete"
            }
            return buildMap {
                put("displayName", metadata.displayName)
                put("mimeType", metadata.mimeType)
                put("sizeBytes", copiedBytes)
                put("sourcePath", destination.path)
                put("sourceIdentifier", uri.toString())
                audioDurationSeconds(destination)?.let { put("durationSeconds", it) }
            }
        } catch (error: Throwable) {
            runCatching { destination.delete() }
            throw error
        }
    }

    private fun audioDurationSeconds(file: File): Int? {
        val retriever = MediaMetadataRetriever()
        return try {
            retriever.setDataSource(file.absolutePath)
            retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)
                ?.toLongOrNull()
                ?.takeIf { it > 0 }
                ?.let { milliseconds ->
                    ((milliseconds + 999L) / 1000L)
                        .coerceAtMost(Int.MAX_VALUE.toLong())
                        .toInt()
                }
        } catch (_: RuntimeException) {
            null
        } finally {
            runCatching { retriever.release() }
        }
    }

    private fun pickDocumentFiles(result: MethodChannel.Result) {
        if (hasPendingNativeFileInteraction()) {
            result.error(
                "NATIVE_DOCUMENT_PICKER_BUSY",
                "Another native file interaction is already active.",
                null,
            )
            return
        }
        pendingDocumentPickerResult = result
        try {
            val pickerIntent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                addCategory(Intent.CATEGORY_OPENABLE)
                type = "*/*"
                putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
                putExtra(Intent.EXTRA_MIME_TYPES, DOCUMENT_MIME_TYPES)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            startActivityForResult(pickerIntent, DOCUMENT_PICKER_REQUEST_CODE)
        } catch (_: RuntimeException) {
            val pending = pendingDocumentPickerResult
            pendingDocumentPickerResult = null
            pending?.error(
                "NATIVE_DOCUMENT_PICKER_FAILED",
                "Native document picker could not be opened.",
                null,
            )
        }
    }

    private fun completeDocumentPickerRequest(resultCode: Int, data: Intent?) {
        val pending = pendingDocumentPickerResult ?: return
        pendingDocumentPickerResult = null
        if (resultCode != RESULT_OK) {
            pending.success(null)
            return
        }
        val uris = selectedDocumentUris(data)
        if (uris.isEmpty()) {
            pending.success(null)
            return
        }

        Thread {
            val copied = runCatching {
                uris.map(::copyPickedDocument)
            }
            runOnUiThread {
                copied.fold(
                    onSuccess = { payload -> pending.success(payload) },
                    onFailure = {
                        pending.error(
                            "NATIVE_DOCUMENT_PICKER_FAILED",
                            "Native document picker could not prepare selected files.",
                            null,
                        )
                    },
                )
            }
        }.start()
    }

    private fun selectedDocumentUris(data: Intent?): List<Uri> {
        if (data == null) return emptyList()
        val uris = linkedSetOf<Uri>()
        data.data?.let(uris::add)
        data.clipData?.let { clipData ->
            for (index in 0 until clipData.itemCount) {
                clipData.getItemAt(index).uri?.let(uris::add)
            }
        }
        return uris.toList()
    }

    private fun copyPickedDocument(uri: Uri): Map<String, Any> {
        val displayName = documentDisplayName(uri)
        val extension = displayName.substringAfterLast('.', "").lowercase()
        check(extension in SUPPORTED_DOCUMENT_EXTENSIONS) {
            "Unsupported document extension"
        }
        val mimeType = documentMimeType(extension)

        val importDirectory = File(cacheDir, "huahuoai-native-file-picker")
        check(importDirectory.exists() || importDirectory.mkdirs()) {
            "Could not create import cache directory"
        }
        val destination = File(importDirectory, "${UUID.randomUUID()}.$extension")
        val readableInput = contentResolver.openInputStream(uri)
            ?: throw IncomingMaterialCopyException("INCOMING_MATERIAL_UNREADABLE")
        val sizeBytes = copyIncomingMaterialBounded(
            input = readableInput,
            destination = destination,
            maximumBytes = MAX_PICKED_DOCUMENT_BYTES,
        )
        return mapOf(
            "displayName" to displayName,
            "mimeType" to mimeType,
            "sizeBytes" to sizeBytes,
            "sourcePath" to destination.path,
            "sourceIdentifier" to uri.toString(),
        )
    }

    private fun acceptIncomingMaterialIntent(incomingIntent: Intent?) {
        val action = incomingIntent?.action ?: return
        if (action !in SUPPORTED_INCOMING_ACTIONS) return
        if (action == Intent.ACTION_VIEW && incomingIntent.data?.scheme == "huahuoai") {
            return
        }
        val uris = incomingMaterialUris(incomingIntent)
        if (uris.isEmpty()) return
        val origin = when (action) {
            Intent.ACTION_SEND_MULTIPLE -> "sendMultiple"
            Intent.ACTION_SEND -> "send"
            else -> "open"
        }
        Thread {
            val copied = mutableListOf<Map<String, Any>>()
            val failures = mutableListOf<String>()
            for (uri in uris) {
                runCatching { copyIncomingMaterial(uri, origin) }
                    .fold(
                        onSuccess = copied::add,
                        onFailure = { failures += incomingMaterialFailureCode(it) },
                    )
            }
            if (copied.isEmpty() && failures.isEmpty()) return@Thread
            runOnUiThread {
                for (payload in copied) {
                    if (pendingIncomingMaterials.size >= MAX_PENDING_INCOMING_MATERIALS) {
                        deleteIncomingMaterial(pendingIncomingMaterials.removeAt(0))
                    }
                    pendingIncomingMaterials.add(payload)
                }
                for (code in failures) {
                    if (pendingIncomingMaterialErrors.size >= MAX_PENDING_INCOMING_MATERIALS) {
                        pendingIncomingMaterialErrors.removeAt(0)
                    }
                    pendingIncomingMaterialErrors.add(code)
                }
                incomingMaterialEventSink?.success("pending")
            }
        }.start()
    }

    private fun incomingMaterialFailureCode(error: Throwable): String = when (error) {
        is IncomingMaterialCopyException -> error.code
        is SecurityException -> "INCOMING_MATERIAL_PERMISSION_DENIED"
        else -> "INCOMING_MATERIAL_UNREADABLE"
    }

    private fun incomingMaterialUris(incomingIntent: Intent): List<Uri> {
        val uris = linkedSetOf<Uri>()
        incomingIntent.data?.let(uris::add)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            incomingIntent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)?.let(uris::add)
            incomingIntent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java)
                ?.let(uris::addAll)
        } else {
            @Suppress("DEPRECATION")
            (incomingIntent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM))?.let(uris::add)
            @Suppress("DEPRECATION")
            incomingIntent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)?.let(uris::addAll)
        }
        incomingIntent.clipData?.let { clipData ->
            for (index in 0 until clipData.itemCount) {
                clipData.getItemAt(index).uri?.let(uris::add)
            }
        }
        return uris.take(MAX_PENDING_INCOMING_MATERIALS)
    }

    private fun copyIncomingMaterial(uri: Uri, origin: String): Map<String, Any> {
        var displayName = documentDisplayName(uri)
        val declaredMimeType = contentResolver.getType(uri)?.lowercase()
        var extension = displayName.substringAfterLast('.', "").lowercase()
        if (extension in LEGACY_DOCUMENT_EXTENSIONS) {
            throw IncomingMaterialCopyException("INCOMING_MATERIAL_FORMAT_UNSUPPORTED")
        }
        val inferredExtension = materialExtensionForMime(declaredMimeType)
        if (inferredExtension != null && extension !in SUPPORTED_MATERIAL_EXTENSIONS) {
            displayName = "imported-material.$inferredExtension"
            extension = inferredExtension
        }
        if (extension !in SUPPORTED_MATERIAL_EXTENSIONS) {
            throw IncomingMaterialCopyException("INCOMING_MATERIAL_FORMAT_UNSUPPORTED")
        }
        val expectedKind = if (extension in SUPPORTED_AUDIO_EXTENSIONS) "audio" else "document"
        val mimeType = if (expectedKind == "document") {
            documentMimeType(extension)
        } else {
            declaredMimeType
                ?.takeIf { it in MATERIAL_MIME_TYPES || it == "application/octet-stream" }
                ?: materialMimeType(extension)
        }
        if (expectedKind == "audio" &&
            !mimeType.startsWith("audio/") &&
            mimeType != "application/octet-stream"
        ) {
            throw IncomingMaterialCopyException("INCOMING_MATERIAL_FORMAT_UNSUPPORTED")
        }
        val directory = incomingMaterialDirectory()
        check(directory.exists() || directory.mkdirs()) { "Could not create incoming cache" }
        val opaqueId = UUID.randomUUID().toString()
        val destination = File(directory, "$opaqueId.$extension")
        val readable = contentResolver.openInputStream(uri)
            ?: throw IncomingMaterialCopyException("INCOMING_MATERIAL_UNREADABLE")
        val sizeBytes = copyIncomingMaterialBounded(
            input = readable,
            destination = destination,
            maximumBytes = MAX_INCOMING_MATERIAL_BYTES,
        )
        val contentHash = sha256Hex(destination)
        val payload = mapOf(
            "opaqueRef" to "incoming-material://$opaqueId",
            "displayName" to displayName.take(MAX_INCOMING_DISPLAY_NAME),
            "mimeType" to mimeType,
            "sizeBytes" to sizeBytes,
            "kind" to expectedKind,
            "origin" to origin,
            "sourcePath" to destination.absolutePath,
            "contentHash" to contentHash,
        )
        try {
            persistIncomingMaterial(payload)
        } catch (error: Throwable) {
            runCatching { destination.delete() }
            throw error
        }
        return payload
    }

    private fun consumeIncomingMaterials(result: MethodChannel.Result) {
        result.success(pendingIncomingMaterials.toList())
    }

    private fun consumeIncomingMaterialErrors(result: MethodChannel.Result) {
        val errors = pendingIncomingMaterialErrors.toList()
        pendingIncomingMaterialErrors.clear()
        result.success(errors)
    }

    private fun acknowledgeIncomingMaterials(
        arguments: Map<*, *>?,
        result: MethodChannel.Result,
    ) {
        val refs = (arguments?.get("opaqueRefs") as? List<*>)
            ?.filterIsInstance<String>()
            ?.filter { INCOMING_OPAQUE_REF.matches(it) }
            ?.toSet()
            .orEmpty()
        val discardFiles = arguments?.get("discardFiles") as? Boolean ?: true
        if (refs.isEmpty()) {
            result.error(
                "INCOMING_MATERIAL_ACK_INVALID",
                "Incoming material acknowledgement was invalid.",
                null,
            )
            return
        }
        val acknowledged = pendingIncomingMaterials.filter {
            (it["opaqueRef"] as? String) in refs
        }
        if (acknowledged.size != refs.size) {
            result.error(
                "INCOMING_MATERIAL_ACK_NOT_FOUND",
                "An incoming material acknowledgement was stale.",
                null,
            )
            return
        }
        pendingIncomingMaterials.removeAll(acknowledged.toSet())
        acknowledged.forEach { payload ->
            deleteIncomingMaterial(payload, discardFile = discardFiles)
        }
        result.success(true)
    }

    private fun incomingMaterialDirectory(): File =
        File(filesDir, "huahuoai-incoming-materials")

    private fun persistIncomingMaterial(payload: Map<String, Any>) {
        val opaqueRef = payload["opaqueRef"] as? String
            ?: error("Incoming material opaque ref is missing")
        val opaqueId = opaqueRef.removePrefix("incoming-material://")
        check(INCOMING_OPAQUE_ID.matches(opaqueId)) { "Incoming material opaque ref is invalid" }
        val directory = incomingMaterialDirectory()
        check(directory.exists() || directory.mkdirs()) { "Could not create incoming directory" }
        val manifest = File(directory, "$opaqueId.json")
        val part = File(directory, ".$opaqueId.json.part")
        val json = JSONObject()
        payload.forEach { (key, value) -> json.put(key, value) }
        part.writeText(json.toString(), Charsets.UTF_8)
        if (manifest.exists()) check(manifest.delete()) { "Could not replace incoming manifest" }
        check(part.renameTo(manifest)) { "Could not commit incoming manifest" }
    }

    private fun restoreIncomingMaterials() {
        pendingIncomingMaterials.clear()
        val directory = incomingMaterialDirectory()
        if (!directory.exists()) return
        val manifests = directory.listFiles { file ->
            file.isFile && file.name.endsWith(".json")
        }?.sortedBy { it.lastModified() }.orEmpty()
        for (manifest in manifests.dropLast(minOf(manifests.size, MAX_PENDING_INCOMING_MATERIALS))) {
            val payload = runCatching { payloadFromIncomingManifest(manifest) }.getOrNull()
            if (payload == null) {
                runCatching { manifest.delete() }
            } else {
                deleteIncomingMaterial(payload)
            }
        }
        for (manifest in manifests.takeLast(MAX_PENDING_INCOMING_MATERIALS)) {
            val payload = runCatching { payloadFromIncomingManifest(manifest) }.getOrNull()
            if (payload == null) {
                runCatching { manifest.delete() }
                continue
            }
            pendingIncomingMaterials.add(payload)
        }
    }

    private fun payloadFromIncomingManifest(manifest: File): Map<String, Any> {
        val json = JSONObject(manifest.readText(Charsets.UTF_8))
        val candidate = mutableMapOf<String, Any>()
        listOf(
            "opaqueRef",
            "displayName",
            "mimeType",
            "kind",
            "origin",
            "sourcePath",
            "contentHash",
        ).forEach { key -> candidate[key] = json.getString(key) }
        candidate["sizeBytes"] = json.getLong("sizeBytes")
        validateIncomingMaterial(candidate)
        return candidate.toMap()
    }

    private fun validateIncomingMaterial(payload: Map<String, Any>) {
        val opaqueRef = payload["opaqueRef"] as? String
        val displayName = payload["displayName"] as? String
        val mimeType = payload["mimeType"] as? String
        val kind = payload["kind"] as? String
        val sourcePath = payload["sourcePath"] as? String
        val sizeBytes = payload["sizeBytes"] as? Long
        val contentHash = payload["contentHash"] as? String
        check(opaqueRef != null && INCOMING_OPAQUE_REF.matches(opaqueRef))
        check(displayName != null && mimeType != null && kind != null)
        check(sourcePath != null && sizeBytes != null && sizeBytes > 0)
        check(contentHash != null && SHA_256.matches(contentHash))
        val extension = displayName.substringAfterLast('.', "").lowercase()
        check(extension in SUPPORTED_MATERIAL_EXTENSIONS)
        val expectedKind = if (extension in SUPPORTED_AUDIO_EXTENSIONS) "audio" else "document"
        check(kind == expectedKind)
        if (expectedKind == "document") {
            check(mimeType == documentMimeType(extension))
        }
        val directory = incomingMaterialDirectory().canonicalFile
        val file = File(sourcePath).canonicalFile
        check(file.parentFile == directory && file.isFile && file.length() == sizeBytes)
        check(sha256Hex(file) == contentHash)
    }

    private fun deleteIncomingMaterial(
        payload: Map<String, Any>,
        discardFile: Boolean = true,
    ) {
        val opaqueId = (payload["opaqueRef"] as? String)
            ?.removePrefix("incoming-material://")
            ?.takeIf(INCOMING_OPAQUE_ID::matches)
            ?: return
        runCatching { File(incomingMaterialDirectory(), "$opaqueId.json").delete() }
        if (!discardFile) return
        val path = payload["sourcePath"] as? String ?: return
        runCatching {
            val directory = incomingMaterialDirectory().canonicalFile
            val file = File(path).canonicalFile
            if (file.parentFile == directory) file.delete()
        }
    }

    private fun sha256Hex(file: File): String {
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().buffered().use { input ->
            val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
            while (true) {
                val read = input.read(buffer)
                if (read < 0) break
                if (read > 0) digest.update(buffer, 0, read)
            }
        }
        return digest.digest().joinToString("") { byte ->
            "%02x".format(byte.toInt() and 0xff)
        }
    }

    private fun materialMimeType(extension: String): String = when (extension) {
        "mp3" -> "audio/mpeg"
        "m4a", "mp4" -> "audio/mp4"
        "wav" -> "audio/wav"
        "opus" -> "audio/opus"
        else -> documentMimeType(extension)
    }

    private fun materialExtensionForMime(mimeType: String?): String? = when (mimeType) {
        "audio/mpeg", "audio/mp3" -> "mp3"
        "audio/mp4", "audio/x-m4a" -> "m4a"
        "audio/wav", "audio/x-wav" -> "wav"
        "audio/opus", "audio/ogg" -> "opus"
        "text/plain" -> "txt"
        "text/markdown" -> "md"
        "text/csv" -> "csv"
        "application/json" -> "json"
        "application/pdf" -> "pdf"
        "application/vnd.openxmlformats-officedocument.wordprocessingml.document" -> "docx"
        "application/vnd.openxmlformats-officedocument.presentationml.presentation" -> "pptx"
        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" -> "xlsx"
        else -> null
    }

    private fun documentDisplayName(uri: Uri): String {
        contentResolver.query(
            uri,
            arrayOf(OpenableColumns.DISPLAY_NAME),
            null,
            null,
            null,
        )?.use { cursor ->
            if (cursor.moveToFirst()) {
                val index = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (index >= 0) {
                    val name = cursor.getString(index)?.trim().orEmpty()
                    if (name.isNotEmpty()) return name
                }
            }
        }
        return uri.lastPathSegment?.substringAfterLast('/')?.trim()
            ?.takeIf(String::isNotEmpty)
            ?: "imported-document.txt"
    }

    private fun documentMimeType(extension: String): String = when (extension) {
        "txt" -> "text/plain"
        "md" -> "text/markdown"
        "csv" -> "text/csv"
        "json" -> "application/json"
        "pdf" -> "application/pdf"
        "docx" -> "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        "pptx" -> "application/vnd.openxmlformats-officedocument.presentationml.presentation"
        "xlsx" -> "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        else -> "application/octet-stream"
    }

    private fun isSupportedMediaExtension(extension: String, kind: String): Boolean = when (kind) {
        "image" -> extension in IMAGE_EXTENSIONS
        "video" -> extension in VIDEO_EXTENSIONS
        else -> false
    }

    private fun mediaMimeType(extension: String, kind: String): String = when (extension.lowercase()) {
        "jpg", "jpeg" -> "image/jpeg"
        "png" -> "image/png"
        "heic" -> "image/heic"
        "webp" -> "image/webp"
        "mp4" -> "video/mp4"
        "mov" -> "video/quicktime"
        "webm" -> "video/webm"
        else -> if (kind == "image") "image/*" else "video/*"
    }

    private fun mediaExtensionForMime(mimeType: String?, kind: String): String? = when (
        mimeType?.substringBefore(';')?.trim()?.lowercase()
    ) {
        "image/jpeg" -> "jpg".takeIf { kind == "image" }
        "image/png" -> "png".takeIf { kind == "image" }
        "image/heic", "image/heif" -> "heic".takeIf { kind == "image" }
        "image/webp" -> "webp".takeIf { kind == "image" }
        "video/mp4" -> "mp4".takeIf { kind == "video" }
        "video/quicktime" -> "mov".takeIf { kind == "video" }
        "video/webm" -> "webm".takeIf { kind == "video" }
        else -> null
    }

    private fun cancelDocumentPickerRequest() {
        val pending = pendingDocumentPickerResult
        pendingDocumentPickerResult = null
        pending?.error(
            "NATIVE_DOCUMENT_PICKER_CANCELLED",
            "Native document picker was cancelled.",
            null,
        )
    }

    private fun cancelAudioPickerRequest() {
        val pending = pendingAudioPickerResult
        pendingAudioPickerResult = null
        pending?.error(
            "NATIVE_FILE_PICKER_CANCELLED",
            "Native audio picker was cancelled.",
            null,
        )
    }

    private fun pickMediaFiles(arguments: Map<*, *>?, result: MethodChannel.Result) {
        if (hasPendingNativeFileInteraction()) {
            result.error("NATIVE_MEDIA_PICKER_BUSY", "Another native file interaction is already active.", null)
            return
        }
        val kind = arguments?.get("kind") as? String
        val source = arguments?.get("source") as? String
        if (kind == null || source == null || kind !in MEDIA_KINDS || source !in MEDIA_SOURCES) {
            result.error("NATIVE_MEDIA_PICKER_INVALID", "Native media picker request is invalid.", null)
            return
        }
        pendingMediaPicker = PendingMediaPicker(result = result, kind = kind, source = source)
        when (source) {
            "gallery" -> launchMediaGalleryPicker(kind)
            "files" -> launchMediaFilePicker(kind)
            else -> requestCameraMediaPermissionOrLaunch()
        }
    }

    private fun launchMediaGalleryPicker(kind: String) {
        pendingMediaPicker ?: return
        try {
            val mediaUri = if (kind == "image") {
                MediaStore.Images.Media.EXTERNAL_CONTENT_URI
            } else {
                MediaStore.Video.Media.EXTERNAL_CONTENT_URI
            }
            val intent = Intent(Intent.ACTION_PICK, mediaUri).apply {
                type = if (kind == "image") "image/*" else "video/*"
                putExtra(Intent.EXTRA_ALLOW_MULTIPLE, kind == "image")
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            startActivityForResult(intent, MEDIA_GALLERY_PICKER_REQUEST_CODE)
        } catch (_: RuntimeException) {
            clearMediaPickerRequest().result.error(
                "NATIVE_MEDIA_PICKER_FAILED",
                "Native media picker could not be opened.",
                null,
            )
        }
    }

    private fun launchMediaFilePicker(kind: String) {
        pendingMediaPicker ?: return
        try {
            val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                addCategory(Intent.CATEGORY_OPENABLE)
                type = if (kind == "image") "image/*" else "video/*"
                putExtra(Intent.EXTRA_ALLOW_MULTIPLE, kind == "image")
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            startActivityForResult(intent, MEDIA_GALLERY_PICKER_REQUEST_CODE)
        } catch (_: RuntimeException) {
            clearMediaPickerRequest().result.error(
                "NATIVE_MEDIA_PICKER_FAILED",
                "Native media file picker could not be opened.",
                null,
            )
        }
    }

    private fun requestCameraMediaPermissionOrLaunch() {
        val pending = pendingMediaPicker ?: return
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M ||
            checkSelfPermission(Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED
        ) {
            launchCameraMediaPicker(pending)
            return
        }
        try {
            requestPermissions(arrayOf(Manifest.permission.CAMERA), CAMERA_MEDIA_PERMISSION_REQUEST_CODE)
        } catch (_: RuntimeException) {
            clearMediaPickerRequest().result.error(
                "NATIVE_MEDIA_CAMERA_PERMISSION_REQUIRED",
                "Camera permission is required for capture.",
                null,
            )
        }
    }

    private fun completeCameraMediaPermissionRequest() {
        val pending = pendingMediaPicker ?: return
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M ||
            checkSelfPermission(Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED
        ) {
            launchCameraMediaPicker(pending)
        } else {
            clearMediaPickerRequest().result.error(
                "NATIVE_MEDIA_CAMERA_PERMISSION_REQUIRED",
                "Camera permission is required for capture.",
                null,
            )
        }
    }

    private fun launchCameraMediaPicker(pending: PendingMediaPicker) {
        try {
            val directory = File(cacheDir, "huahuoai-media-capture")
            check(directory.exists() || directory.mkdirs()) { "Could not create camera cache" }
            val extension = if (pending.kind == "image") "jpg" else "mp4"
            val output = File(directory, "${UUID.randomUUID()}.$extension")
            val uri = FileProvider.getUriForFile(this, "$packageName.fileprovider", output)
            val intent = Intent(
                if (pending.kind == "image") {
                    MediaStore.ACTION_IMAGE_CAPTURE
                } else {
                    MediaStore.ACTION_VIDEO_CAPTURE
                },
            ).apply {
                putExtra(MediaStore.EXTRA_OUTPUT, uri)
                addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION or Intent.FLAG_GRANT_READ_URI_PERMISSION)
                clipData = android.content.ClipData.newRawUri("media-output", uri)
            }
            pending.outputFile = output
            startActivityForResult(intent, MEDIA_CAMERA_PICKER_REQUEST_CODE)
        } catch (_: RuntimeException) {
            clearMediaPickerRequest().result.error(
                "NATIVE_MEDIA_CAMERA_FAILED",
                "Camera could not be opened.",
                null,
            )
        }
    }

    private fun completeMediaGalleryPickerRequest(resultCode: Int, data: Intent?) {
        val pending = pendingMediaPicker ?: return
        if (resultCode != RESULT_OK) {
            clearMediaPickerRequest().result.success(null)
            return
        }
        val limit = if (pending.kind == "image") MAX_PICKED_CHAT_IMAGES else 1
        val uris = selectedDocumentUris(data).take(limit)
        if (uris.isEmpty()) {
            clearMediaPickerRequest().result.success(null)
            return
        }
        Thread {
            val payload = runCatching {
                uris.map { uri -> copyPickedMedia(uri, pending.kind) }
            }
            runOnUiThread {
                val result = clearMediaPickerRequest().result
                payload.fold(
                    onSuccess = result::success,
                    onFailure = {
                        result.error(
                            "NATIVE_MEDIA_PICKER_FAILED",
                            "Native media picker could not prepare selected media.",
                            null,
                        )
                    },
                )
            }
        }.start()
    }

    private fun completeMediaCameraPickerRequest(resultCode: Int) {
        val pending = pendingMediaPicker ?: return
        val output = pending.outputFile
        val result = clearMediaPickerRequest().result
        if (resultCode != RESULT_OK || output == null || !output.exists() || output.length() <= 0L) {
            output?.delete()
            result.success(null)
            return
        }
        result.success(listOf(mediaPayload(output, pending.kind)))
    }

    private fun copyPickedMedia(uri: Uri, kind: String): Map<String, Any> {
        val providerMimeType = contentResolver.getType(uri)
        var displayName = documentDisplayName(uri)
        var extension = displayName.substringAfterLast('.', "").lowercase()
        if (!isSupportedMediaExtension(extension, kind)) {
            val inferredExtension = checkNotNull(mediaExtensionForMime(providerMimeType, kind)) {
                "Unsupported media extension"
            }
            displayName = displayNameWithMediaExtension(displayName, inferredExtension, kind)
            extension = inferredExtension
        }
        val directory = File(cacheDir, "huahuoai-native-media-picker")
        check(directory.exists() || directory.mkdirs()) { "Could not create media cache directory" }
        if (kind == "image" && extension in HEIF_EXTENSIONS) {
            val destination = File(directory, "${UUID.randomUUID()}.jpg")
            try {
                copyHEIFImageAsJpeg(uri, destination)
                check(destination.length() in 1..MAX_IMAGE_GALLERY_SAVE_BYTES) {
                    "Converted image is too large"
                }
                return mediaPayload(
                    destination,
                    kind,
                    "image/jpeg",
                    displayName = jpegDisplayName(displayName),
                )
            } catch (error: Throwable) {
                runCatching { destination.delete() }
                throw error
            }
        }
        val destination = File(directory, "${UUID.randomUUID()}.$extension")
        try {
            contentResolver.openInputStream(uri).use { input ->
                val readableInput = checkNotNull(input) { "Could not read selected media" }
                FileOutputStream(destination).use { output -> readableInput.copyTo(output) }
            }
            if (kind == "image") {
                check(destination.length() in 1..MAX_IMAGE_GALLERY_SAVE_BYTES) {
                    "Selected image is too large"
                }
            }
        } catch (error: Throwable) {
            runCatching { destination.delete() }
            throw error
        }
        return mediaPayload(
            destination,
            kind,
            normalizedMediaMimeType(
                providerMimeType,
                destination.extension,
                kind,
            ),
            displayName = displayName,
        )
    }

    private fun mediaPayload(
        file: File,
        kind: String,
        resolvedMimeType: String? = null,
        displayName: String? = null,
    ): Map<String, Any> {
        val resolvedDisplayName = displayName?.trim().orEmpty().ifEmpty { file.name }
        return mapOf(
            "displayName" to resolvedDisplayName,
            "mimeType" to (resolvedMimeType ?: mediaMimeType(file.extension, kind)),
            "sizeBytes" to file.length(),
            "sourcePath" to file.path,
        )
    }

    private fun normalizedMediaMimeType(
        providerMimeType: String?,
        extension: String,
        kind: String,
    ): String {
        val expected = mediaMimeType(extension, kind)
        val provider = providerMimeType?.trim()?.lowercase()
        return if (expected in IMAGE_GALLERY_MIME_TYPES || expected in VIDEO_MEDIA_MIME_TYPES) {
            expected
        } else if (provider.isNullOrEmpty() || provider.endsWith("/*")) {
            expected
        } else {
            provider
        }
    }

    private fun copyHEIFImageAsJpeg(uri: Uri, destination: File) {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        contentResolver.openInputStream(uri).use { input ->
            checkNotNull(input) { "Could not read selected image" }
            BitmapFactory.decodeStream(input, null, bounds)
        }
        check(bounds.outWidth > 0 && bounds.outHeight > 0) { "Selected image is invalid" }
        var sampleSize = 1
        while (bounds.outWidth / sampleSize > MAX_HEIF_IMAGE_DIMENSION ||
            bounds.outHeight / sampleSize > MAX_HEIF_IMAGE_DIMENSION
        ) {
            sampleSize *= 2
        }
        val options = BitmapFactory.Options().apply { inSampleSize = sampleSize }
        val bitmap = contentResolver.openInputStream(uri).use { input ->
            checkNotNull(input) { "Could not read selected image" }
            checkNotNull(BitmapFactory.decodeStream(input, null, options)) {
                "Selected image is invalid"
            }
        }
        try {
            FileOutputStream(destination).use { output ->
                check(bitmap.compress(Bitmap.CompressFormat.JPEG, 92, output)) {
                    "Selected image could not be converted"
                }
                output.flush()
            }
        } finally {
            bitmap.recycle()
        }
    }

    private fun jpegDisplayName(value: String): String {
        val base = value.substringBeforeLast('.', value).trim().ifEmpty { "image" }
        return "$base.jpg"
    }

    private fun displayNameWithMediaExtension(
        value: String,
        extension: String,
        kind: String,
    ): String {
        val base = value.substringBeforeLast('.', value).trim().ifEmpty { "selected-$kind" }
        return "$base.$extension"
    }

    private fun clearMediaPickerRequest(): PendingMediaPicker {
        val pending = checkNotNull(pendingMediaPicker) { "No pending media picker" }
        pendingMediaPicker = null
        return pending
    }

    private fun cancelMediaPickerRequest() {
        val pending = pendingMediaPicker ?: return
        pendingMediaPicker = null
        pending.outputFile?.delete()
        pending.result.error(
            "NATIVE_MEDIA_PICKER_CANCELLED",
            "Native media picker was cancelled.",
            null,
        )
    }

    private fun requestBluetoothPermissions(
        arguments: Map<*, *>?,
        result: MethodChannel.Result,
    ) {
        val requestedKinds = arguments?.get("kinds") as? List<*>
        if (
            requestedKinds.isNullOrEmpty() ||
                requestedKinds.any { kind ->
                    kind !is String || kind !in BLUETOOTH_PERMISSION_KINDS
                }
        ) {
            result.error(
                "PLATFORM_PERMISSION_REQUEST_INVALID",
                "Only Bluetooth permission kinds can be requested on this channel.",
                null,
            )
            return
        }

        val permissions = bluetoothPermissionsToRequest()
        if (permissions.isEmpty() || permissions.all(::isPermissionGranted)) {
            result.success(permissionStatuses())
            return
        }
        if (hasPendingPlatformPermissionRequest()) {
            result.error(
                "PLATFORM_PERMISSION_REQUEST_IN_PROGRESS",
                "A platform permission request is already active.",
                null,
            )
            return
        }

        pendingBluetoothPermissionResult = result
        bluetoothPermissionTimeout = Runnable {
            val pending = pendingBluetoothPermissionResult ?: return@Runnable
            clearBluetoothPermissionRequest()
            pending.error(
                "PLATFORM_PERMISSION_REQUEST_TIMEOUT",
                "Bluetooth permission did not return in time.",
                null,
            )
        }.also { mainHandler.postDelayed(it, PERMISSION_REQUEST_TIMEOUT_MS) }
        try {
            requestPermissions(permissions, RECORDING_CARD_BLUETOOTH_PERMISSION_REQUEST_CODE)
        } catch (_: RuntimeException) {
            completeBluetoothPermissionFailure("PLATFORM_PERMISSION_REQUEST_FAILED")
        }
    }

    private fun hasPendingPlatformPermissionRequest(): Boolean =
        pendingBluetoothPermissionResult != null ||
            pendingLocalNetworkPermissionResult != null ||
            pendingNotificationPermissionResult != null ||
            pendingGeneralPermissionResult != null

    private fun requestPlatformPermissions(
        arguments: Map<*, *>?,
        result: MethodChannel.Result,
    ) {
        val requestedKinds = arguments?.get("kinds") as? List<*>
        when {
            !requestedKinds.isNullOrEmpty() &&
                requestedKinds.all { it is String && it in BLUETOOTH_PERMISSION_KINDS } ->
                requestBluetoothPermissions(arguments, result)
            requestedKinds?.size == 1 && requestedKinds.single() == "local_network" ->
                requestLocalNetworkPermission(result)
            requestedKinds?.size == 1 && requestedKinds.single() == "notification" ->
                requestNotificationPermission(result)
            requestedKinds?.size == 1 &&
                requestedKinds.single() in GENERAL_PERMISSION_KINDS ->
                requestGeneralPermission(requestedKinds.single() as String, result)
            else -> result.error(
                "PLATFORM_PERMISSION_REQUEST_INVALID",
                "The requested Android permission is not supported.",
                null,
            )
        }
    }

    private fun requestGeneralPermission(kind: String, result: MethodChannel.Result) {
        val permissions = generalPermissionsToRequest(kind)
        if (permissions.isEmpty() || permissions.all(::isPermissionGranted)) {
            result.success(permissionStatuses())
            return
        }
        if (hasPendingPlatformPermissionRequest()) {
            result.error(
                "PLATFORM_PERMISSION_REQUEST_IN_PROGRESS",
                "A platform permission request is already active.",
                null,
            )
            return
        }

        pendingGeneralPermissionKind = kind
        pendingGeneralPermissionResult = result
        generalPermissionTimeout = Runnable {
            val pending = pendingGeneralPermissionResult ?: return@Runnable
            clearGeneralPermissionRequest()
            pending.error(
                "PLATFORM_PERMISSION_REQUEST_TIMEOUT",
                "Platform permission did not return in time.",
                null,
            )
        }.also { mainHandler.postDelayed(it, PERMISSION_REQUEST_TIMEOUT_MS) }
        try {
            requestPermissions(permissions, GENERAL_PERMISSION_REQUEST_CODE)
        } catch (_: RuntimeException) {
            completeGeneralPermissionFailure("PLATFORM_PERMISSION_REQUEST_FAILED")
        }
    }

    private fun requestNotificationPermission(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
            isPermissionGranted(Manifest.permission.POST_NOTIFICATIONS)
        ) {
            result.success(permissionStatuses())
            return
        }
        if (hasPendingPlatformPermissionRequest()) {
            result.error(
                "PLATFORM_PERMISSION_REQUEST_IN_PROGRESS",
                "A platform permission request is already active.",
                null,
            )
            return
        }
        pendingNotificationPermissionResult = result
        notificationPermissionTimeout = Runnable {
            val pending = pendingNotificationPermissionResult ?: return@Runnable
            clearNotificationPermissionRequest()
            pending.error(
                "PLATFORM_PERMISSION_REQUEST_TIMEOUT",
                "Notification permission did not return in time.",
                null,
            )
        }.also { mainHandler.postDelayed(it, PERMISSION_REQUEST_TIMEOUT_MS) }
        try {
            requestPermissions(
                arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                NOTIFICATION_PERMISSION_REQUEST_CODE,
            )
        } catch (_: RuntimeException) {
            completeNotificationPermissionFailure("PLATFORM_PERMISSION_REQUEST_FAILED")
        }
    }

    private fun requestLocalNetworkPermission(result: MethodChannel.Result) {
        val permissions = localNetworkPermissionsToRequest()
        if (permissions.isEmpty() || permissions.all(::isPermissionGranted)) {
            result.success(permissionStatuses())
            return
        }
        if (hasPendingPlatformPermissionRequest()) {
            result.error(
                "PLATFORM_PERMISSION_REQUEST_IN_PROGRESS",
                "A local-network permission request is already active.",
                null,
            )
            return
        }
        pendingLocalNetworkPermissionResult = result
        localNetworkPermissionTimeout = Runnable {
            val pending = pendingLocalNetworkPermissionResult ?: return@Runnable
            clearLocalNetworkPermissionRequest()
            pending.error(
                "PLATFORM_PERMISSION_REQUEST_TIMEOUT",
                "Local-network permission did not return in time.",
                null,
            )
        }.also { mainHandler.postDelayed(it, PERMISSION_REQUEST_TIMEOUT_MS) }
        try {
            requestPermissions(permissions, RECORDING_CARD_WIFI_PERMISSION_REQUEST_CODE)
        } catch (_: RuntimeException) {
            completeLocalNetworkPermissionFailure("PLATFORM_PERMISSION_REQUEST_FAILED")
        }
    }

    private fun permissionStatuses(): Map<String, String> = mapOf(
        "bluetooth" to bluetoothStatus(),
        "nearby_devices" to bluetoothStatus(),
        "microphone" to runtimePermissionStatus(
            "microphone",
            arrayOf(Manifest.permission.RECORD_AUDIO),
        ),
        "camera" to runtimePermissionStatus(
            "camera",
            arrayOf(Manifest.permission.CAMERA),
        ),
        "media_library" to mediaAudioStatus(),
        "notification" to notificationStatus(),
        "local_network" to localNetworkStatus(),
    )

    private fun bluetoothStatus(): String {
        val permissions = recordingCardBluetoothAccess.runtimePermissions()
        val granted = permissions.all(::isPermissionGranted)
        val shouldShowRationale = permissions.any(::shouldShowRequestPermissionRationale)
        return recordingCardBluetoothPermissionStatus(
            granted = granted,
            requestAttempted = bluetoothPermissionRequestAttempted(),
            shouldShowRationale = shouldShowRationale,
        )
    }

    private fun mediaAudioStatus(): String {
        return runtimePermissionStatus("media_library", mediaAudioPermissionsToRequest())
    }

    private fun notificationStatus(): String {
        if (!NotificationManagerCompat.from(this).areNotificationsEnabled()) {
            return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                runtimePermissionStatus(
                    "notification",
                    arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                )
            } else {
                "blocked"
            }
        }
        return "granted"
    }

    private fun localNetworkStatus(): String {
        return runtimePermissionStatus("local_network", localNetworkPermissionsToRequest())
    }

    private fun runtimePermissionStatus(kind: String, permissions: Array<String>): String {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
            return "granted"
        }
        if (permissions.isEmpty()) return "granted"
        val granted = permissions.all { permission ->
            checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED
        }
        if (granted) return "granted"
        if (!permissionRequestAttempted(kind)) return "not_determined"
        return if (permissions.any(::shouldShowRequestPermissionRationale)) {
            "denied"
        } else {
            "blocked"
        }
    }

    private fun bluetoothPermissionsToRequest(): Array<String> {
        return recordingCardBluetoothAccess.runtimePermissions()
    }

    private fun localNetworkPermissionsToRequest(): Array<String> = when {
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU ->
            arrayOf(Manifest.permission.NEARBY_WIFI_DEVICES)
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.M ->
            arrayOf(Manifest.permission.ACCESS_FINE_LOCATION)
        else -> emptyArray()
    }

    private fun mediaAudioPermissionsToRequest(): Array<String> = when {
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU ->
            arrayOf(Manifest.permission.READ_MEDIA_AUDIO)
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.M ->
            arrayOf(Manifest.permission.READ_EXTERNAL_STORAGE)
        else -> emptyArray()
    }

    private fun generalPermissionsToRequest(kind: String): Array<String> = when (kind) {
        "microphone" -> arrayOf(Manifest.permission.RECORD_AUDIO)
        "camera" -> arrayOf(Manifest.permission.CAMERA)
        "media_library" -> mediaAudioPermissionsToRequest()
        else -> emptyArray()
    }

    private fun isPermissionGranted(permission: String): Boolean {
        return Build.VERSION.SDK_INT < Build.VERSION_CODES.M ||
            checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED
    }

    private fun completeBluetoothPermissionRequest() {
        val pending = pendingBluetoothPermissionResult ?: return
        markBluetoothPermissionRequestAttempted()
        clearBluetoothPermissionRequest()
        pending.success(permissionStatuses())
    }

    private fun completeBluetoothPermissionFailure(code: String) {
        val pending = pendingBluetoothPermissionResult ?: return
        clearBluetoothPermissionRequest()
        pending.error(code, "Bluetooth permission could not be requested.", null)
    }

    private fun cancelBluetoothPermissionRequest() {
        val pending = pendingBluetoothPermissionResult
        clearBluetoothPermissionRequest()
        pending?.error(
            "PLATFORM_PERMISSION_REQUEST_CANCELLED",
            "Bluetooth permission request was cancelled.",
            null,
        )
    }

    private fun clearBluetoothPermissionRequest() {
        bluetoothPermissionTimeout?.let(mainHandler::removeCallbacks)
        bluetoothPermissionTimeout = null
        pendingBluetoothPermissionResult = null
    }

    private fun completeLocalNetworkPermissionRequest() {
        val pending = pendingLocalNetworkPermissionResult ?: return
        markPermissionRequestAttempted("local_network")
        clearLocalNetworkPermissionRequest()
        pending.success(permissionStatuses())
    }

    private fun completeLocalNetworkPermissionFailure(code: String) {
        val pending = pendingLocalNetworkPermissionResult ?: return
        clearLocalNetworkPermissionRequest()
        pending.error(code, "Local-network permission could not be requested.", null)
    }

    private fun cancelLocalNetworkPermissionRequest() {
        val pending = pendingLocalNetworkPermissionResult
        clearLocalNetworkPermissionRequest()
        pending?.error(
            "PLATFORM_PERMISSION_REQUEST_CANCELLED",
            "Local-network permission request was cancelled.",
            null,
        )
    }

    private fun clearLocalNetworkPermissionRequest() {
        localNetworkPermissionTimeout?.let(mainHandler::removeCallbacks)
        localNetworkPermissionTimeout = null
        pendingLocalNetworkPermissionResult = null
    }

    private fun completeNotificationPermissionRequest() {
        val pending = pendingNotificationPermissionResult ?: return
        markPermissionRequestAttempted("notification")
        clearNotificationPermissionRequest()
        pending.success(permissionStatuses())
    }

    private fun completeNotificationPermissionFailure(code: String) {
        val pending = pendingNotificationPermissionResult ?: return
        clearNotificationPermissionRequest()
        pending.error(code, "Notification permission could not be requested.", null)
    }

    private fun cancelNotificationPermissionRequest() {
        val pending = pendingNotificationPermissionResult
        clearNotificationPermissionRequest()
        pending?.error(
            "PLATFORM_PERMISSION_REQUEST_CANCELLED",
            "Notification permission request was cancelled.",
            null,
        )
    }

    private fun clearNotificationPermissionRequest() {
        notificationPermissionTimeout?.let(mainHandler::removeCallbacks)
        notificationPermissionTimeout = null
        pendingNotificationPermissionResult = null
    }

    private fun completeGeneralPermissionRequest() {
        val pending = pendingGeneralPermissionResult ?: return
        pendingGeneralPermissionKind?.let(::markPermissionRequestAttempted)
        clearGeneralPermissionRequest()
        pending.success(permissionStatuses())
    }

    private fun completeGeneralPermissionFailure(code: String) {
        val pending = pendingGeneralPermissionResult ?: return
        clearGeneralPermissionRequest()
        pending.error(code, "Platform permission could not be requested.", null)
    }

    private fun cancelGeneralPermissionRequest() {
        val pending = pendingGeneralPermissionResult
        clearGeneralPermissionRequest()
        pending?.error(
            "PLATFORM_PERMISSION_REQUEST_CANCELLED",
            "Platform permission request was cancelled.",
            null,
        )
    }

    private fun clearGeneralPermissionRequest() {
        generalPermissionTimeout?.let(mainHandler::removeCallbacks)
        generalPermissionTimeout = null
        pendingGeneralPermissionResult = null
        pendingGeneralPermissionKind = null
    }

    private fun openAppSettings(): Boolean {
        return runCatching {
            val intent = Intent(
                Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                Uri.fromParts("package", packageName, null),
            )
            startActivity(intent)
            true
        }.getOrDefault(false)
    }

    private fun openBluetoothSettings(arguments: Map<*, *>?): Boolean {
        if (arguments?.get("target") != "location_services") return false
        return runCatching {
            startActivity(recordingCardBluetoothAccess.locationSettingsIntent())
            true
        }.getOrDefault(false)
    }

    private fun requestBluetoothActivation(result: MethodChannel.Result) {
        val adapter = runCatching { recordingCardBluetoothAccess.adapter }.getOrElse { error ->
            if (error is SecurityException) {
                result.error(
                    "PLATFORM_BLUETOOTH_PERMISSION_REQUIRED",
                    "Bluetooth permission is required.",
                    null,
                )
            } else {
                result.success("unavailable")
            }
            return
        }
        if (adapter == null) {
            result.success("unavailable")
            return
        }
        val isEnabled = runCatching { adapter.isEnabled }.getOrElse { error ->
            if (error is SecurityException) {
                result.error(
                    "PLATFORM_BLUETOOTH_PERMISSION_REQUIRED",
                    "Bluetooth permission is required.",
                    null,
                )
            } else {
                result.success("unavailable")
            }
            return
        }
        if (isEnabled) {
            result.success("enabled")
            return
        }
        if (pendingBluetoothActivationResult != null) {
            result.error(
                "PLATFORM_BLUETOOTH_ACTIVATION_IN_PROGRESS",
                "A Bluetooth activation request is already running.",
                null,
            )
            return
        }
        pendingBluetoothActivationResult = result
        runCatching {
            startActivityForResult(
                Intent(BluetoothAdapter.ACTION_REQUEST_ENABLE),
                BLUETOOTH_ACTIVATION_REQUEST_CODE,
            )
        }.onFailure {
            pendingBluetoothActivationResult = null
            result.success("unavailable")
        }
    }

    private fun bluetoothPermissionRequestAttempted(): Boolean =
        permissionRequestAttempted("bluetooth")

    private fun markBluetoothPermissionRequestAttempted() {
        markPermissionRequestAttempted("bluetooth")
    }

    private fun permissionRequestAttempted(kind: String): Boolean =
        getSharedPreferences(PERMISSION_PREFERENCES, MODE_PRIVATE)
            .getBoolean(permissionRequestKey(kind), false)

    private fun markPermissionRequestAttempted(kind: String) {
        getSharedPreferences(PERMISSION_PREFERENCES, MODE_PRIVATE)
            .edit()
            .putBoolean(permissionRequestKey(kind), true)
            .apply()
    }

    private fun permissionRequestKey(kind: String): String =
        if (kind == "bluetooth" || kind == "nearby_devices") {
            BLUETOOTH_PERMISSION_REQUESTED_KEY
        } else {
            "runtime_request_attempted_$kind"
        }

    private companion object {
        const val PERMISSIONS_CHANNEL = "huahuoai/platform_permissions"
        const val DEVICE_TIME_ZONE_CHANNEL = "huahuoai/device_timezone"
        const val NATIVE_FILE_CHANNEL = "huahuoai/native_file"
        const val INCOMING_MATERIAL_EVENT_CHANNEL = "huahuoai/native_file/incoming"
        const val KNOWLEDGE_EXPORT_CHANNEL = "huahuoai/knowledge_export"
        const val RECORDING_CARD_BLUETOOTH_PERMISSION_REQUEST_CODE = 0x5243
        const val RECORDING_CARD_WIFI_PERMISSION_REQUEST_CODE = 0x5746
        const val NOTIFICATION_PERMISSION_REQUEST_CODE = 0x4E50
        const val GENERAL_PERMISSION_REQUEST_CODE = 0x4750
        const val DOCUMENT_PICKER_REQUEST_CODE = 0x444F
        const val AUDIO_PICKER_REQUEST_CODE = 0x4155
        const val MEDIA_GALLERY_PICKER_REQUEST_CODE = 0x4D47
        const val MEDIA_CAMERA_PICKER_REQUEST_CODE = 0x4D43
        const val CAMERA_MEDIA_PERMISSION_REQUEST_CODE = 0x4D50
        const val RECORDING_EXPORT_SAVE_REQUEST_CODE = 0x4558
        const val BLUETOOTH_ACTIVATION_REQUEST_CODE = 0x4245
        const val PERMISSION_REQUEST_TIMEOUT_MS = 30_000L
        const val PERMISSION_PREFERENCES = "recording_card_bluetooth_permissions"
        const val BLUETOOTH_PERMISSION_REQUESTED_KEY = "runtime_request_attempted"
        val BLUETOOTH_PERMISSION_KINDS = setOf("bluetooth", "nearby_devices")
        val GENERAL_PERMISSION_KINDS = setOf("microphone", "camera", "media_library")
        const val MAX_PENDING_INCOMING_MATERIALS = 16
        val INCOMING_OPAQUE_ID = Regex("^[A-Za-z0-9-]{1,96}$")
        val INCOMING_OPAQUE_REF = Regex("^incoming-material://[A-Za-z0-9-]{1,96}$")
        val SHA_256 = Regex("^[a-f0-9]{64}$")
        const val MAX_INCOMING_DISPLAY_NAME = 240
        const val MAX_INCOMING_MATERIAL_BYTES = 500L * 1024L * 1024L
        const val MAX_PICKED_DOCUMENT_BYTES = 500L * 1024L * 1024L
        const val MAX_PICKED_AUDIO_FILES = 16
        const val MAX_PICKED_AUDIO_BYTES = 500L * 1024L * 1024L
        const val MAX_IMAGE_GALLERY_SAVE_BYTES = 50 * 1024 * 1024
        const val MAX_PICKED_CHAT_IMAGES = 9
        const val MAX_HEIF_IMAGE_DIMENSION = 4096
        val IMAGE_GALLERY_MIME_TYPES = setOf("image/jpeg", "image/png", "image/webp")
        val SUPPORTED_INCOMING_ACTIONS = setOf(
            Intent.ACTION_VIEW,
            Intent.ACTION_SEND,
            Intent.ACTION_SEND_MULTIPLE,
        )
        val SUPPORTED_AUDIO_EXTENSIONS = setOf("mp3", "m4a", "mp4", "wav", "opus")
        val SUPPORTED_DOCUMENT_EXTENSIONS = setOf(
            "txt", "md", "csv", "json", "pdf", "docx", "pptx", "xlsx",
        )
        val LEGACY_DOCUMENT_EXTENSIONS = setOf("doc", "ppt")
        val SUPPORTED_MATERIAL_EXTENSIONS = SUPPORTED_AUDIO_EXTENSIONS + SUPPORTED_DOCUMENT_EXTENSIONS
        val MATERIAL_MIME_TYPES = arrayOf(
            "audio/mpeg",
            "audio/mp4",
            "audio/wav",
            "audio/x-wav",
            "audio/opus",
            "text/plain",
            "text/markdown",
            "text/csv",
            "application/json",
            "application/pdf",
            "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
            "application/vnd.openxmlformats-officedocument.presentationml.presentation",
            "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        )
        val DOCUMENT_MIME_TYPES = arrayOf(
            "text/plain",
            "text/markdown",
            "text/csv",
            "application/json",
            "application/pdf",
            "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
            "application/vnd.openxmlformats-officedocument.presentationml.presentation",
            "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        )
        val AUDIO_MIME_TYPES = arrayOf(
            "audio/mpeg",
            "audio/mp4",
            "audio/x-m4a",
            "audio/wav",
            "audio/x-wav",
            "audio/opus",
            "audio/ogg",
        )
        val MEDIA_KINDS = setOf("image", "video")
        val MEDIA_SOURCES = setOf("camera", "gallery", "files")
        val IMAGE_EXTENSIONS = setOf("jpg", "jpeg", "png", "heic", "heif", "webp")
        val HEIF_EXTENSIONS = setOf("heic", "heif")
        val VIDEO_EXTENSIONS = setOf("mp4", "mov", "webm")
        val VIDEO_MEDIA_MIME_TYPES = setOf("video/mp4", "video/quicktime", "video/webm")
    }

    private data class PendingMediaPicker(
        val result: MethodChannel.Result,
        val kind: String,
        val source: String,
        var outputFile: File? = null,
    )

    private data class PendingRecordingExportSave(
        val result: MethodChannel.Result,
        val location: RecordingExportLocation,
        val displayName: String,
    )

    private data class PendingImageGallerySave(
        val result: MethodChannel.Result,
    )

    private data class PreparedRecordingExport(
        val location: RecordingExportLocation,
        val sourceFile: File,
        val displayName: String,
    )

    private class RecordingExportException(
        val code: String,
        val safeMessage: String,
    ) : RuntimeException()
}
