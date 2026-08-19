import BetterflowBenchmarkCore
import FluidAudio
import Foundation

final class FluidStreamingAdapter: ModelAdapter, @unchecked Sendable {
  let model: BenchmarkModel

  private var manager: (any StreamingAsrManager)?

  init(model: BenchmarkModel) {
    precondition(model == .parakeetEou || model == .nemotron)
    self.model = model
  }

  func prepare(guideWords _: [String]) async throws {
    let manager: any StreamingAsrManager
    switch model {
    case .parakeetEou:
      manager = StreamingEouAsrManager(chunkSize: .ms160)
    case .nemotron:
      manager = StreamingNemotronAsrManager()
    default:
      preconditionFailure("FluidStreamingAdapter received \(model.rawValue)")
    }
    try await manager.loadModels()
    self.manager = manager
  }

  func transcribe(
    audio: AudioData,
    guidance _: GuidanceMode,
    cadenceMilliseconds: Double,
    realtime: Bool,
    onHypothesis: @escaping @Sendable (HypothesisEvent) -> Void
  ) async throws -> AdapterOutput {
    guard let manager else { throw AdapterError.notPrepared(model.rawValue) }
    try await manager.reset()
    let started = ContinuousClock.now
    let step = max(1, Int(audio.sampleRate * cadenceMilliseconds / 1_000))
    var events: [HypothesisEvent] = []
    var inferenceMilliseconds = 0.0
    var offset = 0

    while offset < audio.samples.count {
      let end = min(offset + step, audio.samples.count)
      let audioMilliseconds = Double(end) / audio.sampleRate * 1_000
      try await pace(audioMilliseconds: audioMilliseconds, started: started, realtime: realtime)
      let buffer = try AudioIO.buffer(samples: audio.samples[offset..<end])
      let inferenceStart = ContinuousClock.now
      try await manager.appendAudio(buffer)
      try await manager.processBufferedAudio()
      let text = await manager.getPartialTranscript()
      inferenceMilliseconds += inferenceStart.duration(to: .now).milliseconds
      if events.last?.text != text, !text.isEmpty {
        let update = event(
          text: text,
          final: false,
          audioMilliseconds: audioMilliseconds,
          started: started
        )
        events.append(update)
        onHypothesis(update)
      }
      offset = end
    }

    let finishStart = ContinuousClock.now
    let text = try await manager.finish()
    inferenceMilliseconds += finishStart.duration(to: .now).milliseconds
    let final = event(
      text: text,
      final: true,
      audioMilliseconds: audio.durationSeconds * 1_000,
      started: started
    )
    events.append(final)
    onHypothesis(final)
    return AdapterOutput(
      events: events,
      inferenceMilliseconds: inferenceMilliseconds,
      guidanceMechanism: "unsupported"
    )
  }

  func makeLiveSession(guidance _: GuidanceMode) async throws
    -> (any LiveTranscriptionSession)?
  {
    guard let manager else { throw AdapterError.notPrepared(model.rawValue) }
    try await manager.reset()
    return FluidLiveSession(manager: manager)
  }

  func close() async {
    await manager?.cleanup()
    manager = nil
  }
}

private actor FluidLiveSession: LiveTranscriptionSession {
  private let manager: any StreamingAsrManager
  private let started = ContinuousClock.now
  private var audioSampleCount = 0

  init(manager: any StreamingAsrManager) {
    self.manager = manager
  }

  func append(audio: AudioData, final: Bool) async throws -> HypothesisEvent {
    audioSampleCount += audio.samples.count
    if !audio.samples.isEmpty {
      let buffer = try AudioIO.buffer(samples: audio.samples[...])
      try await manager.appendAudio(buffer)
      try await manager.processBufferedAudio()
    }
    let text = final ? try await manager.finish() : await manager.getPartialTranscript()
    return HypothesisEvent(
      elapsedMilliseconds: started.duration(to: .now).milliseconds,
      audioMilliseconds: Double(audioSampleCount) / audio.sampleRate * 1_000,
      text: text.trimmingCharacters(in: .whitespacesAndNewlines),
      isFinal: final
    )
  }

  func close() async {}
}
