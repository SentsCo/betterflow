import Foundation
import Testing

@testable import BetterflowApp

@Test @MainActor
func voiceDictationIsOnByDefaultAndPersistsWhenTurnedOff() {
  let suiteName = "DictationSettingTests-\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suiteName)!
  defer { defaults.removePersistentDomain(forName: suiteName) }

  let settings = AppSettings(defaults: defaults)
  #expect(settings.dictationEnabled)

  settings.dictationEnabled = false

  #expect(!AppSettings(defaults: defaults).dictationEnabled)
}
