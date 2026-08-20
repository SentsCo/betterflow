@preconcurrency import AVFoundation
import BetterflowBenchmarkCore
import Foundation
@preconcurrency import Speech

final class AppleSpeechAdapter: ModelAdapter, @unchecked Sendable {
  let model: BenchmarkModel

  private var guideWords: [String] = []

  init(model: BenchmarkModel) {
    precondition(model == .appleSpeech || model == .appleDictation)
    self.model = model
  }

  func prepare(guideWords: [String]) async throws {
    self.guideWords = guideWords
    guard #available(macOS 26.0, *) else {
      throw AdapterError.unsupported("\(model.shortName) requires macOS 26 or newer.")
    }
    let locale = try await englishLocale()
    switch model {
    case .appleSpeech:
      try await installAssets(
        for: SpeechTranscriber(locale: locale, preset: .progressiveTranscription))
    case .appleDictation:
      try await installAssets(
        for: DictationTranscriber(locale: locale, preset: .progressiveShortDictation)
      )
    default:
      preconditionFailure("AppleSpeechAdapter received \(model.rawValue)")
    }
  }

  func transcribe(
    audio: AudioData,
    guidance: GuidanceMode,
    cadenceMilliseconds: Double,
    realtime: Bool,
    onHypothesis: @escaping @Sendable (HypothesisEvent) -> Void
  ) async throws -> AdapterOutput {
    guard #available(macOS 26.0, *) else {
      throw AdapterError.unsupported("\(model.shortName) requires macOS 26 or newer.")
    }
    let locale = try await englishLocale()
    switch model {
    case .appleSpeech:
      let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
      return try await run(
        audio: audio,
        guidance: guidance,
        cadenceMilliseconds: cadenceMilliseconds,
        realtime: realtime,
        module: transcriber,
        consumeResults: { started in
          try await Self.consume(
            transcriber.results,
            started: started,
            onHypothesis: onHypothesis
          )
        },
        onHypothesis: onHypothesis
      )
    case .appleDictation:
      let transcriber = DictationTranscriber(
        locale: locale,
        preset: .progressiveShortDictation
      )
      return try await run(
        audio: audio,
        guidance: guidance,
        cadenceMilliseconds: cadenceMilliseconds,
        realtime: realtime,
        module: transcriber,
        consumeResults: { started in
          try await Self.consume(
            transcriber.results,
            started: started,
            onHypothesis: onHypothesis
          )
        },
        onHypothesis: onHypothesis
      )
    default:
      preconditionFailure("AppleSpeechAdapter received \(model.rawValue)")
    }
  }

  @available(macOS 26.0, *)
  private func englishLocale() async throws -> Locale {
    let requested = Locale(identifier: "en-US")
    let supported: Locale?
    switch model {
    case .appleSpeech:
      supported = await SpeechTranscriber.supportedLocale(equivalentTo: requested)
    case .appleDictation:
      supported = await DictationTranscriber.supportedLocale(equivalentTo: requested)
    default:
      supported = nil
    }
    guard let supported else {
      throw AdapterError.unsupported("\(model.shortName) does not support English on this Mac.")
    }
    return supported
  }

  @available(macOS 26.0, *)
  private func installAssets(for module: any SpeechModule) async throws {
    let modules: [any SpeechModule] = [module]
    switch await AssetInventory.status(forModules: modules) {
    case .installed:
      return
    case .unsupported:
      throw AdapterError.unsupported(
        "Apple has no compatible \(model.shortName) asset for this Mac.")
    case .supported, .downloading:
      guard let request = try await AssetInventory.assetInstallationRequest(supporting: modules)
      else {
        throw AdapterError.unsupported("Apple could not create a model download request.")
      }
      try await request.downloadAndInstall()
    @unknown default:
      throw AdapterError.unsupported("Apple returned an unknown model asset status.")
    }
  }

  @available(macOS 26.0, *)
  private func run(
    audio: AudioData,
    guidance: GuidanceMode,
    cadenceMilliseconds: Double,
    realtime: Bool,
    module: any SpeechModule,
    consumeResults: @escaping @Sendable (ContinuousClock.Instant) async throws -> AppleResults,
    onHypothesis: @escaping @Sendable (HypothesisEvent) -> Void
  ) async throws -> AdapterOutput {
    let modules: [any SpeechModule] = [module]
    guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules) else {
      throw AdapterError.unsupported("Apple returned no compatible input audio format.")
    }

    let context = AnalysisContext()
    context.contextualStrings = guidance == .on ? [.general: guideWords] : [:]
    let analyzer = SpeechAnalyzer(modules: modules)
    try await analyzer.setContext(context)
    let (inputs, continuation) = AsyncStream<AnalyzerInput>.makeStream()
    try await analyzer.start(inputSequence: inputs)

    let started = ContinuousClock.now
    let resultTask = Task { try await consumeResults(started) }
    let step = max(1, Int(audio.sampleRate * cadenceMilliseconds / 1_000))
    var offset = 0
    while offset < audio.samples.count {
      let end = min(offset + step, audio.samples.count)
      let audioMilliseconds = Double(end) / audio.sampleRate * 1_000
      try await pace(audioMilliseconds: audioMilliseconds, started: started, realtime: realtime)
      let source = try AudioIO.buffer(samples: audio.samples[offset..<end])
      continuation.yield(AnalyzerInput(buffer: try AudioIO.convert(source, to: format)))
      offset = end
    }
    continuation.finish()
    try await analyzer.finalizeAndFinishThroughEndOfInput()

    var collected = try await resultTask.value
    let final = event(
      text: collected.text,
      final: true,
      audioMilliseconds: audio.durationSeconds * 1_000,
      started: started
    )
    collected.events.append(final)
    onHypothesis(final)
    let elapsed = started.duration(to: .now).milliseconds
    let pacingMilliseconds = realtime ? audio.durationSeconds * 1_000 : 0
    return AdapterOutput(
      events: collected.events,
      inferenceMilliseconds: max(0, elapsed - pacingMilliseconds),
      guidanceMechanism: guidance == .on
        ? "Apple AnalysisContext contextual strings" : "disabled"
    )
  }

  @available(macOS 26.0, *)
  private static func consume(
    _ results: SpeechTranscriber.Results,
    started: ContinuousClock.Instant,
    onHypothesis: @escaping @Sendable (HypothesisEvent) -> Void
  ) async throws -> AppleResults {
    var accumulated = AppleResults()
    for try await result in results {
      accumulated.update(
        text: String(result.text.characters),
        isFinal: result.isFinal,
        audioMilliseconds: result.range.end.seconds * 1_000,
        started: started,
        onHypothesis: onHypothesis
      )
    }
    return accumulated
  }

  @available(macOS 26.0, *)
  private static func consume(
    _ results: DictationTranscriber.Results,
    started: ContinuousClock.Instant,
    onHypothesis: @escaping @Sendable (HypothesisEvent) -> Void
  ) async throws -> AppleResults {
    var accumulated = AppleResults()
    for try await result in results {
      accumulated.update(
        text: String(result.text.characters),
        isFinal: result.isFinal,
        audioMilliseconds: result.range.end.seconds * 1_000,
        started: started,
        onHypothesis: onHypothesis
      )
    }
    return accumulated
  }
}

private struct AppleResults: Sendable {
  var finalized = ""
  var volatile = ""
  var events: [HypothesisEvent] = []

  var text: String { finalized + volatile }

  mutating func update(
    text resultText: String,
    isFinal: Bool,
    audioMilliseconds: Double,
    started: ContinuousClock.Instant,
    onHypothesis: @escaping @Sendable (HypothesisEvent) -> Void
  ) {
    if isFinal {
      let previousText = text
      finalized += resultText
      volatile = previousText.hasPrefix(finalized)
        ? String(previousText.dropFirst(finalized.count))
        : ""
    } else {
      volatile = resultText
    }
    let update = HypothesisEvent(
      elapsedMilliseconds: started.duration(to: .now).milliseconds,
      audioMilliseconds: audioMilliseconds,
      text: text.trimmingCharacters(in: .whitespacesAndNewlines),
      isFinal: false
    )
    guard events.last?.text != update.text else { return }
    events.append(update)
    onHypothesis(update)
  }
}

extension CMTime {
  fileprivate var seconds: Double {
    let value = CMTimeGetSeconds(self)
    return value.isFinite ? value : 0
  }
}
