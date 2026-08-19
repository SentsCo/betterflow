import Foundation
import HuggingFace

#if canImport(FoundationModels)
  import FoundationModels
#endif

enum TranscriptCleanupStorage {
  private static let qwenRepo = Repo.ID(namespace: "mlx-community", name: "Qwen3-0.6B-4bit")

  static var qwenDirectory: URL {
    HubCache.default.repoDirectory(repo: qwenRepo, kind: .model)
  }

  static var isQwenDownloaded: Bool {
    let snapshots = qwenDirectory.appendingPathComponent("snapshots", isDirectory: true)
    guard
      let snapshotURLs = try? FileManager.default.contentsOfDirectory(
        at: snapshots,
        includingPropertiesForKeys: nil,
        options: .skipsHiddenFiles
      )
    else { return false }

    return snapshotURLs.contains { snapshot in
      let config = snapshot.appendingPathComponent("config.json")
      let tokenizer = snapshot.appendingPathComponent("tokenizer.json")
      let model = snapshot.appendingPathComponent("model.safetensors")
      return FileManager.default.fileExists(atPath: config.path)
        && FileManager.default.fileExists(atPath: tokenizer.path)
        && FileManager.default.fileExists(atPath: model.path)
    }
  }

  static var qwenAllocatedSize: Int64? {
    guard isQwenDownloaded else { return nil }
    guard let enumerator = FileManager.default.enumerator(
      at: qwenDirectory,
      includingPropertiesForKeys: [.isRegularFileKey, .totalFileAllocatedSizeKey],
      options: [.skipsHiddenFiles]
    ) else { return nil }

    var total: Int64 = 0
    for case let url as URL in enumerator {
      guard let values = try? url.resourceValues(forKeys: [
        .isRegularFileKey, .totalFileAllocatedSizeKey,
      ]), values.isRegularFile == true
      else { continue }
      total += Int64(values.totalFileAllocatedSize ?? 0)
    }
    return total
  }

  static var appleAvailable: Bool {
    #if canImport(FoundationModels)
      if #available(macOS 26.0, *) {
        return SystemLanguageModel.default.isAvailable
      }
    #endif
    return false
  }
}

@MainActor
final class CleanupModelDownloadManager: ObservableObject {
  @Published private(set) var states = Dictionary(
    uniqueKeysWithValues: CleanupModel.allCases.map { ($0, ModelDownloadState.checking) }
  )

  private let settings: AppSettings
  private let runtime: TranscriptCleanupRuntime

  init(settings: AppSettings, runtime: TranscriptCleanupRuntime) {
    self.settings = settings
    self.runtime = runtime
  }

  func refresh(prepareSelectedModel: Bool = false) {
    guard states[.qwenSmall]?.isBusy != true else { return }
    states[.appleFoundation] = TranscriptCleanupStorage.appleAvailable
      ? .downloaded(bytes: nil)
      : .unavailable("Unavailable on this Mac")
    states[.qwenSmall] = .checking
    Task {
      let status = await Task.detached(priority: .utility) {
        if TranscriptCleanupStorage.isQwenDownloaded {
          return ModelDownloadState.downloaded(
            bytes: TranscriptCleanupStorage.qwenAllocatedSize
          )
        }
        return ModelDownloadState.notDownloaded
      }.value
      guard states[.qwenSmall]?.isBusy != true else { return }
      states[.qwenSmall] = status
      if prepareSelectedModel,
        settings.cleanupEnabledByDefault,
        settings.cleanupModel == .qwenSmall,
        case .downloaded = status
      {
        try? await runtime.prepareQwen()
      }
    }
  }

  func select(_ model: CleanupModel) {
    settings.cleanupModel = model
    if model == .qwenSmall, case .downloaded = states[model] {
      Task { try? await runtime.prepareQwen() }
    } else {
      Task { await runtime.unloadQwen() }
    }
  }

  func download(_ model: CleanupModel) {
    guard model == .qwenSmall, states[model]?.isBusy != true else { return }
    states[model] = .downloading
    Task {
      do {
        try await runtime.prepareQwen()
        states[model] = .downloaded(
          bytes: await Task.detached(priority: .utility) {
            TranscriptCleanupStorage.qwenAllocatedSize
          }.value
        )
      } catch {
        states[model] = .failed(error.localizedDescription)
      }
    }
  }

  func delete(_ model: CleanupModel) {
    guard model == .qwenSmall, states[model]?.isBusy != true else { return }
    states[model] = .deleting
    Task {
      await runtime.unloadQwen()
      do {
        try await Task.detached(priority: .utility) {
          let directory = TranscriptCleanupStorage.qwenDirectory
          if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
          }
        }.value
        states[model] = .notDownloaded
      } catch {
        states[model] = .failed(error.localizedDescription)
      }
    }
  }
}
