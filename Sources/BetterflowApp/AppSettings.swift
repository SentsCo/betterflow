import AppKit
import BetterflowBenchmarkCore
import Combine
import Foundation

enum DictationKey: String, CaseIterable, Identifiable {
  case leftCommand
  case rightCommand
  case leftOption
  case rightOption
  case leftControl
  case rightControl
  case function

  var id: String { rawValue }

  var label: String {
    switch self {
    case .leftCommand: "Left Command"
    case .rightCommand: "Right Command"
    case .leftOption: "Left Option"
    case .rightOption: "Right Option"
    case .leftControl: "Left Control"
    case .rightControl: "Right Control"
    case .function: "Fn / Globe"
    }
  }
}

struct ScreenshotShortcut: Codable, Equatable, Sendable {
  static let standard = ScreenshotShortcut(
    keyCode: 19,
    modifierFlagsRawValue: NSEvent.ModifierFlags([.command, .shift]).rawValue,
    key: "2"
  )

  let keyCode: UInt16
  let modifierFlagsRawValue: UInt
  let key: String

  var modifierFlags: NSEvent.ModifierFlags {
    NSEvent.ModifierFlags(rawValue: modifierFlagsRawValue)
      .intersection(.deviceIndependentFlagsMask)
  }

  var label: String {
    let flags = modifierFlags
    return [
      flags.contains(.control) ? "⌃" : "",
      flags.contains(.option) ? "⌥" : "",
      flags.contains(.shift) ? "⇧" : "",
      flags.contains(.command) ? "⌘" : "",
      key,
    ].joined()
  }
}

@MainActor
final class AppSettings: ObservableObject {
  private enum Key {
    static let selectedModel = "selectedModel"
    static let guideWords = "guideWords"
    static let priorityEnabled = "microphonePriorityEnabled"
    static let microphonePriority = "microphonePriority"
    static let knownMicrophoneNames = "knownMicrophoneNames"
    static let dictationKey = "dictationKey"
    static let legacyPushToTalkKey = "pushToTalkKey"
    static let showOverlay = "showOverlay"
    static let cleanupModel = "cleanupModel"
    static let cleanupEnabledByDefault = "cleanupEnabledByDefault"
    static let screenshotShortcut = "screenshotShortcut"
  }

  private let defaults: UserDefaults

  @Published var selectedModel: BenchmarkModel {
    didSet { defaults.set(selectedModel.rawValue, forKey: Key.selectedModel) }
  }

  @Published var guideWords: [String] {
    didSet { defaults.set(guideWords, forKey: Key.guideWords) }
  }

  @Published var microphonePriorityEnabled: Bool {
    didSet { defaults.set(microphonePriorityEnabled, forKey: Key.priorityEnabled) }
  }

  @Published var microphonePriority: [String] {
    didSet { defaults.set(microphonePriority, forKey: Key.microphonePriority) }
  }

  @Published private(set) var knownMicrophoneNames: [String: String] {
    didSet { defaults.set(knownMicrophoneNames, forKey: Key.knownMicrophoneNames) }
  }

  @Published var dictationKey: DictationKey {
    didSet { defaults.set(dictationKey.rawValue, forKey: Key.dictationKey) }
  }

  @Published var showOverlay: Bool {
    didSet { defaults.set(showOverlay, forKey: Key.showOverlay) }
  }

  @Published var cleanupModel: CleanupModel {
    didSet { defaults.set(cleanupModel.rawValue, forKey: Key.cleanupModel) }
  }

  @Published var cleanupEnabledByDefault: Bool {
    didSet {
      defaults.set(cleanupEnabledByDefault, forKey: Key.cleanupEnabledByDefault)
    }
  }

  @Published var screenshotShortcut: ScreenshotShortcut {
    didSet {
      defaults.set(try? JSONEncoder().encode(screenshotShortcut), forKey: Key.screenshotShortcut)
    }
  }

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    selectedModel =
      defaults.string(forKey: Key.selectedModel)
      .flatMap(BenchmarkModel.init(rawValue:)) ?? .moonshineSmall
    guideWords =
      defaults.stringArray(forKey: Key.guideWords)
      ?? ["Zach", "Sara", "WorkflowDog", "TanStack", "Postgres"]
    microphonePriorityEnabled = defaults.bool(forKey: Key.priorityEnabled)
    microphonePriority = defaults.stringArray(forKey: Key.microphonePriority) ?? []
    knownMicrophoneNames =
      defaults.dictionary(forKey: Key.knownMicrophoneNames) as? [String: String] ?? [:]
    dictationKey =
      (defaults.string(forKey: Key.dictationKey)
      ?? defaults.string(forKey: Key.legacyPushToTalkKey))
      .flatMap(DictationKey.init(rawValue:)) ?? .rightControl
    showOverlay = defaults.object(forKey: Key.showOverlay) as? Bool ?? true
    cleanupModel =
      defaults.string(forKey: Key.cleanupModel)
      .flatMap(CleanupModel.init(rawValue:)) ?? .appleFoundation
    cleanupEnabledByDefault =
      defaults.object(forKey: Key.cleanupEnabledByDefault) as? Bool ?? false
    screenshotShortcut =
      defaults.data(forKey: Key.screenshotShortcut)
      .flatMap { try? JSONDecoder().decode(ScreenshotShortcut.self, from: $0) }
      ?? .standard
  }

  func addGuideWord() {
    guideWords.append("")
  }

  func removeGuideWords(at offsets: IndexSet) {
    guideWords.remove(atOffsets: offsets)
  }

  func cleanGuideWords() -> [String] {
    guideWords
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
  }

  func rememberMicrophones(_ devices: [AudioInputDevice]) {
    let updatedNames = devices.reduce(into: knownMicrophoneNames) { names, device in
      names[device.id] = device.name
    }
    if updatedNames != knownMicrophoneNames {
      knownMicrophoneNames = updatedNames
    }

    let knownIDs = Set(microphonePriority)
    let newlyDiscovered = devices.map(\.id).filter { !knownIDs.contains($0) }
    if !newlyDiscovered.isEmpty {
      microphonePriority.append(contentsOf: newlyDiscovered)
    }
  }

  func forgetMicrophone(_ id: String) {
    microphonePriority.removeAll { $0 == id }
    knownMicrophoneNames.removeValue(forKey: id)
  }
}
