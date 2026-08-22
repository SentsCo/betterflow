import BetterflowBenchmarkCore
import BetterflowEngine
import Foundation

enum ModelDownloadState: Equatable {
  case checking
  case notDownloaded
  case downloaded(bytes: Int64?)
  case downloading
  case deleting
  case unavailable(String)
  case failed(String)

  var isBusy: Bool {
    self == .downloading || self == .deleting
  }
}

@MainActor
final class ModelDownloadManager: ObservableObject {
  @Published private(set) var states = Dictionary(
    uniqueKeysWithValues: BenchmarkModel.allCases.map { ($0, ModelDownloadState.checking) }
  )

  private let settings: AppSettings
  private let coordinator: RecognitionCoordinator

  init(settings: AppSettings, coordinator: RecognitionCoordinator) {
    self.settings = settings
    self.coordinator = coordinator
  }

  func refresh(prepareSelectedModel: Bool = false) {
    Task {
      var preparedSelectedModel = false
      await withTaskGroup(of: (BenchmarkModel, ModelStorageStatus).self) { group in
        for model in BenchmarkModel.allCases where states[model]?.isBusy != true {
          group.addTask { (model, await ModelStorage.status(for: model)) }
        }
        for await (model, status) in group {
          guard states[model]?.isBusy != true else { continue }
          states[model] = Self.state(for: status)
          if prepareSelectedModel, model == settings.selectedModel,
            case .downloaded = status
          {
            coordinator.prepareSelectedModel()
            preparedSelectedModel = true
          }
        }
      }
      if prepareSelectedModel, !preparedSelectedModel,
        case .downloaded = states[settings.selectedModel]
      {
        coordinator.prepareSelectedModel()
      }
    }
  }

  func select(_ model: BenchmarkModel) {
    settings.selectedModel = model
    switch states[model] {
    case .downloaded:
      coordinator.prepareSelectedModel()
    default:
      coordinator.unloadModels()
    }
  }

  func setGuideWordStrength(_ strength: GuideWordStrength) {
    settings.setGuideWordStrength(strength, for: settings.selectedModel)
    coordinator.prepareSelectedModel()
  }

  func download(_ model: BenchmarkModel) {
    guard states[model]?.isBusy != true else { return }
    states[model] = .downloading
    Task {
      do {
        try await ModelStorage.download(model)
        states[model] = Self.state(for: await ModelStorage.status(for: model))
        if settings.selectedModel == model {
          coordinator.prepareSelectedModel()
        }
      } catch {
        states[model] = .failed(error.localizedDescription)
      }
    }
  }

  func delete(_ model: BenchmarkModel) {
    guard states[model]?.isBusy != true else { return }
    states[model] = .deleting
    Task {
      do {
        try await coordinator.unloadModel(model)
        try await ModelStorage.delete(model)
        states[model] = Self.state(for: await ModelStorage.status(for: model))
      } catch {
        states[model] = .failed(error.localizedDescription)
      }
    }
  }

  private static func state(for status: ModelStorageStatus) -> ModelDownloadState {
    switch status {
    case .notDownloaded: .notDownloaded
    case .downloaded(let bytes): .downloaded(bytes: bytes)
    case .unsupported(let message): .unavailable(message)
    }
  }
}
