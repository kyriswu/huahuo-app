import AVFoundation
import CryptoKit
import Flutter
import ImageIO
import Photos
import PhotosUI
import UIKit
import UniformTypeIdentifiers

func preferredNativeAudioImportDisplayName(
  sourceURL: URL,
  destinationURL: URL
) -> String {
  let values = try? sourceURL.resourceValues(forKeys: [
    .localizedNameKey,
    .nameKey,
  ])
  for candidate in [
    values?.localizedName,
    values?.name,
    sourceURL.lastPathComponent,
    destinationURL.lastPathComponent,
  ] {
    let normalized = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if !normalized.isEmpty { return normalized }
  }
  return "recording.m4a"
}

func nativeAudioImportDurationSeconds(
  assetDurationSeconds: Double,
  audioFrameCount: AVAudioFramePosition? = nil,
  sampleRate: Double? = nil
) -> Int? {
  if assetDurationSeconds.isFinite, assetDurationSeconds > 0 {
    let rounded = ceil(assetDurationSeconds)
    return rounded <= Double(Int.max) ? max(1, Int(rounded)) : nil
  }
  guard let audioFrameCount,
    let sampleRate,
    audioFrameCount > 0,
    sampleRate.isFinite,
    sampleRate > 0
  else {
    return nil
  }
  let duration = Double(audioFrameCount) / sampleRate
  guard duration.isFinite, duration > 0 else { return nil }
  let rounded = ceil(duration)
  return rounded <= Double(Int.max) ? max(1, Int(rounded)) : nil
}

enum NativeBoundedFileCopyError: Error {
  case invalidMaximum
  case tooLarge
  case empty
  case incomplete
}

/// Streams a provider file into app-private storage without allowing a false or
/// absent provider size to fill the cache first.
func copyNativeFileBounded(
  sourceURL: URL,
  destinationURL: URL,
  maximumBytes: Int,
  fileManager: FileManager = .default
) throws -> Int {
  guard maximumBytes > 0 else {
    throw NativeBoundedFileCopyError.invalidMaximum
  }
  let sourceValues = try sourceURL.resourceValues(forKeys: [
    .fileSizeKey,
    .isRegularFileKey,
  ])
  guard sourceValues.isRegularFile != false else {
    throw NativeBoundedFileCopyError.incomplete
  }
  if let sourceSize = sourceValues.fileSize, sourceSize > maximumBytes {
    throw NativeBoundedFileCopyError.tooLarge
  }
  guard fileManager.createFile(atPath: destinationURL.path, contents: nil) else {
    throw NativeBoundedFileCopyError.incomplete
  }

  let input: FileHandle
  let output: FileHandle
  do {
    input = try FileHandle(forReadingFrom: sourceURL)
    output = try FileHandle(forWritingTo: destinationURL)
  } catch {
    try? fileManager.removeItem(at: destinationURL)
    throw error
  }
  var completed = false
  defer {
    input.closeFile()
    output.closeFile()
    if !completed {
      try? fileManager.removeItem(at: destinationURL)
    }
  }

  var copiedBytes = 0
  while true {
    let chunk = input.readData(ofLength: 64 * 1024)
    if chunk.isEmpty { break }
    guard chunk.count <= maximumBytes - copiedBytes else {
      throw NativeBoundedFileCopyError.tooLarge
    }
    output.write(chunk)
    copiedBytes += chunk.count
  }
  guard copiedBytes > 0 else {
    throw NativeBoundedFileCopyError.empty
  }
  output.synchronizeFile()
  let destinationSize = try destinationURL.resourceValues(forKeys: [.fileSizeKey])
    .fileSize
  guard destinationSize == copiedBytes else {
    throw NativeBoundedFileCopyError.incomplete
  }
  completed = true
  return copiedBytes
}

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var nativeFilePickerBridge: NativeFilePickerBridge?
  private var knowledgeExportBridge: KnowledgeExportBridge?
  private var glassAccessibilityBridge: GlassAccessibilityBridge?
  private var deviceTimeZoneBridge: DeviceTimeZoneBridge?
  private var plainTextClipboardBridge: PlainTextClipboardBridge?
  private var screenCaptureBridge: ScreenCaptureBridge?
  private var tencentLiveAsrBridge: TencentLiveAsrBridge?
  private var runtimePerformanceBridge: RuntimePerformanceBridge?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    RecordingCardBridge.register(with: engineBridge.applicationRegistrar.messenger())
    PlatformPermissionsBridge.register(
      with: engineBridge.applicationRegistrar.messenger()
    )
    VoiceRecorderBridge.register(
      with: engineBridge.applicationRegistrar.messenger()
    )
    tencentLiveAsrBridge = TencentLiveAsrBridge(
      messenger: engineBridge.applicationRegistrar.messenger()
    )
    screenCaptureBridge = ScreenCaptureBridge(
      messenger: engineBridge.applicationRegistrar.messenger()
    )
    nativeFilePickerBridge = NativeFilePickerBridge(
      messenger: engineBridge.applicationRegistrar.messenger()
    )
    knowledgeExportBridge = KnowledgeExportBridge(
      messenger: engineBridge.applicationRegistrar.messenger()
    )
    glassAccessibilityBridge = GlassAccessibilityBridge(
      messenger: engineBridge.applicationRegistrar.messenger()
    )
    deviceTimeZoneBridge = DeviceTimeZoneBridge(
      messenger: engineBridge.applicationRegistrar.messenger()
    )
    plainTextClipboardBridge = PlainTextClipboardBridge(
      messenger: engineBridge.applicationRegistrar.messenger()
    )
    runtimePerformanceBridge = RuntimePerformanceBridge(
      messenger: engineBridge.applicationRegistrar.messenger()
    )
    HomeWidgetBridge.register(
      with: engineBridge.applicationRegistrar.messenger()
    )
  }
}

private final class PlainTextClipboardBridge: NSObject {
  private let methodChannel: FlutterMethodChannel

  init(messenger: FlutterBinaryMessenger) {
    methodChannel = FlutterMethodChannel(
      name: "huahuoai/plain_text_clipboard",
      binaryMessenger: messenger
    )
    super.init()
    methodChannel.setMethodCallHandler { call, result in
      guard call.method == "readPlainText" else {
        result(FlutterMethodNotImplemented)
        return
      }
      if let text = UIPasteboard.general.string {
        result(String(text))
      } else {
        result(nil)
      }
    }
  }
}

private final class DeviceTimeZoneBridge: NSObject {
  private let methodChannel: FlutterMethodChannel

  init(messenger: FlutterBinaryMessenger) {
    methodChannel = FlutterMethodChannel(
      name: "huahuoai/device_timezone",
      binaryMessenger: messenger
    )
    super.init()
    methodChannel.setMethodCallHandler { call, result in
      switch call.method {
      case "getTimeZone":
        result(TimeZone.current.identifier)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}

final class NativeFilePickerBridge: NSObject, UIDocumentPickerDelegate,
  UIImagePickerControllerDelegate,
  UINavigationControllerDelegate,
  FlutterStreamHandler
{
  private static weak var shared: NativeFilePickerBridge?
  private static var queuedIncomingURLs: [URL] = []
  private let methodChannel: FlutterMethodChannel
  private let incomingEventChannel: FlutterEventChannel
  private var incomingEventSink: FlutterEventSink?
  private var pendingIncomingMaterials: [[String: Any]] = []
  private var pendingIncomingMaterialErrors: [String] = []
  private var pendingResult: FlutterResult?
  private var pendingPickerKind: PickerKind?
  private var pendingMediaKind: MediaKind?
  private var presentedActivityController: UIActivityViewController?
  private var pendingImageGallerySaveResult: FlutterResult?
  private var isDrainingSharedIncomingMaterials = false

  private enum PickerKind {
    case audio
    case document
    case mediaFile
    case audioExport
  }

  private enum MediaKind {
    case image
    case video
  }

  init(messenger: FlutterBinaryMessenger) {
    methodChannel = FlutterMethodChannel(
      name: "huahuoai/native_file",
      binaryMessenger: messenger
    )
    incomingEventChannel = FlutterEventChannel(
      name: "huahuoai/native_file/incoming",
      binaryMessenger: messenger
    )
    super.init()
    Self.shared = self
    incomingEventChannel.setStreamHandler(self)

    methodChannel.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(
          FlutterError(
            code: "NATIVE_FILE_PICKER_UNAVAILABLE",
            message: "Native file picker bridge is unavailable.",
            details: nil
          )
        )
        return
      }
      self.handle(call: call, result: result)
    }
    restoreIncomingMaterials()
    receiveSharedIncomingMaterials()
    receiveIncomingURLs(Self.queuedIncomingURLs)
    Self.queuedIncomingURLs.removeAll()
  }

  static func enqueueIncomingURLs(_ urls: [URL]) {
    guard !urls.isEmpty else { return }
    if let shared {
      shared.receiveIncomingURLs(urls)
      return
    }
    queuedIncomingURLs.append(contentsOf: urls)
    if queuedIncomingURLs.count > 16 {
      queuedIncomingURLs.removeFirst(queuedIncomingURLs.count - 16)
    }
  }

  static func enqueueSharedIncomingMaterials() {
    if let shared {
      shared.receiveSharedIncomingMaterials()
    }
  }

  func onListen(
    withArguments arguments: Any?,
    eventSink events: @escaping FlutterEventSink
  ) -> FlutterError? {
    incomingEventSink = events
    if !pendingIncomingMaterials.isEmpty || !pendingIncomingMaterialErrors.isEmpty {
      events("pending")
    }
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    incomingEventSink = nil
    return nil
  }

  private func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "consumeIncomingMaterials":
      result(pendingIncomingMaterials)
    case "consumeIncomingMaterialErrors":
      let errors = pendingIncomingMaterialErrors
      pendingIncomingMaterialErrors.removeAll()
      result(errors)
    case "acknowledgeIncomingMaterials":
      acknowledgeIncomingMaterials(
        call.arguments as? [String: Any],
        result: result
      )
    case "pickAudioFiles":
      pickAudioFiles(result)
    case "pickDocumentFiles":
      pickDocumentFiles(result)
    case "pickMediaFiles":
      pickMediaFiles(call.arguments as? [String: Any], result: result)
    case "saveImageToGallery":
      saveImageToGallery(call.arguments as? [String: Any], result: result)
    case "savePreparedAudioExport":
      savePreparedAudioExport(call.arguments as? [String: Any], result: result)
    case "openPreparedAudioExport":
      openPreparedAudioExport(call.arguments as? [String: Any], result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private var hasPendingNativeFileInteraction: Bool {
    pendingResult != nil ||
      pendingImageGallerySaveResult != nil ||
      presentedActivityController != nil
  }

  private func saveImageToGallery(
    _ args: [String: Any]?,
    result: @escaping FlutterResult
  ) {
    guard !hasPendingNativeFileInteraction,
      let args,
      let typedData = args["bytes"] as? FlutterStandardTypedData,
      let displayName = args["displayName"] as? String,
      let mimeType = args["mimeType"] as? String,
      Self.isSafeImageGalleryRequest(
        bytes: typedData.data,
        displayName: displayName,
        mimeType: mimeType
      )
    else {
      result(
        FlutterError(
          code: "NATIVE_IMAGE_SAVE_INVALID",
          message: "Image save request is invalid.",
          details: nil
        )
      )
      return
    }
    pendingImageGallerySaveResult = result
    let authorization: (PHAuthorizationStatus) -> Void = { [weak self] status in
      guard let self else { return }
      guard self.hasPhotoLibraryAddAuthorization(status) else {
        self.finishImageGallerySave(
          FlutterError(
            code: "NATIVE_IMAGE_SAVE_PERMISSION_DENIED",
            message: "Photo library add permission was not granted.",
            details: nil
          )
        )
        return
      }
      let options = PHAssetResourceCreationOptions()
      options.originalFilename = displayName
      PHPhotoLibrary.shared().performChanges({
        let request = PHAssetCreationRequest.forAsset()
        request.addResource(with: .photo, data: typedData.data, options: options)
      }) { [weak self] success, _ in
        DispatchQueue.main.async {
          self?.finishImageGallerySave(
            success
              ? true
              : FlutterError(
                  code: "NATIVE_IMAGE_SAVE_FAILED",
                  message: "Image could not be saved to the photo library.",
                  details: nil
                )
          )
        }
      }
    }
    if #available(iOS 14.0, *) {
      PHPhotoLibrary.requestAuthorization(for: .addOnly, handler: authorization)
    } else {
      PHPhotoLibrary.requestAuthorization(authorization)
    }
  }

  private func finishImageGallerySave(_ value: Any?) {
    let result = pendingImageGallerySaveResult
    pendingImageGallerySaveResult = nil
    result?(value)
  }

  private func hasPhotoLibraryAddAuthorization(_ status: PHAuthorizationStatus) -> Bool {
    if status == .authorized { return true }
    if #available(iOS 14.0, *) { return status == .limited }
    return false
  }

  private func savePreparedAudioExport(
    _ args: [String: Any]?,
    result: @escaping FlutterResult
  ) {
    guard !hasPendingNativeFileInteraction else {
      result(nativePreparedAudioExportFlutterError(.busy))
      return
    }
    guard let presenter = Self.topViewController(), presenter.viewIfLoaded?.window != nil else {
      result(nativePreparedAudioExportFlutterError(.unavailable))
      return
    }
    do {
      let exportURL = try preparedAudioExportURL(args)
      pendingResult = result
      pendingPickerKind = .audioExport
      let picker: UIDocumentPickerViewController
      if #available(iOS 14.0, *) {
        picker = UIDocumentPickerViewController(forExporting: [exportURL], asCopy: true)
      } else {
        picker = UIDocumentPickerViewController(url: exportURL, in: .exportToService)
      }
      picker.delegate = self
      picker.allowsMultipleSelection = false
      presenter.present(picker, animated: true)
    } catch let error as NativePreparedAudioExportError {
      result(nativePreparedAudioExportFlutterError(error))
    } catch {
      result(nativePreparedAudioExportFlutterError(.unreadable))
    }
  }

  private func openPreparedAudioExport(
    _ args: [String: Any]?,
    result: @escaping FlutterResult
  ) {
    guard !hasPendingNativeFileInteraction else {
      result(nativePreparedAudioExportFlutterError(.busy))
      return
    }
    guard let presenter = Self.topViewController(), presenter.viewIfLoaded?.window != nil else {
      result(nativePreparedAudioExportFlutterError(.unavailable))
      return
    }
    do {
      let exportURL = try preparedAudioExportURL(args)
      let activity = UIActivityViewController(
        activityItems: [exportURL],
        applicationActivities: nil
      )
      if let popover = activity.popoverPresentationController {
        popover.sourceView = presenter.view
        popover.sourceRect = CGRect(
          x: presenter.view.bounds.midX,
          y: presenter.view.bounds.maxY,
          width: 1,
          height: 1
        )
        popover.permittedArrowDirections = []
      }
      activity.completionWithItemsHandler = { [weak self, weak activity] _, _, _, _ in
        guard let self, self.presentedActivityController === activity else { return }
        self.presentedActivityController = nil
      }
      presentedActivityController = activity
      presenter.present(activity, animated: true) {
        result(true)
      }
    } catch let error as NativePreparedAudioExportError {
      result(nativePreparedAudioExportFlutterError(error))
    } catch {
      result(nativePreparedAudioExportFlutterError(.unreadable))
    }
  }

  private func preparedAudioExportURL(_ args: [String: Any]?) throws -> URL {
    guard let args,
      let opaqueExportRef = args["opaqueExportRef"] as? String,
      let displayName = args["displayName"] as? String,
      let mimeType = args["mimeType"] as? String,
      !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      mimeType.lowercased().hasPrefix("audio/")
    else {
      throw NativePreparedAudioExportError.invalidRequest
    }
    let fileManager = FileManager.default
    guard let applicationSupportRoot = fileManager.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    ).first else {
      throw NativePreparedAudioExportError.unavailable
    }
    return try resolveNativePreparedAudioExportReference(
      opaqueExportRef,
      applicationSupportRoot: applicationSupportRoot,
      fileManager: fileManager
    )
  }

  private func pickAudioFiles(_ result: @escaping FlutterResult) {
    presentPicker(
      documentTypes: ["public.audio"],
      kind: .audio,
      result: result
    )
  }

  private func pickDocumentFiles(_ result: @escaping FlutterResult) {
    presentPicker(
      documentTypes: Self.documentTypeIdentifiers,
      kind: .document,
      result: result
    )
  }

  private func pickMediaFiles(_ args: [String: Any]?, result: @escaping FlutterResult) {
    guard let kind = mediaKind(args?["kind"] as? String),
      let source = args?["source"] as? String
    else {
      result(FlutterError(code: "NATIVE_MEDIA_PICKER_INVALID", message: "Media picker request is invalid.", details: nil))
      return
    }
    guard !hasPendingNativeFileInteraction,
      let presenter = Self.topViewController()
    else {
      result(FlutterError(code: "NATIVE_MEDIA_PICKER_UNAVAILABLE", message: "Media picker is unavailable.", details: nil))
      return
    }
    pendingResult = result
    pendingMediaKind = kind
    if source == "gallery" {
      if #available(iOS 14.0, *) {
        presentGalleryMediaPicker(kind: kind, presenter: presenter)
      } else {
        finish(FlutterError(code: "NATIVE_MEDIA_PICKER_UNAVAILABLE", message: "Gallery selection requires iOS 14 or newer.", details: nil))
      }
      return
    }
    if source == "files" {
      pendingPickerKind = .mediaFile
      let identifier = kind == .image ? UTType.image.identifier : UTType.movie.identifier
      let picker = UIDocumentPickerViewController(
        documentTypes: [identifier],
        in: .import
      )
      picker.delegate = self
      picker.allowsMultipleSelection = kind == .image
      presenter.present(picker, animated: true)
      return
    }
    guard source == "camera", UIImagePickerController.isSourceTypeAvailable(.camera) else {
      finish(FlutterError(code: "NATIVE_MEDIA_CAMERA_UNAVAILABLE", message: "Camera is unavailable.", details: nil))
      return
    }
    let picker = UIImagePickerController()
    picker.sourceType = .camera
    picker.mediaTypes = [kind == .image ? "public.image" : "public.movie"]
    picker.delegate = self
    presenter.present(picker, animated: true)
  }

  @available(iOS 14.0, *)
  private func presentGalleryMediaPicker(kind: MediaKind, presenter: UIViewController) {
    var configuration = PHPickerConfiguration(photoLibrary: .shared())
    configuration.selectionLimit = kind == .image ? 9 : 1
    configuration.filter = kind == .image ? .images : .videos
    let picker = PHPickerViewController(configuration: configuration)
    picker.delegate = self
    presenter.present(picker, animated: true)
  }

  private func presentPicker(
    documentTypes: [String],
    kind: PickerKind,
    result: @escaping FlutterResult
  ) {
    guard !hasPendingNativeFileInteraction else {
      result(
        FlutterError(
          code: "NATIVE_FILE_PICKER_BUSY",
          message: "A native file picker request is already active.",
          details: nil
        )
      )
      return
    }
    guard let presenter = Self.topViewController() else {
      result(
        FlutterError(
          code: "NATIVE_FILE_PICKER_UNAVAILABLE",
          message: "No view controller is available to present the file picker.",
          details: nil
        )
      )
      return
    }

    pendingResult = result
    pendingPickerKind = kind
    let picker = UIDocumentPickerViewController(
      documentTypes: documentTypes,
      in: .import
    )
    picker.delegate = self
    picker.allowsMultipleSelection = true
    presenter.present(picker, animated: true)
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    finish(pendingPickerKind == .audioExport ? false : nil)
  }

  func documentPicker(
    _ controller: UIDocumentPickerViewController,
    didPickDocumentsAt urls: [URL]
  ) {
    guard !urls.isEmpty else {
      finish(pendingPickerKind == .audioExport ? false : nil)
      return
    }
    do {
      guard let pendingPickerKind else {
        throw NativeFilePickerError.missingPickerKind
      }
      if pendingPickerKind == .audioExport {
        finish(true)
        return
      }
      let selectedURLs = pendingPickerKind == .audio
        ? urls.prefix(Self.maximumPickedAudioFiles)
        : urls[...]
      let payload = try selectedURLs.map { url in
        switch pendingPickerKind {
        case .audio:
          return try copyPickedAudioURL(url)
        case .document:
          return try copyPickedDocumentURL(url)
        case .mediaFile:
          guard let mediaKind = pendingMediaKind else {
            throw NativeFilePickerError.unsupportedMedia
          }
          return try copyPickedMediaURL(url, kind: mediaKind)
        case .audioExport:
          preconditionFailure("Audio export is handled before import mapping")
        }
      }
      finish(payload)
    } catch {
      finish(
        FlutterError(
          code: "NATIVE_FILE_PICKER_FAILED",
          message: "Native file picker failed to prepare selected audio.",
          details: nil
        )
      )
    }
  }

  @available(iOS 14.0, *)
  func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
    picker.dismiss(animated: true)
    guard let kind = pendingMediaKind, !results.isEmpty else {
      finish(nil)
      return
    }
    let typeIdentifier = kind == .image ? UTType.image.identifier : UTType.movie.identifier
    let group = DispatchGroup()
    let lock = NSLock()
    var payloads = Array<[String: Any]?>(repeating: nil, count: results.count)
    var failed = false
    for (index, selected) in results.enumerated() {
      group.enter()
      selected.itemProvider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { [weak self] url, error in
        defer { group.leave() }
        guard let self, error == nil, let url else {
          lock.lock()
          failed = true
          lock.unlock()
          return
        }
        do {
          let payload = try self.copyPickedMediaURL(url, kind: kind)
          lock.lock()
          payloads[index] = payload
          lock.unlock()
        } catch {
          lock.lock()
          failed = true
          lock.unlock()
        }
      }
    }
    group.notify(queue: .main) { [weak self] in
      guard let self else { return }
      if failed || payloads.contains(where: { $0 == nil }) {
        self.finish(FlutterError(code: "NATIVE_MEDIA_PICKER_FAILED", message: "Media picker failed to prepare selected media.", details: nil))
        return
      }
      self.finish(payloads.compactMap { $0 })
    }
  }

  func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
    picker.dismiss(animated: true)
    finish(nil)
  }

  func imagePickerController(
    _ picker: UIImagePickerController,
    didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
  ) {
    picker.dismiss(animated: true)
    guard let kind = pendingMediaKind else {
      finish(nil)
      return
    }
    do {
      let payload: [String: Any]
      if kind == .image, let image = info[.originalImage] as? UIImage,
        let data = image.jpegData(compressionQuality: 0.92)
      {
        payload = try copyCameraImage(data)
      } else if kind == .video, let url = info[.mediaURL] as? URL {
        payload = try copyPickedMediaURL(url, kind: kind)
      } else {
        throw NativeFilePickerError.unsupportedMedia
      }
      finish([payload])
    } catch {
      finish(FlutterError(code: "NATIVE_MEDIA_PICKER_FAILED", message: "Camera media could not be prepared.", details: nil))
    }
  }

  private func finish(_ value: Any?) {
    let result = pendingResult
    pendingResult = nil
    pendingPickerKind = nil
    pendingMediaKind = nil
    result?(value)
  }

  private func copyPickedAudioURL(_ url: URL) throws -> [String: Any] {
    let displayName = preferredNativeAudioImportDisplayName(
      sourceURL: url,
      destinationURL: url
    )
    guard let safeDisplayName = Self.safeImportedDisplayName(displayName) else {
      throw NativeFilePickerError.unsafeDisplayName
    }
    let fileExtension = URL(fileURLWithPath: safeDisplayName).pathExtension.lowercased()
    guard Self.supportedAudioExtensions.contains(fileExtension) else {
      throw NativeFilePickerError.unsupportedAudio
    }
    var payload = try copyPickedURL(
      url,
      fallbackExtension: fileExtension,
      mimeType: Self.mimeType(for: fileExtension),
      maximumBytes: Self.maximumPickedAudioBytes
    )
    guard let sourcePath = payload["sourcePath"] as? String else {
      throw NativeFilePickerError.unreadableFile
    }
    let destination = URL(fileURLWithPath: sourcePath)
    payload["displayName"] = safeDisplayName
    if let duration = audioImportDurationSeconds(at: destination) {
      payload["durationSeconds"] = duration
    }
    return payload
  }

  private func audioImportDurationSeconds(at url: URL) -> Int? {
    let assetDuration = CMTimeGetSeconds(AVURLAsset(url: url).duration)
    if let duration = nativeAudioImportDurationSeconds(
      assetDurationSeconds: assetDuration
    ) {
      return duration
    }
    guard let audioFile = try? AVAudioFile(forReading: url) else {
      return nil
    }
    return nativeAudioImportDurationSeconds(
      assetDurationSeconds: assetDuration,
      audioFrameCount: audioFile.length,
      sampleRate: audioFile.fileFormat.sampleRate
    )
  }

  private func copyPickedDocumentURL(_ url: URL) throws -> [String: Any] {
    let fileExtension = url.pathExtension.lowercased()
    guard Self.supportedDocumentExtensions.contains(fileExtension) else {
      throw NativeFilePickerError.unsupportedDocument
    }
    let payload = try copyPickedURL(
      url,
      fallbackExtension: fileExtension,
      mimeType: Self.documentMimeType(for: fileExtension),
      maximumBytes: Self.maximumPickedDocumentBytes
    )
    return payload
  }

  private func receiveIncomingURLs(_ urls: [URL]) {
    guard !urls.isEmpty else { return }
    for url in urls.prefix(16) {
      do {
        let payload = try copyIncomingURL(url)
        if pendingIncomingMaterials.count >= 16 {
          deleteIncomingMaterial(pendingIncomingMaterials.removeFirst())
        }
        pendingIncomingMaterials.append(payload)
      } catch {
        if pendingIncomingMaterialErrors.count >= 16 {
          pendingIncomingMaterialErrors.removeFirst()
        }
        pendingIncomingMaterialErrors.append(incomingMaterialErrorCode(error))
      }
    }
    if !pendingIncomingMaterials.isEmpty || !pendingIncomingMaterialErrors.isEmpty {
      incomingEventSink?("pending")
    }
  }

  private func receiveSharedIncomingMaterials() {
    guard !isDrainingSharedIncomingMaterials else { return }
    let sharedItems = IncomingMaterialShareStore.pendingItems()
    guard !sharedItems.isEmpty else { return }
    isDrainingSharedIncomingMaterials = true

    // The extension only stages an App Group copy. Move each item through the
    // existing private, hashed manifest queue off the main scene lifecycle.
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      guard let self else { return }
      var copiedPayloads: [[String: Any]] = []
      var failureCodes: [String] = []
      for item in sharedItems {
        guard let sourceURL = IncomingMaterialShareStore.materialURL(for: item)
        else {
          IncomingMaterialShareStore.remove(item)
          failureCodes.append("INCOMING_MATERIAL_UNREADABLE")
          continue
        }
        do {
          let payload = try self.copyIncomingURL(
            sourceURL,
            origin: item.origin,
            displayName: item.displayName,
            opaqueID: item.id
          )
          IncomingMaterialShareStore.remove(item)
          copiedPayloads.append(payload)
        } catch {
          IncomingMaterialShareStore.remove(item)
          failureCodes.append(self.incomingMaterialErrorCode(error))
        }
      }
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        self.isDrainingSharedIncomingMaterials = false
        for payload in copiedPayloads {
          guard let opaqueRef = payload["opaqueRef"] as? String,
            !self.pendingIncomingMaterials.contains(where: {
              ($0["opaqueRef"] as? String) == opaqueRef
            })
          else {
            continue
          }
          if self.pendingIncomingMaterials.count >= 16 {
            self.deleteIncomingMaterial(self.pendingIncomingMaterials.removeFirst())
          }
          self.pendingIncomingMaterials.append(payload)
        }
        for code in failureCodes {
          if self.pendingIncomingMaterialErrors.count >= 16 {
            self.pendingIncomingMaterialErrors.removeFirst()
          }
          self.pendingIncomingMaterialErrors.append(code)
        }
        if !copiedPayloads.isEmpty || !failureCodes.isEmpty {
          self.incomingEventSink?("pending")
        }
      }
    }
  }

  private func incomingMaterialErrorCode(_ error: Error) -> String {
    if let boundedError = error as? NativeBoundedFileCopyError {
      switch boundedError {
      case .tooLarge:
        return "INCOMING_MATERIAL_TOO_LARGE"
      case .empty:
        return "INCOMING_MATERIAL_EMPTY"
      case .invalidMaximum, .incomplete:
        return "INCOMING_MATERIAL_UNREADABLE"
      }
    }
    if let sharedError = error as? IncomingMaterialShareStoreError {
      switch sharedError {
      case .tooLarge:
        return "INCOMING_MATERIAL_TOO_LARGE"
      case .empty:
        return "INCOMING_MATERIAL_EMPTY"
      case .unsupportedFormat, .invalidManifest, .invalidOrigin:
        return "INCOMING_MATERIAL_FORMAT_UNSUPPORTED"
      case .appGroupUnavailable, .unreadable:
        return "INCOMING_MATERIAL_UNREADABLE"
      }
    }
    if let pickerError = error as? NativeFilePickerError {
      switch pickerError {
      case .unsupportedDocument, .unsupportedAudio, .unsafeDisplayName:
        return "INCOMING_MATERIAL_FORMAT_UNSUPPORTED"
      case .missingPickerKind, .unsupportedMedia, .unreadableFile:
        return "INCOMING_MATERIAL_UNREADABLE"
      }
    }
    return "INCOMING_MATERIAL_UNREADABLE"
  }

  private func copyIncomingURL(
    _ url: URL,
    origin: String = "open",
    displayName: String? = nil,
    opaqueID: String? = nil
  ) throws -> [String: Any] {
    guard origin == "open" || origin == "send" || origin == "sendMultiple"
    else {
      throw IncomingMaterialShareStoreError.invalidOrigin
    }
    if let opaqueID {
      guard Self.incomingOpaqueIDPattern.wholeMatch(in: opaqueID) else {
        throw IncomingMaterialShareStoreError.invalidManifest
      }
      if let existing = existingIncomingMaterial(opaqueID: opaqueID) {
        return existing
      }
    }
    let fileExtension = url.pathExtension.lowercased()
    guard Self.supportedMaterialExtensions.contains(fileExtension) else {
      throw NativeFilePickerError.unsupportedDocument
    }
    let requestedDisplayName = displayName ?? url.lastPathComponent
    guard let safeDisplayName = Self.safeImportedDisplayName(requestedDisplayName),
      URL(fileURLWithPath: safeDisplayName).pathExtension.lowercased() == fileExtension
    else {
      throw NativeFilePickerError.unsafeDisplayName
    }
    var payload = try copyPickedURL(
      url,
      fallbackExtension: fileExtension,
      mimeType: Self.materialMimeType(for: fileExtension),
      directoryName: "huahuoai-incoming-materials",
      persistent: true,
      maximumBytes: Self.maximumIncomingMaterialBytes
    )
    guard let sourcePath = payload["sourcePath"] as? String,
      let sizeBytes = payload["sizeBytes"] as? Int,
      sizeBytes > 0,
      sizeBytes <= Self.maximumIncomingMaterialBytes
    else {
      throw NativeFilePickerError.unsupportedDocument
    }
    let resolvedOpaqueID = opaqueID ?? UUID().uuidString
    payload["opaqueRef"] = "incoming-material://\(resolvedOpaqueID)"
    payload["displayName"] = safeDisplayName
    payload["origin"] = origin
    payload["kind"] = Self.supportedAudioExtensions.contains(fileExtension)
      ? "audio" : "document"
    payload["sourcePath"] = sourcePath
    payload.removeValue(forKey: "sourceIdentifier")
    let destination = URL(fileURLWithPath: sourcePath)
    payload["contentHash"] = try Self.sha256Hex(destination)
    do {
      try persistIncomingMaterial(payload)
    } catch {
      try? FileManager.default.removeItem(at: destination)
      throw error
    }
    return payload
  }

  private func acknowledgeIncomingMaterials(
    _ arguments: [String: Any]?,
    result: @escaping FlutterResult
  ) {
    let refs = Set((arguments?["opaqueRefs"] as? [String] ?? []).filter {
      Self.incomingOpaqueRefPattern.wholeMatch(in: $0)
    })
    let discardFiles = arguments?["discardFiles"] as? Bool ?? true
    guard !refs.isEmpty else {
      result(FlutterError(
        code: "INCOMING_MATERIAL_ACK_INVALID",
        message: "Incoming material acknowledgement was invalid.",
        details: nil
      ))
      return
    }
    let acknowledged = pendingIncomingMaterials.filter {
      guard let ref = $0["opaqueRef"] as? String else { return false }
      return refs.contains(ref)
    }
    guard acknowledged.count == refs.count else {
      result(FlutterError(
        code: "INCOMING_MATERIAL_ACK_NOT_FOUND",
        message: "An incoming material acknowledgement was stale.",
        details: nil
      ))
      return
    }
    pendingIncomingMaterials.removeAll {
      guard let ref = $0["opaqueRef"] as? String else { return false }
      return refs.contains(ref)
    }
    for payload in acknowledged {
      deleteIncomingMaterial(payload, discardFile: discardFiles)
    }
    result(true)
  }

  private func persistIncomingMaterial(_ payload: [String: Any]) throws {
    guard let opaqueRef = payload["opaqueRef"] as? String,
      let opaqueID = opaqueRef.split(separator: "/").last.map(String.init),
      Self.incomingOpaqueIDPattern.wholeMatch(in: opaqueID)
    else {
      throw NativeFilePickerError.unsupportedDocument
    }
    let directory = try incomingMaterialDirectory()
    let manifest = directory.appendingPathComponent(opaqueID).appendingPathExtension("json")
    let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    try data.write(to: manifest, options: [.atomic])
  }

  private func existingIncomingMaterial(opaqueID: String) -> [String: Any]? {
    guard Self.incomingOpaqueIDPattern.wholeMatch(in: opaqueID),
      let directory = try? incomingMaterialDirectory()
    else {
      return nil
    }
    let manifest = directory.appendingPathComponent(opaqueID).appendingPathExtension("json")
    guard let data = try? Data(contentsOf: manifest),
      let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      validateIncomingMaterial(payload, directory: directory)
    else {
      try? FileManager.default.removeItem(at: manifest)
      return nil
    }
    return payload
  }

  private func restoreIncomingMaterials() {
    pendingIncomingMaterials.removeAll()
    guard let directory = try? incomingMaterialDirectory(),
      let manifests = try? FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: [.contentModificationDateKey],
        options: [.skipsHiddenFiles]
      )
    else { return }
    let sorted = manifests
      .filter { $0.pathExtension.lowercased() == "json" }
      .sorted {
        let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?
          .contentModificationDate ?? .distantPast
        let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?
          .contentModificationDate ?? .distantPast
        return left < right
      }
    for manifest in sorted.suffix(16) {
      guard let data = try? Data(contentsOf: manifest),
        let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        validateIncomingMaterial(payload, directory: directory)
      else {
        try? FileManager.default.removeItem(at: manifest)
        continue
      }
      pendingIncomingMaterials.append(payload)
    }
    for manifest in sorted.dropLast(min(sorted.count, 16)) {
      if let data = try? Data(contentsOf: manifest),
        let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
      {
        deleteIncomingMaterial(payload)
      } else {
        try? FileManager.default.removeItem(at: manifest)
      }
    }
  }

  private func validateIncomingMaterial(
    _ payload: [String: Any],
    directory: URL
  ) -> Bool {
    guard let opaqueRef = payload["opaqueRef"] as? String,
      Self.incomingOpaqueRefPattern.wholeMatch(in: opaqueRef),
      let displayName = payload["displayName"] as? String,
      let mimeType = payload["mimeType"] as? String,
      let kind = payload["kind"] as? String,
      let sourcePath = payload["sourcePath"] as? String,
      let expectedHash = payload["contentHash"] as? String,
      Self.sha256Pattern.wholeMatch(in: expectedHash),
      let expectedSize = (payload["sizeBytes"] as? NSNumber)?.intValue,
      expectedSize > 0,
      expectedSize <= Self.maximumIncomingMaterialBytes
    else { return false }
    let fileExtension = URL(fileURLWithPath: displayName).pathExtension.lowercased()
    guard Self.supportedMaterialExtensions.contains(fileExtension) else { return false }
    if Self.supportedDocumentExtensions.contains(fileExtension) {
      guard kind == "document",
        mimeType.lowercased() == Self.documentMimeType(for: fileExtension)
      else { return false }
    } else if kind != "audio" {
      return false
    }
    let file = URL(fileURLWithPath: sourcePath).resolvingSymlinksInPath().standardizedFileURL
    let root = directory.resolvingSymlinksInPath().standardizedFileURL
    guard file.deletingLastPathComponent() == root,
      let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
      values.isRegularFile == true,
      values.fileSize == expectedSize,
      (try? Self.sha256Hex(file)) == expectedHash
    else { return false }
    return true
  }

  private func deleteIncomingMaterial(
    _ payload: [String: Any],
    discardFile: Bool = true
  ) {
    guard let directory = try? incomingMaterialDirectory() else { return }
    if let opaqueRef = payload["opaqueRef"] as? String,
      let opaqueID = opaqueRef.split(separator: "/").last.map(String.init),
      Self.incomingOpaqueIDPattern.wholeMatch(in: opaqueID)
    {
      try? FileManager.default.removeItem(
        at: directory.appendingPathComponent(opaqueID).appendingPathExtension("json")
      )
    }
    guard discardFile, let sourcePath = payload["sourcePath"] as? String else { return }
    let file = URL(fileURLWithPath: sourcePath).resolvingSymlinksInPath().standardizedFileURL
    let root = directory.resolvingSymlinksInPath().standardizedFileURL
    if file.deletingLastPathComponent() == root {
      try? FileManager.default.removeItem(at: file)
    }
  }

  private func incomingMaterialDirectory() throws -> URL {
    let manager = FileManager.default
    let base = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
      .first ?? manager.temporaryDirectory
    let directory = base
      .appendingPathComponent("HuahuoAI", isDirectory: true)
      .appendingPathComponent("IncomingMaterials", isDirectory: true)
    try manager.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  private func copyPickedMediaURL(_ url: URL, kind: MediaKind) throws -> [String: Any] {
    let displayName = (try? url.resourceValues(forKeys: [.localizedNameKey]))?.localizedName
      ?? url.lastPathComponent
    let extensionName = url.pathExtension.isEmpty
      ? (kind == .image ? "jpg" : "mp4")
      : url.pathExtension.lowercased()
    if kind == .image, Self.isHEIFExtension(extensionName) {
      let destination = try copyHEIFImageAsJPEG(url)
      return try mediaPayload(
        destination,
        kind: kind,
        displayName: Self.jpegDisplayName(displayName)
      )
    }
    let destination = try mediaDestination(extensionName)
    try FileManager.default.copyItem(at: url, to: destination)
    return try mediaPayload(destination, kind: kind, displayName: displayName)
  }

  private func copyHEIFImageAsJPEG(_ url: URL) throws -> URL {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
      throw NativeFilePickerError.unsupportedMedia
    }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: 4096,
    ]
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
      let data = UIImage(cgImage: image).jpegData(compressionQuality: 0.92),
      !data.isEmpty,
      data.count <= Self.maxChatImageBytes
    else {
      throw NativeFilePickerError.unsupportedMedia
    }
    let destination = try mediaDestination("jpg")
    try data.write(to: destination, options: .atomic)
    return destination
  }

  private func copyCameraImage(_ data: Data) throws -> [String: Any] {
    let destination = try mediaDestination("jpg")
    try data.write(to: destination, options: .atomic)
    return try mediaPayload(destination, kind: .image)
  }

  private func mediaDestination(_ extensionName: String) throws -> URL {
    let fileManager = FileManager.default
    let directory = (fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
      ?? fileManager.temporaryDirectory)
      .appendingPathComponent("huahuoai-native-media-picker", isDirectory: true)
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent(UUID().uuidString).appendingPathExtension(extensionName)
  }

  private func mediaPayload(
    _ url: URL,
    kind: MediaKind,
    displayName: String? = nil
  ) throws -> [String: Any] {
    let values = try url.resourceValues(forKeys: [.fileSizeKey, .localizedNameKey])
    let resolvedDisplayName = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
    let fallbackDisplayName = values.localizedName ?? url.lastPathComponent
    return [
      "displayName": (resolvedDisplayName?.isEmpty == false)
        ? resolvedDisplayName!
        : fallbackDisplayName,
      "mimeType": Self.mediaMimeType(for: url.pathExtension, kind: kind),
      "sizeBytes": values.fileSize ?? 0,
      "sourcePath": url.path,
    ]
  }

  private func copyPickedURL(
    _ url: URL,
    fallbackExtension: String,
    mimeType: String,
    directoryName: String = "huahuoai-native-file-picker",
    persistent: Bool = false,
    maximumBytes: Int
  ) throws -> [String: Any] {
    let didAccess = url.startAccessingSecurityScopedResource()
    defer {
      if didAccess {
        url.stopAccessingSecurityScopedResource()
      }
    }

    let fileManager = FileManager.default
    let originalDisplayName = (try? url.resourceValues(forKeys: [.localizedNameKey]))?.localizedName
      ?? url.lastPathComponent
    guard let safeDisplayName = Self.safeImportedDisplayName(originalDisplayName) else {
      throw NativeFilePickerError.unsafeDisplayName
    }
    let importDirectory: URL
    if persistent {
      let base = fileManager.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
      ).first ?? fileManager.temporaryDirectory
      importDirectory = base
        .appendingPathComponent("HuahuoAI", isDirectory: true)
        .appendingPathComponent("IncomingMaterials", isDirectory: true)
    } else {
      importDirectory = (fileManager.urls(
        for: .cachesDirectory,
        in: .userDomainMask
      ).first ?? fileManager.temporaryDirectory)
        .appendingPathComponent(directoryName, isDirectory: true)
    }
    try fileManager.createDirectory(
      at: importDirectory,
      withIntermediateDirectories: true
    )

    let destination = importDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathExtension(fallbackExtension)
    if fileManager.fileExists(atPath: destination.path) {
      try fileManager.removeItem(at: destination)
    }
    let copiedBytes = try copyNativeFileBounded(
      sourceURL: url,
      destinationURL: destination,
      maximumBytes: maximumBytes,
      fileManager: fileManager
    )
    return [
      "displayName": safeDisplayName,
      "mimeType": mimeType,
      "sizeBytes": copiedBytes,
      "sourcePath": destination.path,
      "sourceIdentifier": url.absoluteString,
    ]
  }

  private static func sha256Hex(_ url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while true {
      let data = handle.readData(ofLength: 64 * 1024)
      if data.isEmpty { break }
      hasher.update(data: data)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  private static let incomingOpaqueIDPattern = try! NSRegularExpression(
    pattern: "^[A-Za-z0-9-]{1,96}$"
  )
  private static let incomingOpaqueRefPattern = try! NSRegularExpression(
    pattern: "^incoming-material://[A-Za-z0-9-]{1,96}$"
  )
  private static let sha256Pattern = try! NSRegularExpression(
    pattern: "^[a-f0-9]{64}$"
  )

  private static func mimeType(for fileExtension: String) -> String {
    switch fileExtension.lowercased() {
    case "mp3":
      return "audio/mpeg"
    case "m4a", "mp4":
      return "audio/mp4"
    case "wav":
      return "audio/wav"
    case "opus":
      return "audio/opus"
    default:
      return "audio/*"
    }
  }

  private static let supportedDocumentExtensions: Set<String> = [
    "txt",
    "md",
    "csv",
    "json",
    "pdf",
    "docx",
    "pptx",
    "xlsx",
  ]

  private static let documentTypeIdentifiers = [
    "public.plain-text",
    "net.daringfireball.markdown",
    "public.comma-separated-values-text",
    "public.json",
    "com.adobe.pdf",
    "org.openxmlformats.wordprocessingml.document",
    "org.openxmlformats.presentationml.presentation",
    "org.openxmlformats.spreadsheetml.sheet",
  ]

  private static let supportedAudioExtensions: Set<String> = [
    "mp3", "m4a", "mp4", "wav", "opus",
  ]

  private static let maximumPickedAudioFiles = 16
  private static let maximumPickedAudioBytes = 500 * 1024 * 1024
  private static let maximumPickedDocumentBytes = 500 * 1024 * 1024
  private static let maximumIncomingMaterialBytes = 500 * 1024 * 1024
  private static let maximumImportedDisplayNameUTF16Length = 240

  private static func safeImportedDisplayName(_ value: String) -> String? {
    let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty,
      name.utf16.count <= maximumImportedDisplayNameUTF16Length,
      name != ".",
      name != "..",
      !name.contains("/"),
      !name.contains("\\"),
      name.rangeOfCharacter(from: .controlCharacters) == nil
    else {
      return nil
    }
    return name
  }

  private static let supportedMaterialExtensions =
    supportedDocumentExtensions.union(supportedAudioExtensions)

  private static func materialMimeType(for fileExtension: String) -> String {
    if supportedAudioExtensions.contains(fileExtension.lowercased()) {
      return mimeType(for: fileExtension)
    }
    return documentMimeType(for: fileExtension)
  }

  private static func documentMimeType(for fileExtension: String) -> String {
    switch fileExtension.lowercased() {
    case "txt":
      return "text/plain"
    case "md":
      return "text/markdown"
    case "csv":
      return "text/csv"
    case "json":
      return "application/json"
    case "pdf":
      return "application/pdf"
    case "docx":
      return "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
    case "pptx":
      return "application/vnd.openxmlformats-officedocument.presentationml.presentation"
    case "xlsx":
      return "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
    default:
      return "application/octet-stream"
    }
  }

  private static func mediaMimeType(for fileExtension: String, kind: MediaKind) -> String {
    switch fileExtension.lowercased() {
    case "jpg", "jpeg": return "image/jpeg"
    case "png": return "image/png"
    case "heic": return "image/heic"
    case "webp": return "image/webp"
    case "mov": return "video/quicktime"
    case "m4v": return "video/x-m4v"
    case "mp4": return "video/mp4"
    default: return kind == .image ? "image/*" : "video/*"
    }
  }

  private static let maxChatImageBytes = 50 * 1024 * 1024

  private static func isHEIFExtension(_ value: String) -> Bool {
    value == "heic" || value == "heif"
  }

  private static func jpegDisplayName(_ value: String) -> String {
    let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
    let base = URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent
    return "\(base.isEmpty ? "image" : base).jpg"
  }

  private static func isSafeImageGalleryRequest(
    bytes: Data,
    displayName: String,
    mimeType: String
  ) -> Bool {
    let normalizedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedMime = mimeType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !normalizedName.isEmpty,
      normalizedName.count <= 128,
      !normalizedName.contains("/"),
      !normalizedName.contains("\\"),
      !normalizedName.contains(".."),
      normalizedName.unicodeScalars.allSatisfy({ $0.value >= 32 }),
      bytes.count > 0,
      bytes.count <= 50 * 1024 * 1024,
      ["image/jpeg", "image/png", "image/webp"].contains(normalizedMime)
    else { return false }
    let extensionName = URL(fileURLWithPath: normalizedName).pathExtension.lowercased()
    let validExtension = switch normalizedMime {
    case "image/jpeg": ["jpg", "jpeg"].contains(extensionName)
    case "image/png": extensionName == "png"
    case "image/webp": extensionName == "webp"
    default: false
    }
    guard validExtension else { return false }
    switch normalizedMime {
    case "image/jpeg":
      return bytes.starts(with: Data([0xFF, 0xD8, 0xFF]))
    case "image/png":
      return bytes.starts(with: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))
    case "image/webp":
      return bytes.count >= 12 &&
        bytes.prefix(4) == Data([0x52, 0x49, 0x46, 0x46]) &&
        bytes.dropFirst(8).prefix(4) == Data([0x57, 0x45, 0x42, 0x50])
    default:
      return false
    }
  }

  private func mediaKind(_ value: String?) -> MediaKind? {
    switch value {
    case "image": return .image
    case "video": return .video
    default: return nil
    }
  }

  private static func topViewController() -> UIViewController? {
    let root = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap { $0.windows }
      .first { $0.isKeyWindow }?
      .rootViewController
    return topViewController(from: root)
  }

  private static func topViewController(from root: UIViewController?) -> UIViewController? {
    if let navigationController = root as? UINavigationController {
      return topViewController(from: navigationController.visibleViewController)
    }
    if let tabController = root as? UITabBarController {
      return topViewController(from: tabController.selectedViewController)
    }
    if let presented = root?.presentedViewController {
      return topViewController(from: presented)
    }
    return root
  }

  private enum NativeFilePickerError: Error {
    case missingPickerKind
    case unsupportedDocument
    case unsupportedAudio
    case unsupportedMedia
    case unsafeDisplayName
    case unreadableFile
  }
}

private extension NSRegularExpression {
  func wholeMatch(in value: String) -> Bool {
    let range = NSRange(value.startIndex..<value.endIndex, in: value)
    guard let match = firstMatch(in: value, range: range) else { return false }
    return match.range == range
  }
}

@available(iOS 14.0, *)
extension NativeFilePickerBridge: PHPickerViewControllerDelegate {}

private final class KnowledgeExportBridge: NSObject {
  private let methodChannel: FlutterMethodChannel
  private var pendingResult: FlutterResult?
  private var presentedActivityController: UIActivityViewController?

  init(messenger: FlutterBinaryMessenger) {
    methodChannel = FlutterMethodChannel(
      name: "huahuoai/knowledge_export",
      binaryMessenger: messenger
    )
    super.init()
    methodChannel.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(nativePreparedKnowledgeExportFlutterError(.unavailable))
        return
      }
      switch call.method {
      case "shareKnowledgeText":
        self.shareKnowledgeText(call.arguments as? [String: Any], result: result)
      case "openPreparedKnowledgeExport", "sharePreparedKnowledgeExport":
        self.openPreparedKnowledgeExport(
          call.arguments as? [String: Any],
          result: result
        )
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func shareKnowledgeText(
    _ args: [String: Any]?,
    result: @escaping FlutterResult
  ) {
    guard let text = args?["text"] as? String,
      isSafeNativeKnowledgeShareText(text)
    else {
      result(nativePreparedKnowledgeExportFlutterError(.invalidRequest))
      return
    }
    presentActivity(items: [text], cleanupURL: nil, result: result)
  }

  private func openPreparedKnowledgeExport(
    _ args: [String: Any]?,
    result: @escaping FlutterResult
  ) {
    do {
      guard let args,
        let opaqueExportRef = args["opaqueExportRef"] as? String,
        let displayName = args["displayName"] as? String,
        let mimeType = args["mimeType"] as? String,
        isSafeNativeKnowledgeDisplayName(displayName),
        let fileExtension = displayName.split(separator: ".").last?.lowercased(),
        (fileExtension == "md" && mimeType == "text/markdown") ||
          (fileExtension == "pdf" && mimeType == "application/pdf") ||
          (fileExtension == "zip" && mimeType == "application/zip")
      else {
        throw NativePreparedKnowledgeExportError.invalidRequest
      }
      guard let applicationSupportRoot = FileManager.default.urls(
        for: .cachesDirectory,
        in: .userDomainMask
      ).first else {
        throw NativePreparedKnowledgeExportError.unavailable
      }
      let fileURL = try resolveNativePreparedKnowledgeExportReference(
        opaqueExportRef,
        applicationSupportRoot: applicationSupportRoot
      )
      guard fileURL.pathExtension.lowercased() == fileExtension else {
        throw NativePreparedKnowledgeExportError.invalidRequest
      }
      let presentationURL = try prepareNativeKnowledgePresentationCopy(
        sourceURL: fileURL,
        displayName: displayName
      )
      presentActivity(
        items: [presentationURL],
        cleanupURL: presentationURL,
        result: result
      )
    } catch let error as NativePreparedKnowledgeExportError {
      result(nativePreparedKnowledgeExportFlutterError(error))
    } catch {
      result(nativePreparedKnowledgeExportFlutterError(.unreadable))
    }
  }

  private func presentActivity(
    items: [Any],
    cleanupURL: URL?,
    result: @escaping FlutterResult
  ) {
    guard pendingResult == nil, presentedActivityController == nil else {
      if let cleanupURL {
        removeNativeKnowledgePresentationCopy(cleanupURL)
      }
      result(nativePreparedKnowledgeExportFlutterError(.busy))
      return
    }
    guard let presenter = Self.topViewController(),
      presenter.viewIfLoaded?.window != nil
    else {
      if let cleanupURL {
        removeNativeKnowledgePresentationCopy(cleanupURL)
      }
      result(nativePreparedKnowledgeExportFlutterError(.unavailable))
      return
    }
    let activity = UIActivityViewController(
      activityItems: items,
      applicationActivities: nil
    )
    if let popover = activity.popoverPresentationController {
      popover.sourceView = presenter.view
      popover.sourceRect = CGRect(
        x: presenter.view.bounds.midX,
        y: presenter.view.bounds.maxY,
        width: 1,
        height: 1
      )
      popover.permittedArrowDirections = []
    }
    pendingResult = result
    presentedActivityController = activity
    activity.completionWithItemsHandler = { [weak self, weak activity] _, completed, _, _ in
      guard let self, self.presentedActivityController === activity else { return }
      if let cleanupURL {
        removeNativeKnowledgePresentationCopy(cleanupURL)
      }
      let pending = self.pendingResult
      self.pendingResult = nil
      self.presentedActivityController = nil
      pending?(completed)
    }
    presenter.present(activity, animated: true)
  }

  private static func topViewController() -> UIViewController? {
    let root = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap { $0.windows }
      .first { $0.isKeyWindow }?
      .rootViewController
    return topViewController(from: root)
  }

  private static func topViewController(from root: UIViewController?) -> UIViewController? {
    if let navigationController = root as? UINavigationController {
      return topViewController(from: navigationController.visibleViewController)
    }
    if let tabController = root as? UITabBarController {
      return topViewController(from: tabController.selectedViewController)
    }
    if let presented = root?.presentedViewController {
      return topViewController(from: presented)
    }
    return root
  }
}

func prepareNativeKnowledgePresentationCopy(
  sourceURL: URL,
  displayName: String,
  fileManager: FileManager = .default
) throws -> URL {
  guard isSafeNativeKnowledgeDisplayName(displayName),
    sourceURL.pathExtension.lowercased() ==
      (displayName as NSString).pathExtension.lowercased()
  else {
    throw NativePreparedKnowledgeExportError.invalidRequest
  }
  let exportDirectory = sourceURL.deletingLastPathComponent().standardizedFileURL
  let exportId = exportDirectory.lastPathComponent
  guard exportId.hasPrefix("export-"),
    exportId.count <= 87,
    exportId.unicodeScalars.allSatisfy({
      CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_"
    })
  else {
    throw NativePreparedKnowledgeExportError.unsafeReference
  }
  let presentationDirectory = exportDirectory.appendingPathComponent(
    "presentation",
    isDirectory: true
  )
  if fileManager.fileExists(atPath: presentationDirectory.path) {
    let attributes = try fileManager.attributesOfItem(
      atPath: presentationDirectory.path
    )
    guard attributes[.type] as? FileAttributeType == .typeDirectory else {
      throw NativePreparedKnowledgeExportError.unsafeReference
    }
  } else {
    try fileManager.createDirectory(
      at: presentationDirectory,
      withIntermediateDirectories: false
    )
  }
  let presentationURL = presentationDirectory
    .appendingPathComponent(displayName, isDirectory: false)
    .standardizedFileURL
  guard presentationURL.path.hasPrefix(presentationDirectory.path + "/"),
    !fileManager.fileExists(atPath: presentationURL.path)
  else {
    throw NativePreparedKnowledgeExportError.unsafeReference
  }
  do {
    try fileManager.copyItem(at: sourceURL, to: presentationURL)
    let sourceAttributes = try fileManager.attributesOfItem(atPath: sourceURL.path)
    let copyAttributes = try fileManager.attributesOfItem(atPath: presentationURL.path)
    guard copyAttributes[.type] as? FileAttributeType == .typeRegular,
      let sourceSize = (sourceAttributes[.size] as? NSNumber)?.int64Value,
      let copySize = (copyAttributes[.size] as? NSNumber)?.int64Value,
      sourceSize > 0,
      sourceSize == copySize
    else {
      throw NativePreparedKnowledgeExportError.unreadable
    }
    return presentationURL
  } catch {
    try? fileManager.removeItem(at: presentationURL)
    if (try? fileManager.contentsOfDirectory(atPath: presentationDirectory.path).isEmpty) == true {
      try? fileManager.removeItem(at: presentationDirectory)
    }
    if let typed = error as? NativePreparedKnowledgeExportError {
      throw typed
    }
    throw NativePreparedKnowledgeExportError.unreadable
  }
}

func removeNativeKnowledgePresentationCopy(
  _ presentationURL: URL,
  fileManager: FileManager = .default
) {
  let standardized = presentationURL.standardizedFileURL
  let presentationDirectory = standardized.deletingLastPathComponent()
  let exportDirectory = presentationDirectory.deletingLastPathComponent()
  guard presentationDirectory.lastPathComponent == "presentation",
    exportDirectory.lastPathComponent.hasPrefix("export-"),
    standardized.path.hasPrefix(presentationDirectory.path + "/")
  else { return }
  try? fileManager.removeItem(at: standardized)
  if (try? fileManager.contentsOfDirectory(atPath: presentationDirectory.path).isEmpty) == true {
    try? fileManager.removeItem(at: presentationDirectory)
  }
}

enum NativePreparedKnowledgeExportError: Error, Equatable {
  case invalidRequest
  case unsafeReference
  case unsupportedType
  case missing
  case empty
  case symbolicLink
  case unreadable
  case busy
  case unavailable
}

func resolveNativePreparedKnowledgeExportReference(
  _ reference: String,
  applicationSupportRoot: URL,
  fileManager: FileManager = .default
) throws -> URL {
  let trimmed = reference.trimmingCharacters(in: .whitespacesAndNewlines)
  guard trimmed == reference, !trimmed.isEmpty,
    let components = URLComponents(string: trimmed),
    components.scheme?.lowercased() == "app-private-export",
    components.host?.lowercased() == "knowledge",
    components.user == nil,
    components.password == nil,
    components.port == nil,
    components.query == nil,
    components.fragment == nil,
    !components.percentEncodedPath.contains("%")
  else {
    throw NativePreparedKnowledgeExportError.unsafeReference
  }
  let pathParts = components.path.split(
    separator: "/",
    omittingEmptySubsequences: false
  ).map(String.init)
  guard pathParts.count == 4, pathParts[0].isEmpty, pathParts[1] == "cache" else {
    throw NativePreparedKnowledgeExportError.unsafeReference
  }
  let exportId = pathParts[2]
  let fileName = pathParts[3]
  guard exportId.hasPrefix("export-"), exportId.count > "export-".count,
    exportId.count <= 87,
    exportId.unicodeScalars.allSatisfy({
      CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_"
    }),
    !fileName.isEmpty,
    fileName.count <= 100,
    !fileName.hasPrefix("."),
    !fileName.hasSuffix(".part"),
    fileName.unicodeScalars.allSatisfy({
      CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "_" || $0 == "-"
    })
  else {
    throw NativePreparedKnowledgeExportError.unsafeReference
  }
  guard ["md", "pdf", "zip"].contains((fileName as NSString).pathExtension.lowercased()) else {
    throw NativePreparedKnowledgeExportError.unsupportedType
  }

  let relativeComponents = [
    "HuahuoAI",
    "TemporaryTransfers",
    "knowledge",
    "cache",
    exportId,
    fileName,
  ]
  var candidate = applicationSupportRoot.standardizedFileURL
  let rootPath = candidate.path
  for component in relativeComponents {
    candidate.appendPathComponent(component, isDirectory: component != fileName)
    let standardized = candidate.standardizedFileURL
    guard standardized.path.hasPrefix(rootPath + "/") else {
      throw NativePreparedKnowledgeExportError.unsafeReference
    }
    let attributes: [FileAttributeKey: Any]
    do {
      attributes = try fileManager.attributesOfItem(atPath: standardized.path)
    } catch let error as NSError
      where error.domain == NSCocoaErrorDomain &&
        (error.code == CocoaError.Code.fileNoSuchFile.rawValue ||
          error.code == CocoaError.Code.fileReadNoSuchFile.rawValue)
    {
      throw NativePreparedKnowledgeExportError.missing
    } catch {
      throw NativePreparedKnowledgeExportError.unreadable
    }
    if attributes[.type] as? FileAttributeType == .typeSymbolicLink {
      throw NativePreparedKnowledgeExportError.symbolicLink
    }
    candidate = standardized
  }
  let attributes: [FileAttributeKey: Any]
  do {
    attributes = try fileManager.attributesOfItem(atPath: candidate.path)
  } catch {
    throw NativePreparedKnowledgeExportError.unreadable
  }
  guard attributes[.type] as? FileAttributeType == .typeRegular else {
    throw NativePreparedKnowledgeExportError.unreadable
  }
  guard let size = (attributes[.size] as? NSNumber)?.int64Value, size > 0 else {
    throw NativePreparedKnowledgeExportError.empty
  }
  return candidate
}

func isSafeNativeKnowledgeShareText(_ text: String) -> Bool {
  let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
  guard trimmed == text, !text.isEmpty, text.count <= 12_000 else { return false }
  let lower = text.lowercased()
  let forbidden = [
    "file://",
    "app-private://",
    "app-private-export://",
    "/users/",
    "/private/var/",
    "/var/mobile/",
    "/data/user/",
    "/data/data/",
  ]
  if forbidden.contains(where: lower.contains) { return false }
  return text.range(
    of: #"[A-Za-z]:\\"#,
    options: .regularExpression
  ) == nil
}

func isSafeNativeKnowledgeDisplayName(_ value: String) -> Bool {
  let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
  guard trimmed == value, !value.isEmpty, value.count <= 128,
    !value.hasPrefix("."), !value.hasSuffix(".part"),
    !value.contains("/"), !value.contains("\\")
  else { return false }
  return !value.unicodeScalars.contains {
    CharacterSet.controlCharacters.contains($0)
  }
}

private func nativePreparedKnowledgeExportFlutterError(
  _ error: NativePreparedKnowledgeExportError
) -> FlutterError {
  let code: String
  let message: String
  switch error {
  case .invalidRequest:
    code = "NATIVE_KNOWLEDGE_EXPORT_INVALID_REQUEST"
    message = "Prepared knowledge export request is invalid."
  case .unsafeReference:
    code = "NATIVE_KNOWLEDGE_EXPORT_UNSAFE_REFERENCE"
    message = "Prepared knowledge export reference is unsafe."
  case .unsupportedType:
    code = "NATIVE_KNOWLEDGE_EXPORT_UNSUPPORTED_TYPE"
    message = "Prepared knowledge export type is unsupported."
  case .missing:
    code = "NATIVE_KNOWLEDGE_EXPORT_FILE_MISSING"
    message = "Prepared knowledge export file is missing."
  case .empty:
    code = "NATIVE_KNOWLEDGE_EXPORT_FILE_EMPTY"
    message = "Prepared knowledge export file is empty."
  case .symbolicLink:
    code = "NATIVE_KNOWLEDGE_EXPORT_SYMBOLIC_LINK_REJECTED"
    message = "Prepared knowledge export symbolic link is not allowed."
  case .unreadable:
    code = "NATIVE_KNOWLEDGE_EXPORT_FILE_UNREADABLE"
    message = "Prepared knowledge export file is unreadable."
  case .busy:
    code = "NATIVE_KNOWLEDGE_EXPORT_BUSY"
    message = "Another knowledge export interaction is already active."
  case .unavailable:
    code = "NATIVE_KNOWLEDGE_EXPORT_UNAVAILABLE"
    message = "Native knowledge export is unavailable."
  }
  return FlutterError(code: code, message: message, details: nil)
}

enum NativePreparedAudioExportError: Error, Equatable {
  case invalidRequest
  case unsafeReference
  case unsupportedType
  case missing
  case empty
  case symbolicLink
  case unreadable
  case busy
  case unavailable
}

func resolveNativePreparedAudioExportReference(
  _ reference: String,
  applicationSupportRoot: URL,
  fileManager: FileManager = .default
) throws -> URL {
  let trimmed = reference.trimmingCharacters(in: .whitespacesAndNewlines)
  guard trimmed == reference, !trimmed.isEmpty,
    let components = URLComponents(string: trimmed),
    components.scheme?.lowercased() == "app-private-export",
    components.host?.lowercased() == "recordings",
    components.user == nil,
    components.password == nil,
    components.port == nil,
    components.query == nil,
    components.fragment == nil,
    !components.percentEncodedPath.contains("%")
  else {
    throw NativePreparedAudioExportError.unsafeReference
  }

  let pathParts = components.path.split(
    separator: "/",
    omittingEmptySubsequences: false
  ).map(String.init)
  let accountScope: String?
  let exportId: String
  let fileName: String
  if pathParts.count == 4, pathParts[0].isEmpty, pathParts[1] == "cache" {
    accountScope = nil
    exportId = pathParts[2]
    fileName = pathParts[3]
  } else if pathParts.count == 6, pathParts[0].isEmpty,
    pathParts[1] == "users", pathParts[3] == "cache",
    isSafePreparedAudioExportAccountScope(pathParts[2])
  {
    accountScope = pathParts[2]
    exportId = pathParts[4]
    fileName = pathParts[5]
  } else {
    throw NativePreparedAudioExportError.unsafeReference
  }
  guard exportId.hasPrefix("export-"), exportId.count > "export-".count,
    exportId.count <= 96,
    exportId.unicodeScalars.allSatisfy({
      CharacterSet.alphanumerics.contains($0) || $0 == "-"
    }),
    !fileName.isEmpty,
    fileName.count <= 128,
    !fileName.hasPrefix("."),
    !fileName.hasSuffix(".part"),
    fileName.unicodeScalars.allSatisfy({
      CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "_" || $0 == "-"
    })
  else {
    throw NativePreparedAudioExportError.unsafeReference
  }
  let supportedExtensions: Set<String> = ["mp3", "m4a", "mp4", "wav", "opus"]
  guard supportedExtensions.contains((fileName as NSString).pathExtension.lowercased()) else {
    throw NativePreparedAudioExportError.unsupportedType
  }

  let relativeComponents = accountScope.map {
    [
      "HuahuoAI", "Users", $0, "TemporaryTransfers", "export", "cache",
      exportId, fileName,
    ]
  } ?? [
    "HuahuoAI", "TemporaryTransfers", "export", "cache", exportId, fileName,
  ]
  var candidate = applicationSupportRoot.standardizedFileURL
  let rootPath = candidate.path
  for component in relativeComponents {
    candidate.appendPathComponent(component, isDirectory: component != fileName)
    let standardized = candidate.standardizedFileURL
    guard standardized.path.hasPrefix(rootPath + "/") else {
      throw NativePreparedAudioExportError.unsafeReference
    }
    let attributes: [FileAttributeKey: Any]
    do {
      attributes = try fileManager.attributesOfItem(atPath: standardized.path)
    } catch let error as NSError
      where error.domain == NSCocoaErrorDomain &&
        (error.code == CocoaError.Code.fileNoSuchFile.rawValue ||
          error.code == CocoaError.Code.fileReadNoSuchFile.rawValue)
    {
      throw NativePreparedAudioExportError.missing
    } catch {
      throw NativePreparedAudioExportError.unreadable
    }
    if attributes[.type] as? FileAttributeType == .typeSymbolicLink {
      throw NativePreparedAudioExportError.symbolicLink
    }
    candidate = standardized
  }

  let attributes: [FileAttributeKey: Any]
  do {
    attributes = try fileManager.attributesOfItem(atPath: candidate.path)
  } catch {
    throw NativePreparedAudioExportError.unreadable
  }
  guard attributes[.type] as? FileAttributeType == .typeRegular else {
    throw NativePreparedAudioExportError.unreadable
  }
  guard let size = (attributes[.size] as? NSNumber)?.int64Value, size > 0 else {
    throw NativePreparedAudioExportError.empty
  }
  return candidate
}

private func isSafePreparedAudioExportAccountScope(_ value: String) -> Bool {
  guard value.count == 34, value.hasPrefix("u-") else { return false }
  return value.dropFirst(2).allSatisfy { character in
    guard character.unicodeScalars.count == 1,
      let scalar = character.unicodeScalars.first
    else { return false }
    return (48...57).contains(scalar.value) || (97...102).contains(scalar.value)
  }
}

private func nativePreparedAudioExportFlutterError(
  _ error: NativePreparedAudioExportError
) -> FlutterError {
  let code: String
  let message: String
  switch error {
  case .invalidRequest:
    code = "NATIVE_AUDIO_EXPORT_INVALID_REQUEST"
    message = "Prepared audio export request is invalid."
  case .unsafeReference:
    code = "NATIVE_AUDIO_EXPORT_UNSAFE_REFERENCE"
    message = "Prepared audio export reference is unsafe."
  case .unsupportedType:
    code = "NATIVE_AUDIO_EXPORT_UNSUPPORTED_TYPE"
    message = "Prepared audio export type is unsupported."
  case .missing:
    code = "NATIVE_AUDIO_EXPORT_FILE_MISSING"
    message = "Prepared audio export file is missing."
  case .empty:
    code = "NATIVE_AUDIO_EXPORT_FILE_EMPTY"
    message = "Prepared audio export file is empty."
  case .symbolicLink:
    code = "NATIVE_AUDIO_EXPORT_SYMBOLIC_LINK_REJECTED"
    message = "Prepared audio export symbolic link is not allowed."
  case .unreadable:
    code = "NATIVE_AUDIO_EXPORT_FILE_UNREADABLE"
    message = "Prepared audio export file is unreadable."
  case .busy:
    code = "NATIVE_AUDIO_EXPORT_BUSY"
    message = "Another native file interaction is already active."
  case .unavailable:
    code = "NATIVE_AUDIO_EXPORT_UNAVAILABLE"
    message = "Native audio export is unavailable."
  }
  return FlutterError(code: code, message: message, details: nil)
}

private final class GlassAccessibilityBridge: NSObject {
  private let methodChannel: FlutterMethodChannel

  init(messenger: FlutterBinaryMessenger) {
    methodChannel = FlutterMethodChannel(
      name: "huahuoai/glass_accessibility",
      binaryMessenger: messenger
    )
    super.init()

    methodChannel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call: call, result: result)
    }
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(reduceTransparencyStatusDidChange(_:)),
      name: UIAccessibility.reduceTransparencyStatusDidChangeNotification,
      object: nil
    )
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  private func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "getReduceTransparencyEnabled":
      result(UIAccessibility.isReduceTransparencyEnabled)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  @objc private func reduceTransparencyStatusDidChange(_ notification: Notification) {
    DispatchQueue.main.async { [methodChannel] in
      methodChannel.invokeMethod(
        "reduceTransparencyChanged",
        arguments: UIAccessibility.isReduceTransparencyEnabled
      )
    }
  }
}
