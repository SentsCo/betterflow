import BetterflowBenchmarkCore
import Foundation
@preconcurrency import MoonshineVoice

public struct AdapterOutput: Sendable {
  public let events: [HypothesisEvent]
  public let inferenceMilliseconds: Double
  public let guidanceMechanism: String
}

public protocol ModelAdapter: AnyObject, Sendable {
  var model: BenchmarkModel { get }
  func prepare(guideWords: [String], strength: GuideWordStrength) async throws
  func transcribe(
    audio: AudioData,
    guidance: GuidanceMode,
    cadenceMilliseconds: Double,
    realtime: Bool,
    onHypothesis: @escaping @Sendable (HypothesisEvent) -> Void
  ) async throws -> AdapterOutput
  func makeLiveSession(guidance: GuidanceMode) async throws -> (any LiveTranscriptionSession)?
  func close() async
}

public protocol LiveTranscriptionSession: Actor {
  func append(audio: AudioData, final: Bool) async throws -> HypothesisEvent
  func close() async
}

extension ModelAdapter {
  public func prepare(guideWords: [String]) async throws {
    try await prepare(guideWords: guideWords, strength: .normal)
  }

  public func makeLiveSession(guidance _: GuidanceMode) async throws
    -> (any LiveTranscriptionSession)?
  {
    nil
  }

  func close() async {}

  func pace(
    audioMilliseconds: Double,
    started: ContinuousClock.Instant,
    realtime: Bool
  ) async throws {
    guard realtime else { return }
    let elapsed = started.duration(to: .now).milliseconds
    let remaining = audioMilliseconds - elapsed
    if remaining > 0 {
      try await Task.sleep(for: .milliseconds(remaining))
    }
  }

  func event(
    text: String,
    final: Bool,
    audioMilliseconds: Double,
    started: ContinuousClock.Instant
  ) -> HypothesisEvent {
    HypothesisEvent(
      elapsedMilliseconds: started.duration(to: .now).milliseconds,
      audioMilliseconds: audioMilliseconds,
      text: text.trimmingCharacters(in: .whitespacesAndNewlines),
      isFinal: final
    )
  }
}

extension Duration {
  public var milliseconds: Double {
    let components = self.components
    return Double(components.seconds) * 1_000
      + Double(components.attoseconds) / 1_000_000_000_000_000
  }
}

public enum AdapterFactory {
  public static func make(_ model: BenchmarkModel) -> any ModelAdapter {
    switch model {
    case .parakeet: ParakeetAdapter()
    case .moonshineSmall: MoonshineAdapter(model: .moonshineSmall, architecture: .smallStreaming)
    case .moonshineMedium: MoonshineAdapter(model: .moonshineMedium, architecture: .mediumStreaming)
    case .whisper: WhisperAdapter()
    case .appleSpeech, .appleDictation: AppleSpeechAdapter(model: model)
    case .parakeetEou, .nemotron: FluidStreamingAdapter(model: model)
    case .qwen: QwenAdapter()
    }
  }
}
