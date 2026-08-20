import Foundation

public enum BenchmarkModel: String, Codable, CaseIterable, Sendable {
  case parakeet = "parakeet-tdt-ctc-110m"
  case moonshineSmall = "moonshine-small-streaming"
  case moonshineMedium = "moonshine-medium-streaming"
  case whisper = "whisper-large-v3"
  case appleSpeech = "apple-speech-transcriber"
  case appleDictation = "apple-dictation-transcriber"
  case parakeetEou = "parakeet-eou-120m"
  case nemotron = "nemotron-streaming-0.6b"
  case qwen = "qwen3-asr-0.6b-8bit"

  public var shortName: String {
    switch self {
    case .parakeet: "parakeet"
    case .moonshineSmall: "moonshine-small"
    case .moonshineMedium: "moonshine-medium"
    case .whisper: "whisper"
    case .appleSpeech: "apple-speech"
    case .appleDictation: "apple-dictation"
    case .parakeetEou: "parakeet-eou"
    case .nemotron: "nemotron"
    case .qwen: "qwen"
    }
  }

  public var displayName: String {
    switch self {
    case .parakeet: "Parakeet TDT-CTC 110M"
    case .moonshineSmall: "Moonshine Small Streaming"
    case .moonshineMedium: "Moonshine Medium Streaming"
    case .whisper: "Whisper Large v3 Turbo"
    case .appleSpeech: "Apple SpeechTranscriber"
    case .appleDictation: "Apple DictationTranscriber"
    case .parakeetEou: "Parakeet EOU 120M"
    case .nemotron: "NVIDIA Nemotron Streaming 0.6B"
    case .qwen: "Qwen3-ASR 0.6B 8-bit"
    }
  }

  public var summary: String {
    switch self {
    case .parakeet:
      "A compact, fast model that can revise its transcript and favor your guide words."
    case .moonshineSmall:
      "The lighter Moonshine option, built for responsive live transcription with guide words."
    case .moonshineMedium:
      "A larger Moonshine model that trades more processing power for better transcription accuracy."
    case .whisper:
      "A large general-purpose model with strong accuracy, but heavier processing than the smaller options."
    case .appleSpeech:
      "Apple's system-managed model for longer-form live transcription, with no manual download required."
    case .appleDictation:
      "Apple's system-managed model tuned for short dictation, with no manual download required."
    case .parakeetEou:
      "A compact streaming model tuned to finish utterances quickly, but unable to revise earlier text."
    case .nemotron:
      "A larger streaming model for continuous speech whose transcript is append-only and has no guide words."
    case .qwen:
      "A local model with prompt-based guide words that reprocesses the growing recording as you speak."
    }
  }

  public var isRecommended: Bool {
    switch self {
    case .parakeet, .moonshineSmall, .moonshineMedium, .whisper: true
    case .appleSpeech, .appleDictation, .parakeetEou, .nemotron, .qwen: false
    }
  }

  public var supportsRevisions: Bool {
    switch self {
    case .parakeet, .moonshineSmall, .moonshineMedium, .whisper, .appleSpeech,
      .appleDictation, .qwen:
      true
    case .parakeetEou, .nemotron: false
    }
  }

  public var supportsGuidance: Bool {
    switch self {
    case .parakeet, .moonshineSmall, .moonshineMedium, .whisper, .appleSpeech,
      .appleDictation, .qwen:
      true
    case .parakeetEou, .nemotron: false
    }
  }

  public var supportsGuideWordStrength: Bool {
    switch self {
    case .parakeet, .moonshineSmall, .moonshineMedium, .whisper, .qwen:
      true
    case .appleSpeech, .appleDictation, .parakeetEou, .nemotron:
      false
    }
  }

  public var revisionStrategy: String {
    switch self {
    case .parakeet: "growing-prefix re-decode"
    case .moonshineSmall, .moonshineMedium: "native mutable stream"
    case .whisper, .qwen: "growing-prefix re-decode"
    case .appleSpeech, .appleDictation: "native volatile results"
    case .parakeetEou, .nemotron: "append-only stream"
    }
  }

  public var guidanceMechanism: String {
    switch self {
    case .parakeet: "CTC acoustic vocabulary rescoring"
    case .moonshineSmall, .moonshineMedium: "decoder keyterms"
    case .whisper: "decoder prompt tokens"
    case .appleSpeech, .appleDictation: "AnalysisContext contextual strings"
    case .qwen: "model system prompt"
    case .parakeetEou, .nemotron: "none"
    }
  }

  public var requirements: String {
    switch self {
    case .appleSpeech, .appleDictation: "macOS 26+; Apple-managed model asset"
    case .qwen: "uv; Python 3.13; mlx-audio runtime"
    default: "Apple Silicon"
    }
  }

  public static var recommendedCases: [BenchmarkModel] {
    allCases.filter(\.isRecommended)
  }

  public static func parse(_ value: String) throws -> BenchmarkModel {
    if let match = allCases.first(where: { $0.rawValue == value || $0.shortName == value }) {
      return match
    }
    throw BenchmarkError.invalidModel(value)
  }
}

public enum GuidanceMode: String, Codable, CaseIterable, Sendable {
  case off
  case on
}

public enum GuideWordStrength: String, Codable, CaseIterable, Identifiable, Sendable {
  case normal
  case conservative

  public var id: String { rawValue }

  public var displayName: String {
    switch self {
    case .normal: "Normal"
    case .conservative: "Conservative"
    }
  }
}

public struct BenchmarkManifest: Codable, Sendable {
  public let guideWords: [String]
  public let cases: [BenchmarkCase]

  public init(guideWords: [String], cases: [BenchmarkCase]) {
    self.guideWords = guideWords
    self.cases = cases
  }
}

public struct BenchmarkCase: Codable, Sendable {
  public let id: String
  public let audio: String
  public let reference: String

  public init(id: String, audio: String, reference: String) {
    self.id = id
    self.audio = audio
    self.reference = reference
  }
}

public struct HypothesisEvent: Codable, Equatable, Sendable {
  public let elapsedMilliseconds: Double
  public let audioMilliseconds: Double
  public let text: String
  public let isFinal: Bool

  public init(
    elapsedMilliseconds: Double,
    audioMilliseconds: Double,
    text: String,
    isFinal: Bool
  ) {
    self.elapsedMilliseconds = elapsedMilliseconds
    self.audioMilliseconds = audioMilliseconds
    self.text = text
    self.isFinal = isFinal
  }
}

public struct EngineRun: Codable, Sendable {
  public let model: BenchmarkModel
  public let guidance: GuidanceMode
  public let caseID: String
  public let reference: String
  public let guideWords: [String]
  public let guidanceMechanism: String
  public let audioDurationSeconds: Double
  public let speechStartSeconds: Double
  public let modelLoadMilliseconds: Double
  public let inferenceMilliseconds: Double
  public let peakResidentMegabytes: Double?
  public let events: [HypothesisEvent]

  public init(
    model: BenchmarkModel,
    guidance: GuidanceMode,
    caseID: String,
    reference: String,
    guideWords: [String],
    guidanceMechanism: String,
    audioDurationSeconds: Double,
    speechStartSeconds: Double,
    modelLoadMilliseconds: Double,
    inferenceMilliseconds: Double,
    peakResidentMegabytes: Double?,
    events: [HypothesisEvent]
  ) {
    self.model = model
    self.guidance = guidance
    self.caseID = caseID
    self.reference = reference
    self.guideWords = guideWords
    self.guidanceMechanism = guidanceMechanism
    self.audioDurationSeconds = audioDurationSeconds
    self.speechStartSeconds = speechStartSeconds
    self.modelLoadMilliseconds = modelLoadMilliseconds
    self.inferenceMilliseconds = inferenceMilliseconds
    self.peakResidentMegabytes = peakResidentMegabytes
    self.events = events
  }
}

public struct BenchmarkMetrics: Codable, Equatable, Sendable {
  public let finalText: String
  public let wordErrorRate: Double
  public let guideWordRecall: Double?
  public let guideWordHits: Int
  public let guideWordExpected: Int
  public let guideWordFalsePositives: Int
  public let firstTextLatencyMilliseconds: Double?
  public let finalizationLatencyMilliseconds: Double
  public let partialUpdates: Int
  public let revisions: Int
  public let revisedCharacters: Int
  public let computeRealTimeFactor: Double
}

public struct ScoredRun: Codable, Sendable {
  public let run: EngineRun
  public let metrics: BenchmarkMetrics

  public init(run: EngineRun, metrics: BenchmarkMetrics) {
    self.run = run
    self.metrics = metrics
  }
}

public struct BenchmarkReport: Codable, Sendable {
  public let generatedAt: Date
  public let host: String
  public let cadenceMilliseconds: Double
  public let realtimePacing: Bool
  public let runs: [ScoredRun]
  public let failures: [BenchmarkFailure]

  public init(
    generatedAt: Date,
    host: String,
    cadenceMilliseconds: Double,
    realtimePacing: Bool,
    runs: [ScoredRun],
    failures: [BenchmarkFailure]
  ) {
    self.generatedAt = generatedAt
    self.host = host
    self.cadenceMilliseconds = cadenceMilliseconds
    self.realtimePacing = realtimePacing
    self.runs = runs
    self.failures = failures
  }
}

public struct BenchmarkFailure: Codable, Sendable {
  public let model: BenchmarkModel
  public let guidance: GuidanceMode?
  public let caseID: String?
  public let stage: String
  public let message: String

  public init(
    model: BenchmarkModel,
    guidance: GuidanceMode? = nil,
    caseID: String? = nil,
    stage: String,
    message: String
  ) {
    self.model = model
    self.guidance = guidance
    self.caseID = caseID
    self.stage = stage
    self.message = message
  }
}

public enum BenchmarkError: LocalizedError {
  case invalidModel(String)
  case invalidManifest(String)
  case noEvents

  public var errorDescription: String? {
    switch self {
    case .invalidModel(let value):
      "Unknown model '\(value)'. Use all or one of: \(BenchmarkModel.allCases.map(\.shortName).joined(separator: ", "))."
    case .invalidManifest(let message): message
    case .noEvents: "The engine produced no transcript events."
    }
  }
}
