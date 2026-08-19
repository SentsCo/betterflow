import BetterflowBenchmarkCore
import Foundation
@preconcurrency import WhisperKit

final class WhisperAdapter: ModelAdapter, @unchecked Sendable {
  let model: BenchmarkModel = .whisper

  private var whisper: WhisperKit?
  private var promptTokens: [Int] = []

  func prepare(guideWords: [String]) async throws {
    let whisper = try await WhisperKit(
      model: "large-v3-v20240930_turbo",
      verbose: false,
      prewarm: true,
      load: true
    )
    guard let tokenizer = whisper.tokenizer else { throw AdapterError.missingTokenizer }
    let prompt = " Vocabulary: \(guideWords.joined(separator: ", "))."
    promptTokens = tokenizer.encode(text: prompt)
      .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
    self.whisper = whisper
  }

  func transcribe(
    audio: AudioData,
    guidance: GuidanceMode,
    cadenceMilliseconds: Double,
    realtime: Bool,
    onHypothesis: @escaping @Sendable (HypothesisEvent) -> Void
  ) async throws -> AdapterOutput {
    guard let whisper else { throw AdapterError.notPrepared(model.rawValue) }
    let started = ContinuousClock.now
    let step = max(1, Int(audio.sampleRate * cadenceMilliseconds / 1_000))
    var events: [HypothesisEvent] = []
    var inferenceMilliseconds = 0.0
    var end = min(step, audio.samples.count)

    while true {
      let audioMilliseconds = Double(end) / audio.sampleRate * 1_000
      try await pace(audioMilliseconds: audioMilliseconds, started: started, realtime: realtime)
      let options = DecodingOptions(
        language: "en",
        temperature: 0,
        usePrefillPrompt: true,
        skipSpecialTokens: true,
        withoutTimestamps: true,
        wordTimestamps: false,
        promptTokens: guidance == .on ? promptTokens : nil,
        concurrentWorkerCount: 1
      )
      let inferenceStart = ContinuousClock.now
      let results = try await whisper.transcribe(
        audioArray: Array(audio.samples.prefix(end)),
        decodeOptions: options
      )
      inferenceMilliseconds += inferenceStart.duration(to: .now).milliseconds
      let text = results.map(\.text).joined(separator: " ")
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
      guidanceMechanism: guidance == .on ? "Whisper decoder prompt tokens" : "disabled"
    )
  }

  func close() async {
    await whisper?.unloadModels()
    whisper = nil
  }
}
