import Foundation
import UniformTypeIdentifiers

enum IncomingMaterialShareStoreError: Error {
  case appGroupUnavailable
  case empty
  case invalidManifest
  case invalidOrigin
  case tooLarge
  case unreadable
  case unsupportedFormat
}

struct IncomingMaterialShareItem: Codable, Equatable {
  let id: String
  let displayName: String
  let fileName: String
  let origin: String
}

enum IncomingMaterialShareStore {
  static let appGroupIdentifier = "group.com.hangzhouchuda.huahuoai.capture"
  static let maximumFileBytes = 500 * 1024 * 1024
  static let maximumTextBytes = 4 * 1024 * 1024
  static let maximumPendingItems = 16

  static let supportedDocumentExtensions: Set<String> = [
    "txt", "md", "csv", "json", "pdf", "docx", "pptx", "xlsx",
  ]
  static let supportedAudioExtensions: Set<String> = [
    "mp3", "m4a", "mp4", "wav", "opus",
  ]
  static let supportedExtensions = supportedDocumentExtensions.union(
    supportedAudioExtensions
  )

  static func acceptedFileExtension(
    sourceURL: URL,
    typeIdentifier: String?
  ) -> String? {
    let sourceExtension = sourceURL.pathExtension.lowercased()
    if supportedExtensions.contains(sourceExtension) {
      return sourceExtension
    }
    guard let typeIdentifier, let type = UTType(typeIdentifier)
    else {
      return nil
    }
    if let preferred = type.preferredFilenameExtension?.lowercased(),
      supportedExtensions.contains(preferred)
    {
      return preferred
    }
    if type.conforms(to: .plainText) || type.conforms(to: .text) {
      return "txt"
    }
    if type.conforms(to: .commaSeparatedText) { return "csv" }
    if type.conforms(to: .json) { return "json" }
    if type.conforms(to: .pdf) { return "pdf" }
    switch type.identifier {
    case "public.mp3": return "mp3"
    case "public.mpeg-4-audio": return "m4a"
    case "com.microsoft.waveform-audio": return "wav"
    case "org.xiph.opus": return "opus"
    case "net.daringfireball.markdown": return "md"
    case "org.openxmlformats.wordprocessingml.document": return "docx"
    case "org.openxmlformats.presentationml.presentation": return "pptx"
    case "org.openxmlformats.spreadsheetml.sheet": return "xlsx"
    default: return nil
    }
  }

  static func isTextTypeIdentifier(_ identifier: String) -> Bool {
    guard let type = UTType(identifier) else { return false }
    return type.conforms(to: .plainText) || type.conforms(to: .text)
  }

  static func stageFile(
    from sourceURL: URL,
    displayName: String,
    typeIdentifier: String?,
    origin: String
  ) throws -> IncomingMaterialShareItem {
    guard let fileExtension = acceptedFileExtension(
      sourceURL: sourceURL,
      typeIdentifier: typeIdentifier
    ) else {
      throw IncomingMaterialShareStoreError.unsupportedFormat
    }
    return try stage(
      displayName: displayName,
      fileExtension: fileExtension,
      origin: origin
    ) { temporaryURL in
      try copyBoundedFile(from: sourceURL, to: temporaryURL)
    }
  }

  static func stageText(
    _ text: String,
    displayName: String = "shared-text.txt",
    origin: String
  ) throws -> IncomingMaterialShareItem {
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      let data = text.data(using: .utf8),
      !data.isEmpty
    else {
      throw IncomingMaterialShareStoreError.empty
    }
    guard data.count <= maximumTextBytes else {
      throw IncomingMaterialShareStoreError.tooLarge
    }
    return try stage(
      displayName: displayName,
      fileExtension: "txt",
      origin: origin
    ) { temporaryURL in
      try data.write(to: temporaryURL, options: .atomic)
    }
  }

  static func pendingItems() -> [IncomingMaterialShareItem] {
    guard let directory = try? directoryURL(),
      let manifests = try? FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: [.contentModificationDateKey],
        options: [.skipsHiddenFiles]
      )
    else {
      return []
    }
    let sorted = manifests
      .filter { $0.pathExtension.lowercased() == "json" }
      .sorted { modificationDate(of: $0) < modificationDate(of: $1) }
    var entries: [(manifest: URL, item: IncomingMaterialShareItem)] = []
    for manifest in sorted {
      guard let data = try? Data(contentsOf: manifest),
        let item = try? JSONDecoder().decode(
          IncomingMaterialShareItem.self,
          from: data
        ),
        isValid(item, in: directory)
      else {
        try? FileManager.default.removeItem(at: manifest)
        continue
      }
      entries.append((manifest, item))
    }
    if entries.count > maximumPendingItems {
      for entry in entries.dropLast(maximumPendingItems) {
        remove(entry.item)
      }
      entries.removeFirst(entries.count - maximumPendingItems)
    }
    return entries.map(\.item)
  }

  static func materialURL(for item: IncomingMaterialShareItem) -> URL? {
    guard let directory = try? directoryURL(), isValid(item, in: directory)
    else {
      return nil
    }
    return directory.appendingPathComponent(item.fileName, isDirectory: false)
  }

  static func remove(_ item: IncomingMaterialShareItem) {
    guard let directory = try? directoryURL(), isSafeIdentifier(item.id),
      let fileExtension = safeFileExtension(for: item)
    else {
      return
    }
    let manager = FileManager.default
    try? manager.removeItem(
      at: directory.appendingPathComponent(item.id).appendingPathExtension("json")
    )
    try? manager.removeItem(
      at: directory.appendingPathComponent("\(item.id).\(fileExtension)")
    )
  }

  private static func stage(
    displayName: String,
    fileExtension: String,
    origin: String,
    writer: (URL) throws -> Void
  ) throws -> IncomingMaterialShareItem {
    guard supportedExtensions.contains(fileExtension),
      let safeName = normalizedDisplayName(
        displayName,
        requiredExtension: fileExtension
      ),
      isValidOrigin(origin)
    else {
      throw IncomingMaterialShareStoreError.unsupportedFormat
    }
    let directory = try directoryURL()
    let id = UUID().uuidString
    let fileName = "\(id).\(fileExtension)"
    let temporary = directory.appendingPathComponent(".\(fileName).part")
    let destination = directory.appendingPathComponent(fileName)
    let item = IncomingMaterialShareItem(
      id: id,
      displayName: safeName,
      fileName: fileName,
      origin: origin
    )
    let manager = FileManager.default
    do {
      try? manager.removeItem(at: temporary)
      try writer(temporary)
      let values = try temporary.resourceValues(
        forKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey]
      )
      guard values.isRegularFile == true,
        values.isSymbolicLink != true,
        let size = values.fileSize,
        size > 0
      else {
        throw IncomingMaterialShareStoreError.empty
      }
      guard size <= maximumFileBytes else {
        throw IncomingMaterialShareStoreError.tooLarge
      }
      try? manager.removeItem(at: destination)
      try manager.moveItem(at: temporary, to: destination)
      try persist(item, in: directory)
      _ = pendingItems()
      return item
    } catch {
      try? manager.removeItem(at: temporary)
      try? manager.removeItem(at: destination)
      throw error
    }
  }

  private static func copyBoundedFile(from sourceURL: URL, to destination: URL) throws {
    guard sourceURL.isFileURL else {
      throw IncomingMaterialShareStoreError.unreadable
    }
    let didAccess = sourceURL.startAccessingSecurityScopedResource()
    defer {
      if didAccess { sourceURL.stopAccessingSecurityScopedResource() }
    }
    let input = try FileHandle(forReadingFrom: sourceURL)
    defer { try? input.close() }
    guard FileManager.default.createFile(atPath: destination.path, contents: nil),
      let output = try? FileHandle(forWritingTo: destination)
    else {
      throw IncomingMaterialShareStoreError.unreadable
    }
    defer { try? output.close() }
    var copiedBytes = 0
    while true {
      let data = input.readData(ofLength: 64 * 1024)
      if data.isEmpty { break }
      let nextCount = copiedBytes + data.count
      guard nextCount <= maximumFileBytes else {
        throw IncomingMaterialShareStoreError.tooLarge
      }
      output.write(data)
      copiedBytes = nextCount
    }
    guard copiedBytes > 0 else { throw IncomingMaterialShareStoreError.empty }
  }

  private static func persist(
    _ item: IncomingMaterialShareItem,
    in directory: URL
  ) throws {
    let data = try JSONEncoder().encode(item)
    let manifest = directory.appendingPathComponent(item.id).appendingPathExtension("json")
    try data.write(to: manifest, options: .atomic)
  }

  private static func directoryURL() throws -> URL {
    guard let groupURL = FileManager.default.containerURL(
      forSecurityApplicationGroupIdentifier: appGroupIdentifier
    ) else {
      throw IncomingMaterialShareStoreError.appGroupUnavailable
    }
    let directory = groupURL
      .appendingPathComponent("IncomingMaterialShare", isDirectory: true)
      .appendingPathComponent("v1", isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    return directory
  }

  private static func isValid(
    _ item: IncomingMaterialShareItem,
    in directory: URL
  ) -> Bool {
    guard isSafeIdentifier(item.id),
      let fileExtension = safeFileExtension(for: item),
      normalizedDisplayName(item.displayName, requiredExtension: fileExtension)
        == item.displayName,
      isValidOrigin(item.origin)
    else {
      return false
    }
    let file = directory
      .appendingPathComponent(item.fileName, isDirectory: false)
      .resolvingSymlinksInPath()
      .standardizedFileURL
    let root = directory.resolvingSymlinksInPath().standardizedFileURL
    guard file.deletingLastPathComponent() == root,
      let values = try? file.resourceValues(
        forKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey]
      ),
      values.isRegularFile == true,
      values.isSymbolicLink != true,
      let fileSize = values.fileSize,
      fileSize > 0,
      fileSize <= maximumFileBytes
    else {
      return false
    }
    return true
  }

  private static func safeFileExtension(
    for item: IncomingMaterialShareItem
  ) -> String? {
    guard isSafeIdentifier(item.id) else { return nil }
    let extensionName = (item.fileName as NSString).pathExtension.lowercased()
    guard supportedExtensions.contains(extensionName),
      item.fileName == "\(item.id).\(extensionName)"
    else {
      return nil
    }
    return extensionName
  }

  private static func normalizedDisplayName(
    _ value: String,
    requiredExtension: String
  ) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty,
      !trimmed.contains("/"),
      !trimmed.contains("\\"),
      !trimmed.unicodeScalars.contains(where: { scalar in
        scalar.value < 0x20 || scalar.value == 0x7f
      })
    else {
      return nil
    }
    let base = (trimmed as NSString).deletingPathExtension
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !base.isEmpty else { return nil }
    let maximumBaseLength = max(1, 240 - requiredExtension.count - 1)
    return "\(String(base.prefix(maximumBaseLength))).\(requiredExtension)"
  }

  private static func isSafeIdentifier(_ value: String) -> Bool {
    UUID(uuidString: value) != nil
  }

  private static func isValidOrigin(_ value: String) -> Bool {
    value == "send" || value == "sendMultiple"
  }

  private static func modificationDate(of url: URL) -> Date {
    (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
      .contentModificationDate ?? .distantPast
  }
}
