import BetterflowBenchmarkCore
import Foundation

final class QwenAdapter: ModelAdapter, @unchecked Sendable {
  let model: BenchmarkModel = .qwen

  private var worker: QwenWorker?
  private var guideWords: [String] = []

  func prepare(guideWords: [String]) async throws {
    self.guideWords = guideWords
    let worker = try QwenWorker()
    try await worker.prepare()
    self.worker = worker
  }

  func transcribe(
    audio: AudioData,
    guidance: GuidanceMode,
    cadenceMilliseconds: Double,
    realtime: Bool,
    onHypothesis: @escaping @Sendable (HypothesisEvent) -> Void
  ) async throws -> AdapterOutput {
    guard let worker else { throw AdapterError.notPrepared(model.rawValue) }
    let started = ContinuousClock.now
    let step = max(1, Int(audio.sampleRate * cadenceMilliseconds / 1_000))
    let audioURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("betterflow-qwen-\(UUID().uuidString).f32")
    defer { try? FileManager.default.removeItem(at: audioURL) }
    var events: [HypothesisEvent] = []
    var inferenceMilliseconds = 0.0
    var end = min(step, audio.samples.count)

    while true {
      let audioMilliseconds = Double(end) / audio.sampleRate * 1_000
      try await pace(audioMilliseconds: audioMilliseconds, started: started, realtime: realtime)
      try write(samples: Array(audio.samples.prefix(end)), to: audioURL)
      let response = try await worker.transcribe(
        audioPath: audioURL.path,
        context: guidance == .on
          ? "Important vocabulary: \(guideWords.joined(separator: ", "))." : nil
      )
      inferenceMilliseconds += response.inferenceMilliseconds
      let isFinal = end == audio.samples.count
      let update = event(
        text: response.text,
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
      guidanceMechanism: guidance == .on ? "Qwen model system prompt" : "disabled"
    )
  }

  func close() async {
    worker?.close()
    worker = nil
  }

  private func write(samples: [Float], to url: URL) throws {
    let data = samples.withUnsafeBufferPointer { buffer in
      Data(bytes: buffer.baseAddress!, count: buffer.count * MemoryLayout<Float>.stride)
    }
    try data.write(to: url, options: .atomic)
  }
}

private final class QwenWorker {
  private static let model = "mlx-community/Qwen3-ASR-0.6B-8bit"
  private static let timeout: Duration = .seconds(120)

  private let process = Process()
  private let input = Pipe()
  private let output = Pipe()
  private let errors = Pipe()
  private let pending = QwenPendingResponses()
  private let lineReader: QwenLineReader
  private let errorBuffer = QwenErrorBuffer()

  init() throws {
    guard let script = QwenResource.workerURL else {
      throw AdapterError.worker("Bundled qwen_worker.py is missing.")
    }
    lineReader = QwenLineReader { [pending] data in
      Task { await pending.resolve(data) }
    }
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [
      "uv", "run", "--python", "3.13", "--with", "mlx-audio==0.4.6", "python",
      script.path, "--model", Self.model,
    ]
    process.standardInput = input
    process.standardOutput = output
    process.standardError = errors
    output.fileHandleForReading.readabilityHandler = { [lineReader] handle in
      lineReader.receive(handle.availableData)
    }
    errors.fileHandleForReading.readabilityHandler = { [errorBuffer] handle in
      errorBuffer.append(handle.availableData)
    }
    process.terminationHandler = { [pending, errorBuffer] process in
      let detail = errorBuffer.text.trimmingCharacters(in: .whitespacesAndNewlines)
      let message =
        detail.isEmpty
        ? "Qwen worker exited with status \(process.terminationStatus)."
        : "Qwen worker exited with status \(process.terminationStatus): \(detail)"
      Task { await pending.failAll(AdapterError.worker(message)) }
    }
    try process.run()
  }

  func prepare() async throws {
    _ = try await request(command: "ping", audioPath: nil, context: nil)
  }

  func transcribe(audioPath: String, context: String?) async throws -> QwenResponse {
    try await request(command: "transcribe", audioPath: audioPath, context: context)
  }

  func close() {
    output.fileHandleForReading.readabilityHandler = nil
    errors.fileHandleForReading.readabilityHandler = nil
    if process.isRunning { process.terminate() }
  }

  private func request(command: String, audioPath: String?, context: String?) async throws
    -> QwenResponse
  {
    let id = UUID().uuidString
    let request = QwenRequest(id: id, command: command, audioPath: audioPath, context: context)
    var data = try JSONEncoder().encode(request)
    data.append(0x0A)
    do {
      try input.fileHandleForWriting.write(contentsOf: data)
      let responseData = try await pending.wait(id: id, timeout: Self.timeout)
      let response = try JSONDecoder().decode(QwenResponse.self, from: responseData)
      if let error = response.error { throw AdapterError.worker(error) }
      return response
    } catch {
      await pending.fail(id: id, error: error)
      throw error
    }
  }
}

private enum QwenResource {
  static var workerURL: URL? {
    if let resources = Bundle.main.resourceURL {
      let packaged =
        resources
        .appendingPathComponent("Betterflow_BetterflowEngine.bundle", isDirectory: true)
        .appendingPathComponent("qwen_worker.py")
      if FileManager.default.fileExists(atPath: packaged.path) { return packaged }
    }
    return Bundle.module.url(forResource: "qwen_worker", withExtension: "py")
  }
}

private struct QwenRequest: Encodable {
  let id: String
  let command: String
  let audioPath: String?
  let context: String?

  enum CodingKeys: String, CodingKey {
    case id, command, context
    case audioPath = "audio_path"
  }
}

private struct QwenResponse: Codable, Sendable {
  let id: String
  let text: String
  let inferenceMilliseconds: Double
  let error: String?

  enum CodingKeys: String, CodingKey {
    case id, text, error
    case inferenceMilliseconds = "inference_ms"
  }
}

private actor QwenPendingResponses {
  private struct Entry {
    let continuation: CheckedContinuation<Data, Error>
    let timeoutTask: Task<Void, Never>
  }

  private var entries: [String: Entry] = [:]
  private var buffered: [String: Data] = [:]
  private var terminalError: Error?

  func wait(id: String, timeout: Duration) async throws -> Data {
    if let data = buffered.removeValue(forKey: id) { return data }
    if let terminalError { throw terminalError }
    return try await withCheckedThrowingContinuation { continuation in
      let timeoutTask = Task { [weak self] in
        try? await Task.sleep(for: timeout)
        await self?.expire(id: id)
      }
      entries[id] = Entry(continuation: continuation, timeoutTask: timeoutTask)
    }
  }

  func resolve(_ data: Data) {
    guard
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let id = object["id"] as? String
    else { return }
    guard let entry = entries.removeValue(forKey: id) else {
      buffered[id] = data
      return
    }
    entry.timeoutTask.cancel()
    entry.continuation.resume(returning: data)
  }

  func fail(id: String, error: Error) {
    guard let entry = entries.removeValue(forKey: id) else { return }
    entry.timeoutTask.cancel()
    entry.continuation.resume(throwing: error)
  }

  func failAll(_ error: Error) {
    terminalError = error
    let current = entries.values
    entries.removeAll()
    for entry in current {
      entry.timeoutTask.cancel()
      entry.continuation.resume(throwing: error)
    }
  }

  private func expire(id: String) {
    fail(
      id: id,
      error: AdapterError.worker(
        "Qwen did not respond within 120 seconds. This runtime is not fast enough for the hotkey path."
      )
    )
  }
}

private final class QwenLineReader: @unchecked Sendable {
  private let lock = NSLock()
  private var buffer = Data()
  private let onLine: @Sendable (Data) -> Void

  init(onLine: @escaping @Sendable (Data) -> Void) {
    self.onLine = onLine
  }

  func receive(_ data: Data) {
    guard !data.isEmpty else { return }
    lock.lock()
    buffer.append(data)
    var lines: [Data] = []
    while let newline = buffer.firstIndex(of: 0x0A) {
      lines.append(buffer[..<newline])
      buffer.removeSubrange(...newline)
    }
    lock.unlock()
    lines.filter { !$0.isEmpty }.forEach(onLine)
  }
}

private final class QwenErrorBuffer: @unchecked Sendable {
  private let lock = NSLock()
  private var data = Data()

  var text: String {
    lock.withLock { String(decoding: data.suffix(8_192), as: UTF8.self) }
  }

  func append(_ newData: Data) {
    guard !newData.isEmpty else { return }
    lock.withLock {
      data.append(newData)
      if data.count > 16_384 { data.removeFirst(data.count - 16_384) }
    }
  }
}
