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

@Test @MainActor
func cloudTranscriptionPreferencesPersistIndependently() {
  let suiteName = "CloudTranscriptionSettingsTests-\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suiteName)!
  defer { defaults.removePersistentDomain(forName: suiteName) }

  let settings = AppSettings(defaults: defaults)
  #expect(settings.transcriptionMode == .localOnly)
  #expect(settings.cloudProvider == .deepgram)
  #expect(settings.guideWordStrength(for: .deepgram) == .normal)
  #expect(settings.guideWordStrength(for: .elevenLabs) == .normal)

  settings.transcriptionMode = .automatic
  settings.cloudProvider = .elevenLabs
  settings.setGuideWordStrength(.conservative, for: .elevenLabs)

  let reloaded = AppSettings(defaults: defaults)
  #expect(reloaded.transcriptionMode == .automatic)
  #expect(reloaded.cloudProvider == .elevenLabs)
  #expect(reloaded.guideWordStrength(for: .deepgram) == .normal)
  #expect(reloaded.guideWordStrength(for: .elevenLabs) == .conservative)
}

@Test
func streamingAudioResamplerPreservesSamplesAcrossChunks() {
  var resampler = StreamingAudioResampler(sourceRate: 16_000, destinationRate: 24_000)
  let first = resampler.process(Array(repeating: 0.5, count: 480), final: false)
  let second = resampler.process(Array(repeating: 0.5, count: 480), final: true)
  let output = first + second

  #expect(output.count == 1_440)
  #expect(output.allSatisfy { abs($0 - 0.5) < 0.000_001 })
}

@Test
func streamingAudioResamplerDownsamplesCaptureAudioAcrossChunks() {
  var resampler = StreamingAudioResampler(sourceRate: 24_000, destinationRate: 16_000)
  let first = resampler.process(Array(repeating: -0.25, count: 720), final: false)
  let second = resampler.process(Array(repeating: -0.25, count: 720), final: true)
  let output = first + second

  #expect(output.count == 960)
  #expect(output.allSatisfy { abs($0 + 0.25) < 0.000_001 })
}
