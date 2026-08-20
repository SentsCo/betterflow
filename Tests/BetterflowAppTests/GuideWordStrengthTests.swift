import BetterflowBenchmarkCore
import Foundation
import Testing

@testable import BetterflowApp

@Test @MainActor
func guideWordStrengthPersistsIndependentlyForEachModel() {
  let suiteName = "GuideWordStrengthTests-\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suiteName)!
  defer { defaults.removePersistentDomain(forName: suiteName) }

  let settings = AppSettings(defaults: defaults)
  #expect(settings.guideWordStrength(for: .parakeet) == .normal)
  #expect(settings.guideWordStrength(for: .whisper) == .normal)

  settings.setGuideWordStrength(.conservative, for: .parakeet)

  #expect(settings.guideWordStrength(for: .parakeet) == .conservative)
  #expect(settings.guideWordStrength(for: .whisper) == .normal)

  let reloaded = AppSettings(defaults: defaults)
  #expect(reloaded.guideWordStrength(for: .parakeet) == .conservative)
  #expect(reloaded.guideWordStrength(for: .whisper) == .normal)
}
