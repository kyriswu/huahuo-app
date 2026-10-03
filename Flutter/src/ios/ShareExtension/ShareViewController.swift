import Social
import UniformTypeIdentifiers
import UIKit

final class ShareViewController: SLComposeServiceViewController {
  private var completed = false

  override func isContentValid() -> Bool {
    if !(contentText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) {
      return true
    }
    return !attachmentProviders().isEmpty
  }

  override func didSelectPost() {
    let providers = attachmentProviders()
    let fallbackText = providers.isEmpty
      ? contentText?.trimmingCharacters(in: .whitespacesAndNewlines)
      : nil
    let materialCount = providers.count + (fallbackText?.isEmpty == false ? 1 : 0)
    let origin = materialCount > 1 ? "sendMultiple" : "send"
    let completionGroup = DispatchGroup()
    let lock = NSLock()
    var stagedAnyMaterial = false

    for provider in providers.prefix(IncomingMaterialShareStore.maximumPendingItems) {
      completionGroup.enter()
      stage(
        provider: provider,
        origin: origin
      ) { staged in
        lock.lock()
        stagedAnyMaterial = stagedAnyMaterial || staged
        lock.unlock()
        completionGroup.leave()
      }
    }

    if let fallbackText, !fallbackText.isEmpty {
      completionGroup.enter()
      DispatchQueue.global(qos: .userInitiated).async {
        let staged = (try? IncomingMaterialShareStore.stageText(
          fallbackText,
          origin: origin
        )) != nil
        lock.lock()
        stagedAnyMaterial = stagedAnyMaterial || staged
        lock.unlock()
        completionGroup.leave()
      }
    }

    completionGroup.notify(queue: .main) { [weak self] in
      self?.finish(stagedAnyMaterial: stagedAnyMaterial)
    }
  }

  override func configurationItems() -> [Any]! {
    []
  }

  private func attachmentProviders() -> [NSItemProvider] {
    (extensionContext?.inputItems as? [NSExtensionItem] ?? [])
      .flatMap { $0.attachments ?? [] }
      .filter { provider in
        selectedFileTypeIdentifier(for: provider) != nil ||
          selectedTextTypeIdentifier(for: provider) != nil ||
          provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
      }
  }

  private func stage(
    provider: NSItemProvider,
    origin: String,
    completion: @escaping (Bool) -> Void
  ) {
    if let typeIdentifier = selectedFileTypeIdentifier(for: provider) {
      provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, _ in
        guard let url else {
          completion(false)
          return
        }
        let staged = (try? IncomingMaterialShareStore.stageFile(
          from: url,
          displayName: provider.suggestedName ?? url.lastPathComponent,
          typeIdentifier: typeIdentifier,
          origin: origin
        )) != nil
        completion(staged)
      }
      return
    }
    if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
      provider.loadItem(
        forTypeIdentifier: UTType.fileURL.identifier,
        options: nil
      ) { item, _ in
        guard let url = item as? URL else {
          completion(false)
          return
        }
        let staged = (try? IncomingMaterialShareStore.stageFile(
          from: url,
          displayName: provider.suggestedName ?? url.lastPathComponent,
          typeIdentifier: nil,
          origin: origin
        )) != nil
        completion(staged)
      }
      return
    }
    guard let typeIdentifier = selectedTextTypeIdentifier(for: provider) else {
      completion(false)
      return
    }
    provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, _ in
      guard let data,
        let text = String(data: data, encoding: .utf8)
      else {
        completion(false)
        return
      }
      let staged = (try? IncomingMaterialShareStore.stageText(
        text,
        origin: origin
      )) != nil
      completion(staged)
    }
  }

  private func selectedFileTypeIdentifier(for provider: NSItemProvider) -> String? {
    provider.registeredTypeIdentifiers.first { identifier in
      guard !IncomingMaterialShareStore.isTextTypeIdentifier(identifier),
        let type = UTType(identifier)
      else {
        return false
      }
      return IncomingMaterialShareStore.acceptedFileExtension(
        sourceURL: URL(fileURLWithPath: "material"),
        typeIdentifier: type.identifier
      ) != nil
    }
  }

  private func selectedTextTypeIdentifier(for provider: NSItemProvider) -> String? {
    provider.registeredTypeIdentifiers.first(
      where: IncomingMaterialShareStore.isTextTypeIdentifier
    )
  }

  private func finish(stagedAnyMaterial: Bool) {
    guard !completed else { return }
    completed = true
    guard stagedAnyMaterial,
      let url = URL(string: "huahuoai://incoming-materials")
    else {
      extensionContext?.completeRequest(returningItems: nil)
      return
    }
    extensionContext?.open(url) { [weak self] _ in
      self?.extensionContext?.completeRequest(returningItems: nil)
    }
  }
}
