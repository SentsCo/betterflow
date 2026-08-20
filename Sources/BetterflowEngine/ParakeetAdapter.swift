import BetterflowBenchmarkCore
import FluidAudio
import Foundation

final class ParakeetAdapter: ModelAdapter, @unchecked Sendable {
  let model: BenchmarkModel = .parakeet

  private var manager: AsrManager?
  private var boosting: VocabularyBoostingSession?

  func prepare(guideWords: [String], strength: GuideWordStrength) async throws {
    let models = try await AsrModels.downloadAndLoad(version: .tdtCtc110m)
    manager = AsrManager(models: models)

    let vocabularyURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("betterflow-vocabulary-\(UUID().uuidString).txt")
    try guideWords.joined(separator: "\n").write(
      to: vocabularyURL,
      atomically: true,
      encoding: .utf8
    )
    defer { try? FileManager.default.removeItem(at: vocabularyURL) }
    let loaded = try await CustomVocabularyContext.loadWithCtcTokens(from: vocabularyURL.path)
    boosting = try await VocabularyBoostingSession(
      vocabulary: loaded.vocab,
      ctcModels: loaded.models,
      config: rescorerConfig(for: strength)
    )
  }

  private func rescorerConfig(for strength: GuideWordStrength) -> VocabularyRescorer.Config {
    switch strength {
    case .normal:
      VocabularyRescorer.Config(
        shortTermCbwTaperPivot: 5,
        spotterRescueMinSimilarity: 0.30,
        spotterRescueMultiWordMinSimilarity: 0.50
      )
    case .conservative:
      VocabularyRescorer.Config(
        shortTermCbwTaperPivot: 5,
        spotterRescueMinSimilarity: 0.30,
        spotterRescueMultiWordMinSimilarity: 0.50,
        spotterRescueEnabled: false
      )
    }
  }

  func transcribe(
    audio: AudioData,
    guidance: GuidanceMode,
    cadenceMilliseconds: Double,
    realtime: Bool,
    onHypothesis: @escaping @Sendable (HypothesisEvent) -> Void
  ) async throws -> AdapterOutput {
    guard let manager else { throw AdapterError.notPrepared(model.rawValue) }
    let started = ContinuousClock.now
    let step = max(1, Int(audio.sampleRate * cadenceMilliseconds / 1_000))
    var events: [HypothesisEvent] = []
    var inferenceMilliseconds = 0.0
    var end = min(step, audio.samples.count)

    while true {
      let audioMilliseconds = Double(end) / audio.sampleRate * 1_000
      try await pace(audioMilliseconds: audioMilliseconds, started: started, realtime: realtime)
      var state = TdtDecoderState.make(decoderLayers: 1)
      let inferenceStart = ContinuousClock.now
      let prefix = Array(audio.samples.prefix(end))
      let result = try await manager.transcribe(prefix, decoderState: &state)
      var text = result.text
      if guidance == .on,
        let boosting,
        let timings = result.tokenTimings,
        let rescored = await boosting.rescore(
          text: result.text,
          tokenTimings: timings,
          audioSamples: prefix
        )
      {
        text = rescored.text
      }
      inferenceMilliseconds += inferenceStart.duration(to: .now).milliseconds
      let isFinal = end == audio.samples.count
      let update = event(
        text: text,
        final: isFinal,
        audioMilliseconds: audioMilliseconds,
        started: started
      )
      events.append(update)
      onHypothesis(update)
      if isFinal { break }
      end = min(end + step, audio.samples.count)
    }

    return AdapterOutput(
      events: events,
      inferenceMilliseconds: inferenceMilliseconds,
      guidanceMechanism: guidance == .on
        ? "FluidAudio CTC acoustic keyword spotting + constrained rescoring"
        : "disabled"
    )
  }
}

enum AdapterError: LocalizedError {
  case notPrepared(String)
  case missingTokenizer
  case unsupported(String)
  case worker(String)

  var errorDescription: String? {
    switch self {
    case .notPrepared(let model): "\(model) was not prepared."
    case .missingTokenizer: "WhisperKit did not load a tokenizer."
    case .unsupported(let message): message
    case .worker(let message): "Qwen worker error: \(message)"
    }
  }
}
