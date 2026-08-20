import BetterflowBenchmarkCore
import Foundation
@preconcurrency import MoonshineVoice

final class MoonshineAdapter: ModelAdapter, @unchecked Sendable {
  let model: BenchmarkModel
  private let architecture: ModelArch

  private var transcriber: Transcriber?
  private var guideWords: [String] = []

  init(model: BenchmarkModel, architecture: ModelArch) {
    self.model = model
    self.architecture = architecture
  }

  func prepare(guideWords: [String], strength: GuideWordStrength) async throws {
    self.guideWords = guideWords
    let boost = strength == .conservative ? "1.0" : "2.0"
    transcriber = try await Transcriber.load(
      language: "en",
      modelArch: architecture,
      options: [TranscriberOption(name: "keyterm_boost", value: boost)]
    )
  }

  func transcribe(
    audio: AudioData,
    guidance: GuidanceMode,
    cadenceMilliseconds: Double,
    realtime: Bool,
    onHypothesis: @escaping @Sendable (HypothesisEvent) -> Void
  ) async throws -> AdapterOutput {
    guard let transcriber else { throw AdapterError.notPrepared(model.rawValue) }
    try transcriber.setKeyterms(guidance == .on ? guideWords : [])
    if cadenceMilliseconds >= audio.durationSeconds * 1_000 {
      let started = ContinuousClock.now
      let inferenceStart = ContinuousClock.now
      let transcript = try transcriber.transcribeWithoutStreaming(
        audioData: audio.samples,
        sampleRate: Int32(audio.sampleRate)
      )
      let update = event(
        text: transcript.lines.map(\.text).joined(separator: " "),
        final: true,
        audioMilliseconds: audio.durationSeconds * 1_000,
        started: started
      )
      onHypothesis(update)
      return AdapterOutput(
        events: [update],
        inferenceMilliseconds: inferenceStart.duration(to: .now).milliseconds,
        guidanceMechanism: guidance == .on ? "Moonshine decoder keyterms" : "disabled"
      )
    }

    let stream = try transcriber.createStream(updateInterval: 3_600)
    try stream.start()

    let started = ContinuousClock.now
    let step = max(1, Int(audio.sampleRate * cadenceMilliseconds / 1_000))
    var events: [HypothesisEvent] = []
    var inferenceMilliseconds = 0.0
    var offset = 0

    while offset < audio.samples.count {
      let end = min(offset + step, audio.samples.count)
      let audioMilliseconds = Double(end) / audio.sampleRate * 1_000
      try await pace(audioMilliseconds: audioMilliseconds, started: started, realtime: realtime)
      try stream.addAudio(Array(audio.samples[offset..<end]), sampleRate: Int32(audio.sampleRate))

      let inferenceStart = ContinuousClock.now
      let transcript = try stream.updateTranscription(
        flags: end == audio.samples.count ? TranscribeStreamFlags.flagForceUpdate : 0
      )
      inferenceMilliseconds += inferenceStart.duration(to: .now).milliseconds
      let text = transcript.lines.map(\.text).joined(separator: " ")
      let update = event(
        text: text,
        final: end == audio.samples.count,
        audioMilliseconds: audioMilliseconds,
        started: started
      )
      events.append(update)
      onHypothesis(update)
      offset = end
    }
    try stream.stop()

    return AdapterOutput(
      events: events,
      inferenceMilliseconds: inferenceMilliseconds,
      guidanceMechanism: guidance == .on ? "Moonshine decoder keyterms" : "disabled"
    )
  }

  func makeLiveSession(guidance: GuidanceMode) async throws
    -> (any LiveTranscriptionSession)?
  {
    guard let transcriber else { throw AdapterError.notPrepared(model.rawValue) }
    try transcriber.setKeyterms(guidance == .on ? guideWords : [])
    return try MoonshineLiveSession(transcriber: transcriber)
  }

  func close() async {
    transcriber = nil
  }
}

private actor MoonshineLiveSession: LiveTranscriptionSession {
  private let stream: MoonshineVoice.Stream
  private let transcript = MoonshineTranscript()
  private let started = ContinuousClock.now
  private var audioSampleCount = 0
  private var closed = false

  init(transcriber: Transcriber) throws {
    stream = try transcriber.createStream(updateInterval: 3_600)
    let transcript = self.transcript
    stream.addListener { event in
      transcript.record(event)
    }
    try stream.start()
  }

  func append(audio: AudioData, final: Bool) async throws -> HypothesisEvent {
    audioSampleCount += audio.samples.count
    try stream.addAudio(audio.samples, sampleRate: Int32(audio.sampleRate))

    if final {
      try stream.stop()
      closed = true
      if let error = transcript.error { throw error }
    } else {
      try stream.updateTranscription()
    }

    return HypothesisEvent(
      elapsedMilliseconds: started.duration(to: .now).milliseconds,
      audioMilliseconds: Double(audioSampleCount) / audio.sampleRate * 1_000,
      text: transcript.text,
      isFinal: final
    )
  }

  func close() async {
    guard !closed else {
      stream.close()
      return
    }
    closed = true
    stream.close()
  }
}

private final class MoonshineTranscript: @unchecked Sendable {
  private let lock = NSLock()
  private var lines: [UInt64: TranscriptLine] = [:]
  private var storedError: Error?

  var text: String {
    lock.withLock {
      lines.values
        .sorted { $0.startTime < $1.startTime }
        .map(\.text)
        .joined(separator: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }
  }

  var error: Error? {
    lock.withLock { storedError }
  }

  func record(_ event: TranscriptEvent) {
    lock.withLock {
      if let error = event as? TranscriptError {
        storedError = error.error
      } else {
        lines[event.line.lineId] = event.line
      }
    }
  }
}
