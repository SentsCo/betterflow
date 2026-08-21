import BetterflowBenchmarkCore
import Combine
import Foundation
import Security

enum TranscriptionMode: String, CaseIterable, Identifiable {
  case automatic
  case localOnly
  case cloudOnly

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .automatic: "Automatic"
    case .localOnly: "Local"
    case .cloudOnly: "Cloud"
    }
  }

  var detail: String {
    switch self {
    case .automatic: "Use cloud when available, with automatic local fallback."
    case .localOnly: "Keep audio and transcription entirely on this Mac."
    case .cloudOnly: "Require the selected network service."
    }
  }
}

enum CloudTranscriptionProvider: String, CaseIterable, Identifiable, Sendable {
  case deepgram
  case elevenLabs
  case openAI

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .deepgram: "Deepgram Nova-3"
    case .elevenLabs: "ElevenLabs Scribe v2"
    case .openAI: "OpenAI GPT Live Transcribe"
    }
  }

  var summary: String {
    switch self {
    case .deepgram:
      "Fast revisable streaming with native keyterm prompting."
    case .elevenLabs:
      "Low-latency revisable streaming with contextual keyterms."
    case .openAI:
      "High-accuracy streaming with free-form vocabulary guidance."
    }
  }

  var keyURL: URL {
    switch self {
    case .deepgram: URL(string: "https://console.deepgram.com/project/keys")!
    case .elevenLabs: URL(string: "https://elevenlabs.io/app/developers/api-keys")!
    case .openAI: URL(string: "https://platform.openai.com/api-keys")!
    }
  }

  var billingURL: URL {
    switch self {
    case .deepgram: URL(string: "https://console.deepgram.com/billing")!
    case .elevenLabs: URL(string: "https://elevenlabs.io/app/subscription")!
    case .openAI: URL(string: "https://platform.openai.com/settings/organization/billing/overview")!
    }
  }
}

enum CloudCredentialValidation: Equatable {
  case idle
  case testing
  case valid
  case invalid(String)

  var label: String? {
    switch self {
    case .idle: nil
    case .testing: "Checking…"
    case .valid: "Key verified"
    case .invalid(let message): message
    }
  }
}

@MainActor
final class CloudCredentials: ObservableObject {
  @Published private(set) var configuredProviders: Set<CloudTranscriptionProvider> = []
  @Published private(set) var validation: [CloudTranscriptionProvider: CloudCredentialValidation]

  private var keys: [CloudTranscriptionProvider: String] = [:]

  init() {
    validation = Dictionary(
      uniqueKeysWithValues: CloudTranscriptionProvider.allCases.map { ($0, .idle) }
    )
    for provider in CloudTranscriptionProvider.allCases {
      if let key = try? CloudKeychain.load(provider: provider), !key.isEmpty {
        keys[provider] = key
        configuredProviders.insert(provider)
      }
    }
  }

  func key(for provider: CloudTranscriptionProvider) -> String? {
    keys[provider]
  }

  func save(_ key: String, for provider: CloudTranscriptionProvider) throws {
    let cleanKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleanKey.isEmpty else { throw CloudCredentialError.emptyKey }
    try CloudKeychain.save(cleanKey, provider: provider)
    keys[provider] = cleanKey
    configuredProviders.insert(provider)
    validation[provider] = .idle
  }

  func remove(_ provider: CloudTranscriptionProvider) throws {
    try CloudKeychain.remove(provider: provider)
    keys.removeValue(forKey: provider)
    configuredProviders.remove(provider)
    validation[provider] = .idle
  }

  func test(_ provider: CloudTranscriptionProvider) {
    guard let key = keys[provider] else {
      validation[provider] = .invalid("Save an API key first.")
      return
    }
    validation[provider] = .testing
    Task {
      do {
        try await CloudCredentialValidator.validate(key: key, provider: provider)
        validation[provider] = .valid
      } catch {
        validation[provider] = .invalid(error.localizedDescription)
      }
    }
  }
}

private enum CloudKeychain {
  static let service = "com.zachsents.betterflow.cloud-api-keys"

  static func load(provider: CloudTranscriptionProvider) throws -> String? {
    var query = baseQuery(provider: provider)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess else { throw CloudCredentialError.keychain(status) }
    guard let data = result as? Data, let key = String(data: data, encoding: .utf8) else {
      throw CloudCredentialError.invalidStoredKey
    }
    return key
  }

  static func save(_ key: String, provider: CloudTranscriptionProvider) throws {
    let data = Data(key.utf8)
    let query = baseQuery(provider: provider)
    let updateStatus = SecItemUpdate(
      query as CFDictionary,
      [kSecValueData as String: data] as CFDictionary
    )
    if updateStatus == errSecSuccess { return }
    guard updateStatus == errSecItemNotFound else {
      throw CloudCredentialError.keychain(updateStatus)
    }
    var item = query
    item[kSecValueData as String] = data
    item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    let addStatus = SecItemAdd(item as CFDictionary, nil)
    guard addStatus == errSecSuccess else { throw CloudCredentialError.keychain(addStatus) }
  }

  static func remove(provider: CloudTranscriptionProvider) throws {
    let status = SecItemDelete(baseQuery(provider: provider) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw CloudCredentialError.keychain(status)
    }
  }

  private static func baseQuery(provider: CloudTranscriptionProvider) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: provider.rawValue,
    ]
  }
}

private enum CloudCredentialValidator {
  static func validate(key: String, provider: CloudTranscriptionProvider) async throws {
    var request: URLRequest
    switch provider {
    case .deepgram:
      request = URLRequest(url: URL(string: "https://api.deepgram.com/v1/projects")!)
      request.setValue("Token \(key)", forHTTPHeaderField: "Authorization")
    case .elevenLabs:
      request = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/user")!)
      request.setValue(key, forHTTPHeaderField: "xi-api-key")
    case .openAI:
      request = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
      request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    }
    request.timeoutInterval = 15
    let (_, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw CloudCredentialError.invalidResponse
    }
    guard (200..<300).contains(http.statusCode) else {
      if http.statusCode == 401 || http.statusCode == 403 {
        throw CloudCredentialError.rejectedKey
      }
      throw CloudCredentialError.httpStatus(http.statusCode)
    }
  }
}

enum CloudCredentialError: LocalizedError {
  case emptyKey
  case invalidStoredKey
  case keychain(OSStatus)
  case invalidResponse
  case rejectedKey
  case httpStatus(Int)

  var errorDescription: String? {
    switch self {
    case .emptyKey: "Enter an API key."
    case .invalidStoredKey: "The saved API key could not be read."
    case .keychain(let status): "Keychain returned error \(status)."
    case .invalidResponse: "The provider returned an invalid response."
    case .rejectedKey: "The provider rejected this API key."
    case .httpStatus(let status): "The provider returned HTTP \(status)."
    }
  }
}

enum CloudTranscriptionError: LocalizedError, Sendable {
  case invalidURL
  case unavailable(String)
  case timedOut
  case noTranscript

  var errorDescription: String? {
    switch self {
    case .invalidURL: "The cloud transcription URL is invalid."
    case .unavailable(let message): message
    case .timedOut: "The cloud transcription service took too long to finish."
    case .noTranscript: "The cloud transcription service returned no speech."
    }
  }
}

actor CloudTranscriptionSession {
  nonisolated let updates: AsyncThrowingStream<String, Error>

  let provider: CloudTranscriptionProvider

  private let urlSession: URLSession
  private let socket: URLSessionWebSocketTask
  private let updateContinuation: AsyncThrowingStream<String, Error>.Continuation
  private var receiveTask: Task<Void, Never>?
  private var finishTimeoutTask: Task<Void, Never>?
  private var finishContinuation: CheckedContinuation<String, Error>?
  private var bufferedFinishResult: Result<String, Error>?
  private var terminalMessage: String?
  private var providerResampler: StreamingAudioResampler?
  private var sentSampleCount = 0
  private var committedSegments: [String] = []
  private var partialTranscript = ""
  private var openAIItemOrder: [String] = []
  private var openAIItemText: [String: String] = [:]
  private var openAIFinalItemID: String?
  private var finishing = false
  private var closed = false

  static func connect(
    provider: CloudTranscriptionProvider,
    apiKey: String,
    guideWords: [String],
    guideWordStrength: GuideWordStrength
  ) async throws -> CloudTranscriptionSession {
    let request = try makeRequest(
      provider: provider,
      apiKey: apiKey,
      guideWords: guideWords,
      guideWordStrength: guideWordStrength
    )
    let session = URLSession(configuration: .ephemeral)
    let socket = session.webSocketTask(with: request)
    let (updates, continuation) = AsyncThrowingStream<String, Error>.makeStream(
      bufferingPolicy: .bufferingNewest(1)
    )
    let cloudSession = CloudTranscriptionSession(
      provider: provider,
      urlSession: session,
      socket: socket,
      updates: updates,
      updateContinuation: continuation
    )
    try await cloudSession.start(
      guideWords: guideWords,
      guideWordStrength: guideWordStrength
    )
    return cloudSession
  }

  private init(
    provider: CloudTranscriptionProvider,
    urlSession: URLSession,
    socket: URLSessionWebSocketTask,
    updates: AsyncThrowingStream<String, Error>,
    updateContinuation: AsyncThrowingStream<String, Error>.Continuation
  ) {
    self.provider = provider
    self.urlSession = urlSession
    self.socket = socket
    self.updates = updates
    self.updateContinuation = updateContinuation
    if provider != .openAI {
      providerResampler = StreamingAudioResampler(
        sourceRate: MicrophoneCapture.sampleRate,
        destinationRate: 16_000
      )
    }
  }

  func append(samples: [Float]) async throws {
    guard !samples.isEmpty else { return }
    try checkAvailable()
    try await sendAudio(samples, commit: false)
    sentSampleCount += samples.count
  }

  func finish(completeAudio: [Float]) async throws -> String {
    try checkAvailable()
    guard !finishing else {
      throw CloudTranscriptionError.unavailable("Cloud transcription is already finishing.")
    }
    finishing = true
    let remaining = sentSampleCount < completeAudio.count
      ? Array(completeAudio[sentSampleCount...]) : []
    switch provider {
    case .deepgram:
      try await sendAudio(remaining, commit: true)
      sentSampleCount = completeAudio.count
      try await sendJSON(["type": "CloseStream"])
    case .elevenLabs:
      try await sendAudio(remaining, commit: true)
      sentSampleCount = completeAudio.count
    case .openAI:
      try await sendAudio(remaining, commit: true)
      sentSampleCount = completeAudio.count
      try await sendJSON(["type": "input_audio_buffer.commit"])
    }

    if let bufferedFinishResult {
      self.bufferedFinishResult = nil
      return try bufferedFinishResult.get()
    }
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        finishContinuation = continuation
        finishTimeoutTask = Task { [weak self] in
          try? await Task.sleep(for: .seconds(12))
          await self?.finishTimedOut()
        }
      }
    } onCancel: {
      Task { await self.cancel() }
    }
  }

  func cancel() {
    guard !closed else { return }
    closed = true
    receiveTask?.cancel()
    receiveTask = nil
    finishTimeoutTask?.cancel()
    finishTimeoutTask = nil
    socket.cancel(with: .goingAway, reason: nil)
    urlSession.invalidateAndCancel()
    updateContinuation.finish()
    finishContinuation?.resume(throwing: CancellationError())
    finishContinuation = nil
  }

  private func start(
    guideWords: [String],
    guideWordStrength: GuideWordStrength
  ) async throws {
    socket.resume()
    receiveTask = Task { [weak self] in
      await self?.receiveLoop()
    }
    if provider == .openAI {
      let vocabulary = guideWords.joined(separator: ", ")
      let prompt: String
      if vocabulary.isEmpty {
        prompt = "Transcribe natural English dictation accurately."
      } else if guideWordStrength == .conservative {
        prompt =
          "Transcribe natural English dictation accurately. Use these spellings only when clearly spoken: \(vocabulary)."
      } else {
        prompt =
          "Transcribe natural English dictation accurately. Expected vocabulary: \(vocabulary)."
      }
      var transcription: [String: Any] = [
        "model": "gpt-live-transcribe",
        "prompt": prompt,
        "languages": ["en"],
        "delay": "minimal",
      ]
      if guideWordStrength == .normal, !guideWords.isEmpty {
        transcription["keywords"] = guideWords
      }
      try await sendJSON([
        "type": "session.update",
        "session": [
          "type": "transcription",
          "audio": [
            "input": [
              "format": [
                "type": "audio/pcm",
                "rate": 24_000,
              ],
              "transcription": transcription,
              "turn_detection": NSNull(),
              "noise_reduction": ["type": "near_field"],
            ] as [String: Any]
          ],
        ] as [String: Any],
      ])
    }
  }

  private func receiveLoop() async {
    do {
      while !Task.isCancelled, !closed {
        let message = try await socket.receive()
        let data: Data
        switch message {
        case .string(let string): data = Data(string.utf8)
        case .data(let value): data = value
        @unknown default: continue
        }
        try handle(data)
      }
    } catch is CancellationError {
      return
    } catch {
      if finishing, socket.closeCode == .normalClosure, !currentTranscript.isEmpty {
        resolveFinish(.success(currentTranscript))
      } else if !closed {
        terminate(with: error)
      }
    }
  }

  private func handle(_ data: Data) throws {
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      return
    }
    switch provider {
    case .deepgram: try handleDeepgram(object)
    case .elevenLabs: try handleElevenLabs(object)
    case .openAI: try handleOpenAI(object)
    }
  }

  private func handleDeepgram(_ object: [String: Any]) throws {
    let type = object["type"] as? String
    if type == "Error" {
      throw CloudTranscriptionError.unavailable(
        (object["description"] as? String) ?? (object["message"] as? String)
          ?? "Deepgram transcription failed."
      )
    }
    if type == "Metadata", finishing {
      resolveCurrentTranscript()
      return
    }
    guard type == "Results",
      let channel = object["channel"] as? [String: Any],
      let alternatives = channel["alternatives"] as? [[String: Any]],
      let text = alternatives.first?["transcript"] as? String
    else { return }
    let clean = clean(text)
    if object["is_final"] as? Bool == true {
      appendCommitted(clean)
      partialTranscript = ""
    } else {
      partialTranscript = clean
    }
    publishCurrentTranscript()
  }

  private func handleElevenLabs(_ object: [String: Any]) throws {
    guard let type = object["message_type"] as? String else { return }
    if type == "error" || type.hasSuffix("_error") || type == "rate_limited" {
      throw CloudTranscriptionError.unavailable(
        (object["error"] as? String) ?? "ElevenLabs transcription failed."
      )
    }
    let text = clean(object["text"] as? String ?? "")
    switch type {
    case "partial_transcript", "final_transcript":
      partialTranscript = text
      publishCurrentTranscript()
    case "committed_transcript":
      appendCommitted(text)
      partialTranscript = ""
      publishCurrentTranscript()
      if finishing { resolveCurrentTranscript() }
    default:
      break
    }
  }

  private func handleOpenAI(_ object: [String: Any]) throws {
    guard let type = object["type"] as? String else { return }
    if type == "error" {
      let error = object["error"] as? [String: Any]
      let message = (error?["message"] as? String) ?? "OpenAI transcription failed."
      if finishing, !currentTranscript.isEmpty,
        message.localizedCaseInsensitiveContains("buffer")
      {
        resolveCurrentTranscript()
        return
      }
      throw CloudTranscriptionError.unavailable(message)
    }
    if type == "input_audio_buffer.committed" {
      openAIFinalItemID = object["item_id"] as? String
      return
    }
    guard type == "conversation.item.input_audio_transcription.delta"
      || type == "conversation.item.input_audio_transcription.completed"
    else { return }
    guard let itemID = object["item_id"] as? String else { return }
    if !openAIItemOrder.contains(itemID) { openAIItemOrder.append(itemID) }
    if type.hasSuffix(".delta") {
      openAIItemText[itemID, default: ""] += object["delta"] as? String ?? ""
    } else {
      openAIItemText[itemID] = object["transcript"] as? String ?? openAIItemText[itemID] ?? ""
    }
    publishCurrentTranscript()
    if finishing, type.hasSuffix(".completed"),
      openAIFinalItemID == nil || openAIFinalItemID == itemID
    {
      resolveCurrentTranscript()
    }
  }

  private var currentTranscript: String {
    if provider == .openAI {
      return clean(openAIItemOrder.compactMap { openAIItemText[$0] }.joined(separator: " "))
    }
    return clean((committedSegments + [partialTranscript]).joined(separator: " "))
  }

  private func publishCurrentTranscript() {
    let transcript = currentTranscript
    guard !transcript.isEmpty else { return }
    updateContinuation.yield(transcript)
  }

  private func appendCommitted(_ text: String) {
    guard !text.isEmpty, committedSegments.last != text else { return }
    committedSegments.append(text)
  }

  private func resolveCurrentTranscript() {
    let transcript = currentTranscript
    resolveFinish(
      transcript.isEmpty
        ? .failure(CloudTranscriptionError.noTranscript) : .success(transcript)
    )
  }

  private func resolveFinish(_ result: Result<String, Error>) {
    finishTimeoutTask?.cancel()
    finishTimeoutTask = nil
    if let finishContinuation {
      self.finishContinuation = nil
      finishContinuation.resume(with: result)
    } else {
      bufferedFinishResult = result
    }
  }

  private func finishTimedOut() {
    guard finishing else { return }
    resolveFinish(.failure(CloudTranscriptionError.timedOut))
  }

  private func terminate(with error: Error) {
    guard !closed else { return }
    terminalMessage = error.localizedDescription
    updateContinuation.finish(throwing: error)
    resolveFinish(.failure(error))
  }

  private func checkAvailable() throws {
    if let terminalMessage {
      throw CloudTranscriptionError.unavailable(terminalMessage)
    }
    if closed {
      throw CloudTranscriptionError.unavailable("The cloud transcription session closed.")
    }
  }

  private func sendAudio(_ samples: [Float], commit: Bool) async throws {
    switch provider {
    case .deepgram:
      let data = pcm16Data(providerResampler?.process(samples, final: commit) ?? samples)
      guard !data.isEmpty else { return }
      try await socket.send(.data(data))
    case .elevenLabs:
      let data = pcm16Data(providerResampler?.process(samples, final: commit) ?? samples)
      try await sendJSON([
        "message_type": "input_audio_chunk",
        "audio_base_64": data.base64EncodedString(),
        "commit": commit,
      ])
    case .openAI:
      let data = pcm16Data(samples)
      guard !data.isEmpty else { return }
      try await sendJSON([
        "type": "input_audio_buffer.append",
        "audio": data.base64EncodedString(),
      ])
    }
  }

  private func sendJSON(_ object: [String: Any]) async throws {
    let data = try JSONSerialization.data(withJSONObject: object)
    guard let string = String(data: data, encoding: .utf8) else {
      throw CloudTranscriptionError.unavailable("Could not encode a provider request.")
    }
    try await socket.send(.string(string))
  }

  private static func makeRequest(
    provider: CloudTranscriptionProvider,
    apiKey: String,
    guideWords: [String],
    guideWordStrength: GuideWordStrength
  ) throws -> URLRequest {
    let keyterms = guideWordStrength == .normal ? guideWords : []
    var components: URLComponents
    switch provider {
    case .deepgram:
      components = URLComponents(string: "wss://api.deepgram.com/v1/listen")!
      components.queryItems = [
        URLQueryItem(name: "model", value: "nova-3"),
        URLQueryItem(name: "language", value: "en-US"),
        URLQueryItem(name: "encoding", value: "linear16"),
        URLQueryItem(name: "sample_rate", value: "16000"),
        URLQueryItem(name: "channels", value: "1"),
        URLQueryItem(name: "interim_results", value: "true"),
        URLQueryItem(name: "smart_format", value: "true"),
        URLQueryItem(name: "punctuate", value: "true"),
      ] + keyterms.prefix(100).map { URLQueryItem(name: "keyterm", value: $0) }
    case .elevenLabs:
      components = URLComponents(
        string: "wss://api.elevenlabs.io/v1/speech-to-text/realtime"
      )!
      components.queryItems = [
        URLQueryItem(name: "model_id", value: "scribe_v2_realtime"),
        URLQueryItem(name: "audio_format", value: "pcm_16000"),
        URLQueryItem(name: "language_code", value: "en"),
        URLQueryItem(name: "commit_strategy", value: "manual"),
      ] + keyterms.prefix(50).filter { $0.count <= 20 }
        .map { URLQueryItem(name: "keyterms", value: $0) }
    case .openAI:
      components = URLComponents(string: "wss://api.openai.com/v1/realtime")!
      components.queryItems = [URLQueryItem(name: "intent", value: "transcription")]
    }
    guard let url = components.url else { throw CloudTranscriptionError.invalidURL }
    var request = URLRequest(url: url)
    request.timeoutInterval = 15
    switch provider {
    case .deepgram:
      request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")
    case .elevenLabs:
      request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
    case .openAI:
      request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    }
    return request
  }

  private func pcm16Data(_ samples: [Float]) -> Data {
    var data = Data(count: samples.count * MemoryLayout<Int16>.size)
    data.withUnsafeMutableBytes { bytes in
      let values = bytes.bindMemory(to: Int16.self)
      for (index, sample) in samples.enumerated() {
        let scaled = Int((max(-1, min(1, sample)) * Float(Int16.max)).rounded())
        values[index] = Int16(clamping: scaled).littleEndian
      }
    }
    return data
  }

  private func clean(_ text: String) -> String {
    text.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

struct StreamingAudioResampler {
  private let sourceStep: Double
  private var buffer: [Float] = []
  private var sourcePosition = 0.0

  init(sourceRate: Double, destinationRate: Double) {
    precondition(sourceRate > 0 && destinationRate > 0)
    sourceStep = sourceRate / destinationRate
  }

  mutating func process(_ samples: [Float], final: Bool) -> [Float] {
    buffer.append(contentsOf: samples)
    guard !buffer.isEmpty else { return [] }

    var output: [Float] = []
    output.reserveCapacity(Int((Double(samples.count) / sourceStep).rounded(.up)))
    while sourcePosition < Double(buffer.count) {
      let lowerIndex = Int(sourcePosition)
      let fraction = Float(sourcePosition - Double(lowerIndex))
      if lowerIndex + 1 >= buffer.count, fraction > 0.000_001, !final { break }
      let upperIndex = min(lowerIndex + 1, buffer.count - 1)
      output.append(
        buffer[lowerIndex] + (buffer[upperIndex] - buffer[lowerIndex]) * fraction
      )
      sourcePosition += sourceStep
    }

    if final {
      buffer.removeAll(keepingCapacity: true)
      sourcePosition = 0
      return output
    }

    let discardedCount = min(max(Int(sourcePosition) - 1, 0), buffer.count)
    if discardedCount > 0 {
      buffer.removeFirst(discardedCount)
      sourcePosition -= Double(discardedCount)
    }
    return output
  }
}
