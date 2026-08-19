@preconcurrency import AVFoundation
import BetterflowBenchmarkCore
import FluidAudio
import Foundation
@preconcurrency import MoonshineVoice
@preconcurrency import Speech

public enum ModelStorageStatus: Equatable, Sendable {
  case notDownloaded
  case downloaded(bytes: Int64?)
  case unsupported(String)
}

public enum ModelStorage {
  public static func status(for model: BenchmarkModel) async -> ModelStorageStatus {
    switch model {
    case .moonshineSmall, .moonshineMedium:
      let spec = moonshineSpec(for: model)
      let directory = moonshineDirectory(for: spec)
      guard AssetDownloader().isModelPresent(root: directory, spec: spec) else {
        return .notDownloaded
      }
      return .downloaded(bytes: allocatedSize(of: [directory]))

    case .parakeet:
      let primary = AsrModels.defaultCacheDirectory(for: .tdtCtc110m)
      let vocabulary = CtcModels.defaultCacheDirectory(for: .ctc110m)
      guard
        AsrModels.modelsExist(at: primary, version: .tdtCtc110m),
        CtcModels.modelsExist(at: vocabulary)
      else {
        return .notDownloaded
      }
      return .downloaded(bytes: allocatedSize(of: [primary, vocabulary]))

    case .parakeetEou:
      let directory = parakeetEouDirectory
      guard contains(ModelNames.ParakeetEOU.requiredModels, in: directory) else {
        return .notDownloaded
      }
      return .downloaded(bytes: allocatedSize(of: [directory]))

    case .nemotron:
      let directory = nemotronDirectory
      let required: Set<String> = [
        ModelNames.NemotronStreaming.encoderInt8File,
        ModelNames.NemotronStreaming.decoderFile,
        ModelNames.NemotronStreaming.jointFile,
        ModelNames.NemotronStreaming.tokenizer,
      ]
      guard contains(required, in: directory) else { return .notDownloaded }
      return .downloaded(bytes: allocatedSize(of: [directory]))

    case .whisper:
      let directory = whisperDirectory
      let required = [
        "AudioEncoder.mlmodelc/coremldata.bin",
        "MelSpectrogram.mlmodelc/coremldata.bin",
        "TextDecoder.mlmodelc/coremldata.bin",
        "TextDecoderContextPrefill.mlmodelc/coremldata.bin",
      ]
      guard contains(Set(required), in: directory) else { return .notDownloaded }
      return .downloaded(bytes: allocatedSize(of: [directory]))

    case .qwen:
      guard qwenSnapshotIsComplete else { return .notDownloaded }
      return .downloaded(bytes: allocatedSize(of: [qwenDirectory]))

    case .appleSpeech, .appleDictation:
      return await appleStatus(for: model)
    }
  }

  public static func isDownloaded(_ model: BenchmarkModel) async -> Bool {
    switch model {
    case .moonshineSmall, .moonshineMedium:
      let spec = moonshineSpec(for: model)
      return AssetDownloader().isModelPresent(
        root: moonshineDirectory(for: spec),
        spec: spec
      )
    case .parakeet:
      return
        AsrModels.modelsExist(
          at: AsrModels.defaultCacheDirectory(for: .tdtCtc110m),
          version: .tdtCtc110m
        )
        && CtcModels.modelsExist(at: CtcModels.defaultCacheDirectory(for: .ctc110m))
    case .parakeetEou:
      return contains(ModelNames.ParakeetEOU.requiredModels, in: parakeetEouDirectory)
    case .nemotron:
      return contains(
        [
          ModelNames.NemotronStreaming.encoderInt8File,
          ModelNames.NemotronStreaming.decoderFile,
          ModelNames.NemotronStreaming.jointFile,
          ModelNames.NemotronStreaming.tokenizer,
        ],
        in: nemotronDirectory
      )
    case .whisper:
      return contains(
        [
          "AudioEncoder.mlmodelc/coremldata.bin",
          "MelSpectrogram.mlmodelc/coremldata.bin",
          "TextDecoder.mlmodelc/coremldata.bin",
          "TextDecoderContextPrefill.mlmodelc/coremldata.bin",
        ],
        in: whisperDirectory
      )
    case .qwen:
      return qwenSnapshotIsComplete
    case .appleSpeech, .appleDictation:
      if case .downloaded = await appleStatus(for: model) { return true }
      return false
    }
  }

  public static func download(_ model: BenchmarkModel) async throws {
    let adapter = AdapterFactory.make(model)
    do {
      try await adapter.prepare(guideWords: [])
      await adapter.close()
    } catch {
      await adapter.close()
      throw error
    }
  }

  public static func delete(_ model: BenchmarkModel) async throws {
    switch model {
    case .moonshineSmall, .moonshineMedium:
      try remove(moonshineDirectory(for: moonshineSpec(for: model)))
    case .parakeet:
      try remove(AsrModels.defaultCacheDirectory(for: .tdtCtc110m))
      try remove(CtcModels.defaultCacheDirectory(for: .ctc110m))
    case .parakeetEou:
      try remove(parakeetEouDirectory)
    case .nemotron:
      try remove(nemotronDirectory)
    case .whisper:
      try remove(whisperDirectory)
    case .qwen:
      try remove(qwenDirectory)
    case .appleSpeech, .appleDictation:
      try await releaseAppleAssets(for: model)
    }
  }

  private static func moonshineSpec(for model: BenchmarkModel) -> ModelSpec {
    let architecture: ModelArch = model == .moonshineSmall ? .smallStreaming : .mediumStreaming
    return .stt(language: "en", modelArch: architecture)
  }

  private static func moonshineDirectory(for spec: ModelSpec) -> URL {
    MoonshineVoice.ModelCache.defaultRoot()
      .appendingPathComponent(MoonshineVoice.ModelCache.key(for: spec), isDirectory: true)
  }

  private static var fluidModelsDirectory: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("FluidAudio/Models", isDirectory: true)
  }

  private static var parakeetEouDirectory: URL {
    fluidModelsDirectory
      .appendingPathComponent("parakeet-eou-streaming", isDirectory: true)
      .appendingPathComponent(Repo.parakeetEou160.folderName, isDirectory: true)
  }

  private static var nemotronDirectory: URL {
    fluidModelsDirectory.appendingPathComponent(
      Repo.nemotronStreaming2240.folderName,
      isDirectory: true
    )
  }

  private static var whisperDirectory: URL {
    FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("huggingface/models/argmaxinc/whisperkit-coreml", isDirectory: true)
      .appendingPathComponent(
        "openai_whisper-large-v3-v20240930_turbo",
        isDirectory: true
      )
  }

  private static var qwenDirectory: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".cache/huggingface/hub", isDirectory: true)
      .appendingPathComponent(
        "models--mlx-community--Qwen3-ASR-0.6B-8bit",
        isDirectory: true
      )
  }

  private static var qwenSnapshotIsComplete: Bool {
    let snapshots = qwenDirectory.appendingPathComponent("snapshots", isDirectory: true)
    guard
      let candidates = try? FileManager.default.contentsOfDirectory(
        at: snapshots,
        includingPropertiesForKeys: nil,
        options: .skipsHiddenFiles
      )
    else {
      return false
    }
    return candidates.contains { snapshot in
      contains(
        ["config.json", "model.safetensors", "tokenizer_config.json"],
        in: snapshot
      )
    }
  }

  private static func contains(_ relativePaths: Set<String>, in directory: URL) -> Bool {
    relativePaths.allSatisfy {
      FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path)
    }
  }

  private static func allocatedSize(of directories: [URL]) -> Int64? {
    let keys: Set<URLResourceKey> = [
      .isRegularFileKey,
      .fileAllocatedSizeKey,
      .totalFileAllocatedSizeKey,
    ]
    var total: Int64 = 0
    var foundFile = false
    for directory in directories {
      guard
        let files = FileManager.default.enumerator(
          at: directory,
          includingPropertiesForKeys: Array(keys),
          options: [.skipsHiddenFiles]
        )
      else {
        continue
      }
      for case let file as URL in files {
        guard let values = try? file.resourceValues(forKeys: keys), values.isRegularFile == true
        else {
          continue
        }
        foundFile = true
        total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
      }
    }
    return foundFile ? total : nil
  }

  private static func remove(_ url: URL) throws {
    guard FileManager.default.fileExists(atPath: url.path) else { return }
    try FileManager.default.removeItem(at: url)
  }

  private static func appleStatus(for model: BenchmarkModel) async -> ModelStorageStatus {
    guard #available(macOS 26.0, *) else {
      return .unsupported("Requires macOS 26 or newer")
    }
    do {
      let modules = try await appleModules(for: model)
      switch await AssetInventory.status(forModules: modules) {
      case .installed: return .downloaded(bytes: nil)
      case .unsupported: return .unsupported("Unavailable on this Mac")
      case .supported, .downloading: return .notDownloaded
      @unknown default: return .unsupported("Unknown macOS asset status")
      }
    } catch {
      return .unsupported(error.localizedDescription)
    }
  }

  @available(macOS 26.0, *)
  private static func appleModules(for model: BenchmarkModel) async throws -> [any SpeechModule] {
    let locale = try await appleLocale(for: model)
    switch model {
    case .appleSpeech:
      return [SpeechTranscriber(locale: locale, preset: .progressiveTranscription)]
    case .appleDictation:
      return [DictationTranscriber(locale: locale, preset: .progressiveShortDictation)]
    default:
      preconditionFailure("Apple modules requested for \(model.rawValue)")
    }
  }

  @available(macOS 26.0, *)
  private static func appleLocale(for model: BenchmarkModel) async throws -> Locale {
    let requested = Locale(identifier: "en-US")
    let locale: Locale?
    switch model {
    case .appleSpeech:
      locale = await SpeechTranscriber.supportedLocale(equivalentTo: requested)
    case .appleDictation:
      locale = await DictationTranscriber.supportedLocale(equivalentTo: requested)
    default:
      preconditionFailure("Apple locale requested for \(model.rawValue)")
    }
    guard let locale else {
      throw ModelStorageError.unsupported("This Apple model does not support English on this Mac.")
    }
    return locale
  }

  private static func releaseAppleAssets(for model: BenchmarkModel) async throws {
    guard #available(macOS 26.0, *) else {
      throw ModelStorageError.unsupported("This model requires macOS 26 or newer.")
    }
    let locale = try await appleLocale(for: model)
    guard await AssetInventory.release(reservedLocale: locale) else {
      throw ModelStorageError.releaseFailed
    }
  }
}

public enum ModelStorageError: LocalizedError {
  case unsupported(String)
  case releaseFailed

  public var errorDescription: String? {
    switch self {
    case .unsupported(let message): message
    case .releaseFailed: "macOS did not release this speech model."
    }
  }
}
