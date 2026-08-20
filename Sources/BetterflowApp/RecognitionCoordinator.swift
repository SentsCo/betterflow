import BetterflowBenchmarkCore
import BetterflowEngine
import Combine
import Foundation

struct LiveInferenceGate {
  static let minimumAudioSeconds = 0.25
  static let inferenceHeadroom = 1.1

  private let sampleRate: Double
  private(set) var lastProcessedSampleCount = 0
  private(set) var requiredNewSampleCount: Int

  init(sampleRate: Double) {
    self.sampleRate = sampleRate
    requiredNewSampleCount = Int(
      (sampleRate * Self.minimumAudioSeconds).rounded(.up)
    )
  }

  func shouldRun(at totalSampleCount: Int) -> Bool {
    totalSampleCount - lastProcessedSampleCount >= requiredNewSampleCount
  }

  mutating func didFinishInference(
    processedSampleCount: Int,
    durationSeconds: Double
  ) {
    lastProcessedSampleCount = processedSampleCount
    let requiredAudioSeconds = max(
      Self.minimumAudioSeconds,
      durationSeconds * Self.inferenceHeadroom
    )
    requiredNewSampleCount = Int((sampleRate * requiredAudioSeconds).rounded(.up))
  }
}

enum DictationState: Equatable {
  case idle
  case preparing
  case listening
  case finalizing
  case error(String)

  var label: String {
    switch self {
    case .idle: "Ready"
    case .preparing: "Preparing model…"
    case .listening: "Listening"
    case .finalizing: "Finishing…"
    case .error(let message): message
    }
  }
}

private actor RecognitionRuntime {
  private var adapter: (any ModelAdapter)?
  private var liveSession: (any LiveTranscriptionSession)?
  private var liveSampleCount = 0
  private var loadedModel: BenchmarkModel?
  private var loadedGuideWords: [String] = []

  func prepare(model: BenchmarkModel, guideWords: [String]) async throws {
    guard loadedModel != model || loadedGuideWords != guideWords || adapter == nil else { return }
    await liveSession?.close()
    liveSession = nil
    liveSampleCount = 0
    await adapter?.close()
    adapter = nil
    loadedModel = nil
    let newAdapter = AdapterFactory.make(model)
    do {
      try await newAdapter.prepare(guideWords: guideWords)
      adapter = newAdapter
      loadedModel = model
      loadedGuideWords = guideWords
    } catch {
      await newAdapter.close()
      throw error
    }
  }

  func startLive(model: BenchmarkModel, guideWords: [String]) async throws {
    try await prepare(model: model, guideWords: guideWords)
    await liveSession?.close()
    liveSession = try await adapter?.makeLiveSession(
      guidance: model.supportsGuidance ? .on : .off)
    liveSampleCount = 0
  }

  func updateLive(samples: [Float], final: Bool) async throws -> HypothesisEvent? {
    guard let liveSession else { return nil }
    guard samples.count >= liveSampleCount else {
      throw RecognitionError.invalidAudioStream
    }
    let newSamples = Array(samples[liveSampleCount...])
    liveSampleCount = samples.count
    let event = try await liveSession.append(
      audio: AudioData(samples: newSamples, sampleRate: MicrophoneCapture.sampleRate),
      final: final
    )
    if final {
      await liveSession.close()
      self.liveSession = nil
      liveSampleCount = 0
    }
    return event
  }

  func transcribe(
    samples: [Float],
    model: BenchmarkModel,
    guideWords: [String],
    onHypothesis: @escaping @Sendable (HypothesisEvent) -> Void
  ) async throws -> String {
    try await prepare(model: model, guideWords: guideWords)
    guard let adapter else { throw RecognitionError.modelUnavailable }
    let audio = AudioData(
      samples: samples,
      sampleRate: MicrophoneCapture.sampleRate
    )
    let cadence = max(100, audio.durationSeconds * 1_000 + 100)
    let output = try await adapter.transcribe(
      audio: audio,
      guidance: model.supportsGuidance ? .on : .off,
      cadenceMilliseconds: cadence,
      realtime: false,
      onHypothesis: onHypothesis
    )
    guard let final = output.events.last?.text, !final.isEmpty else {
      throw RecognitionError.noSpeech
    }
    return final
  }

  func close(model: BenchmarkModel? = nil) async {
    guard model == nil || loadedModel == model else { return }
    await liveSession?.close()
    liveSession = nil
    liveSampleCount = 0
    await adapter?.close()
    adapter = nil
    loadedModel = nil
    loadedGuideWords = []
  }

  func cancelLive() async {
    await liveSession?.close()
    liveSession = nil
    liveSampleCount = 0
  }
}

@MainActor
final class RecognitionCoordinator: ObservableObject {
  @Published private(set) var state: DictationState = .idle
  @Published private(set) var transcript = ""
  @Published private(set) var selectedMicrophone = "System Default"
  @Published private(set) var cleanupEnabled = false

  let audioMeter = AudioMeterState()

  var onOverlayVisibility: ((Bool) -> Void)?
  var onKeyboardModeChange: ((DictationKeyboardMode) -> Void)?

  private let settings: AppSettings
  private let history: TranscriptionHistory
  private let sounds: AppSoundPlayer
  private let cleanupRuntime: TranscriptCleanupRuntime
  private let capture = MicrophoneCapture()
  private let runtime = RecognitionRuntime()
  private var modelPreparationTask: Task<Void, Never>?
  private var startupTask: Task<Void, Never>?
  private var liveTask: Task<Void, Never>?
  private var audioMeterTask: Task<Void, Never>?
  private var finalizationTask: Task<Void, Never>?
  private var runtimeCancellationTask: Task<Void, Never>?
  private var currentSession = UUID()
  private var insertionTarget: TextInsertionTarget?
  private var cleanupModelForSession = CleanupModel.appleFoundation
  private var returnAfterInsertion = false
  private var dictationActive = false
  private var recording = false

  init(
    settings: AppSettings,
    history: TranscriptionHistory,
    sounds: AppSoundPlayer,
    cleanupRuntime: TranscriptCleanupRuntime
  ) {
    self.settings = settings
    self.history = history
    self.sounds = sounds
    self.cleanupRuntime = cleanupRuntime
  }

  func prepareSelectedModel() {
    guard !recording, !dictationActive, state != .finalizing else { return }
    modelPreparationTask?.cancel()
    state = .preparing
    let model = settings.selectedModel
    let guideWords = settings.cleanGuideWords()
    modelPreparationTask = Task {
      guard await ModelStorage.isDownloaded(model) else {
        if state == .preparing, settings.selectedModel == model { state = .idle }
        return
      }
      guard !Task.isCancelled, settings.selectedModel == model else { return }
      do {
        try await runtime.prepare(model: model, guideWords: guideWords)
        guard !Task.isCancelled else { return }
        if state == .preparing, settings.selectedModel == model {
          state = .idle
          modelPreparationTask = nil
        }
      } catch {
        guard !Task.isCancelled else { return }
        if settings.selectedModel == model {
          state = .error(error.localizedDescription)
          modelPreparationTask = nil
        }
      }
    }
  }

  func unloadModels() {
    guard !recording, !dictationActive, state != .finalizing else { return }
    modelPreparationTask?.cancel()
    modelPreparationTask = nil
    state = .preparing
    Task {
      await runtime.close()
      if state == .preparing { state = .idle }
    }
  }

  func unloadModel(_ model: BenchmarkModel) async throws {
    guard !recording, !dictationActive, state != .finalizing else {
      throw RecognitionError.modelInUse
    }
    if settings.selectedModel == model {
      modelPreparationTask?.cancel()
      modelPreparationTask = nil
    }
    await runtime.close(model: model)
    if settings.selectedModel == model { state = .idle }
  }

  func beginDictation() {
    guard !dictationActive, !recording, state != .finalizing else { return }
    dictationActive = true
    onKeyboardModeChange?(.recording)
    let session = UUID()
    currentSession = session
    insertionTarget = TextInserter.captureTarget()
    cleanupEnabled = settings.cleanupEnabledByDefault
    cleanupModelForSession = settings.cleanupModel
    returnAfterInsertion = false
    transcript = ""
    audioMeter.reset()
    state = .preparing
    sounds.play(.recordingStarted)
    if settings.showOverlay { onOverlayVisibility?(true) }
    startupTask = Task { [weak self] in
      await self?.beginCapture(session: session)
    }
  }

  func finishDictation() {
    dictationActive = false
    guard recording else {
      startupTask?.cancel()
      startupTask = nil
      if state == .preparing { state = .idle }
      insertionTarget = nil
      returnAfterInsertion = false
      onOverlayVisibility?(false)
      onKeyboardModeChange?(.none)
      return
    }
    recording = false
    let pendingStartup = startupTask
    startupTask = nil
    let pendingLiveUpdate = liveTask
    liveTask?.cancel()
    liveTask = nil
    audioMeterTask?.cancel()
    audioMeterTask = nil
    let samples = capture.stop()
    audioMeter.reset()
    state = .finalizing
    onKeyboardModeChange?(.finalizing)
    let session = currentSession
    finalizationTask = Task { [weak self] in
      await pendingStartup?.value
      await pendingLiveUpdate?.value
      guard !Task.isCancelled else { return }
      await self?.finalize(samples: samples, session: session)
    }
  }

  func queueReturnAfterInsertion() {
    guard state == .finalizing else { return }
    returnAfterInsertion = true
  }

  func toggleDictation() {
    if recording || dictationActive {
      finishDictation()
    } else {
      beginDictation()
    }
  }

  func toggleCleanup() {
    guard dictationActive || recording || state == .finalizing else { return }
    cleanupEnabled.toggle()
    if cleanupEnabled, cleanupModelForSession == .qwenSmall,
      TranscriptCleanupStorage.isQwenDownloaded
    {
      Task { try? await cleanupRuntime.prepareQwen() }
    }
  }

  func insertCurrentTranscript() {
    guard dictationActive || recording || state == .finalizing else { return }
    let currentTranscript = transcript
    let target = stopImmediately()
    beginBackgroundCleanup()
    transcript = ""
    guard !currentTranscript.isEmpty else { return }

    let delivery = TextDelivery.deliver(currentTranscript, into: target)
    sounds.play(delivery == .inserted ? .textInserted : .insertionFallback)
    history.add(currentTranscript)
  }

  func cancelDictation() {
    guard dictationActive || recording || state == .finalizing else { return }
    _ = stopImmediately()
    beginBackgroundCleanup()
    transcript = ""
  }

  func clearError() {
    if isError {
      onOverlayVisibility?(false)
      state = .idle
    }
  }

  func shutdown() {
    modelPreparationTask?.cancel()
    modelPreparationTask = nil
    let pendingStartup = startupTask
    startupTask?.cancel()
    startupTask = nil
    let pendingLiveUpdate = liveTask
    liveTask?.cancel()
    liveTask = nil
    audioMeterTask?.cancel()
    finalizationTask?.cancel()
    finalizationTask = nil
    capture.stop()
    insertionTarget = nil
    onKeyboardModeChange?(.none)
    Task {
      await pendingStartup?.value
      await pendingLiveUpdate?.value
      await runtime.close()
    }
  }

  private var isError: Bool {
    if case .error = state { return true }
    return false
  }

  private func beginCapture(session: UUID) async {
    await runtimeCancellationTask?.value
    guard dictationActive, currentSession == session else { return }
    let model = settings.selectedModel
    guard await ModelStorage.isDownloaded(model) else {
      fail("Download \(model.displayName) in Settings before using it.", session: session)
      return
    }
    guard await AppPermission.requestMicrophone() else {
      fail("Microphone permission is required.", session: session)
      return
    }
    guard dictationActive, currentSession == session else { return }
    let device = AudioDeviceCatalog.selectedDevice(
      priorityEnabled: settings.microphonePriorityEnabled,
      priority: settings.microphonePriority
    )
    do {
      let audioUpdates = try capture.start(deviceUID: device?.id)
      selectedMicrophone = device?.name ?? "System Default"
      recording = true
      state = .listening
      startAudioMeter(session: session)
      let guideWords = settings.cleanGuideWords()
      try await runtime.startLive(model: model, guideWords: guideWords)
      guard recording, currentSession == session else { return }
      liveTask = Task.detached(priority: .utility) { [weak self] in
        var inferenceGate = LiveInferenceGate(sampleRate: MicrophoneCapture.sampleRate)
        for await sampleCount in audioUpdates {
          guard !Task.isCancelled else { return }
          guard inferenceGate.shouldRun(at: sampleCount) else { continue }
          guard let self else { return }
          let inferenceStarted = ContinuousClock.now
          guard let processedSampleCount = await self.refreshLiveTranscript(session: session)
          else {
            return
          }
          inferenceGate.didFinishInference(
            processedSampleCount: processedSampleCount,
            durationSeconds: inferenceStarted.duration(to: .now).milliseconds / 1_000
          )
        }
      }
    } catch {
      fail(error.localizedDescription, session: session)
    }
  }

  private func refreshLiveTranscript(session: UUID) async -> Int? {
    guard recording, currentSession == session else { return nil }
    let samples = capture.snapshot()
    guard !samples.isEmpty else { return nil }
    let model = settings.selectedModel
    let guideWords = settings.cleanGuideWords()
    do {
      if let event = try await runtime.updateLive(samples: samples, final: false) {
        guard recording, currentSession == session else { return nil }
        transcript = event.text
        return samples.count
      }
      _ = try await runtime.transcribe(
        samples: samples,
        model: model,
        guideWords: guideWords
      ) { [weak self] event in
        Task { @MainActor in
          guard let self, self.recording, self.currentSession == session else { return }
          self.transcript = event.text
        }
      }
    } catch {
      guard recording, currentSession == session else { return nil }
      // Short prefixes legitimately produce no transcript. Final recognition reports real failures.
    }
    return samples.count
  }

  private func finalize(samples: [Float], session: UUID) async {
    guard samples.count >= Int(MicrophoneCapture.sampleRate * 0.15) else {
      finishWithoutText(session: session)
      return
    }
    let model = settings.selectedModel
    let guideWords = settings.cleanGuideWords()
    do {
      let final: String
      if let event = try await runtime.updateLive(samples: samples, final: true) {
        final = event.text
        transcript = event.text
      } else {
        final = try await runtime.transcribe(
          samples: samples,
          model: model,
          guideWords: guideWords
        ) { [weak self] event in
          Task { @MainActor in
            guard let self, self.currentSession == session else { return }
            self.transcript = event.text
          }
        }
      }
      guard !final.isEmpty else { throw RecognitionError.noSpeech }
      guard !Task.isCancelled, currentSession == session else { return }
      let rawTranscript = final
      let shouldCleanup = cleanupEnabled
      let deliveredTranscript: String
      let appliedCleanup: Bool
      if shouldCleanup {
        let outcome = await cleanupRuntime.cleanup(
          rawTranscript,
          using: cleanupModelForSession
        )
        guard !Task.isCancelled, currentSession == session else { return }
        if cleanupEnabled {
          deliveredTranscript = outcome.text
          appliedCleanup = true
        } else {
          deliveredTranscript = rawTranscript
          appliedCleanup = false
        }
      } else {
        deliveredTranscript = rawTranscript
        appliedCleanup = false
      }
      transcript = deliveredTranscript
      history.add(
        deliveredTranscript,
        rawText: appliedCleanup ? rawTranscript : nil
      )
      let target = insertionTarget
      let delivery = TextDelivery.deliver(deliveredTranscript, into: target)
      insertionTarget = nil
      let shouldSendReturn = returnAfterInsertion
      returnAfterInsertion = false
      if delivery == .inserted, shouldSendReturn {
        try? TextInserter.pressReturn(into: target)
      }
      onOverlayVisibility?(false)
      state = .idle
      onKeyboardModeChange?(.none)
      sounds.play(delivery == .inserted ? .textInserted : .insertionFallback)
    } catch RecognitionError.noSpeech {
      guard !Task.isCancelled else { return }
      finishWithoutText(session: session)
    } catch {
      guard !Task.isCancelled else { return }
      fail(error.localizedDescription, session: session)
    }
  }

  private func startAudioMeter(session: UUID) {
    audioMeterTask?.cancel()
    audioMeterTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .milliseconds(16))
        guard !Task.isCancelled, let self, self.recording, self.currentSession == session else {
          return
        }
        let level = self.capture.level()
        let response = level > self.audioMeter.level ? 0.27 : 0.08
        self.audioMeter.update(
          self.audioMeter.level + (level - self.audioMeter.level) * response)
      }
    }
  }

  private func stopImmediately() -> TextInsertionTarget? {
    currentSession = UUID()
    dictationActive = false
    recording = false
    startupTask?.cancel()
    startupTask = nil
    liveTask?.cancel()
    liveTask = nil
    audioMeterTask?.cancel()
    audioMeterTask = nil
    finalizationTask?.cancel()
    finalizationTask = nil
    let target = insertionTarget
    insertionTarget = nil
    returnAfterInsertion = false
    audioMeter.reset()
    state = .idle
    onOverlayVisibility?(false)
    onKeyboardModeChange?(.none)
    return target
  }

  private func beginBackgroundCleanup() {
    let capture = capture
    let runtime = runtime
    let pendingCleanup = runtimeCancellationTask
    runtimeCancellationTask = Task.detached(priority: .utility) {
      await pendingCleanup?.value
      _ = capture.stop()
      await runtime.cancelLive()
    }
  }

  private func fail(_ message: String, session: UUID) {
    guard currentSession == session else { return }
    dictationActive = false
    recording = false
    capture.stop()
    liveTask?.cancel()
    liveTask = nil
    audioMeterTask?.cancel()
    audioMeterTask = nil
    insertionTarget = nil
    returnAfterInsertion = false
    transcript = ""
    audioMeter.reset()
    state = .error(message)
    onOverlayVisibility?(false)
    onKeyboardModeChange?(.none)
  }

  private func finishWithoutText(session: UUID) {
    guard currentSession == session else { return }
    recording = false
    insertionTarget = nil
    returnAfterInsertion = false
    transcript = ""
    audioMeter.reset()
    state = .idle
    onOverlayVisibility?(false)
    onKeyboardModeChange?(.none)
  }
}

@MainActor
final class AudioMeterState: ObservableObject {
  @Published private(set) var level = 0.0

  func update(_ level: Double) {
    self.level = level
  }

  func reset() {
    level = 0
  }
}

enum RecognitionError: LocalizedError {
  case modelUnavailable
  case modelInUse
  case noSpeech
  case invalidAudioStream

  var errorDescription: String? {
    switch self {
    case .modelUnavailable: "The selected speech model is unavailable."
    case .modelInUse: "Stop dictation before deleting this model."
    case .noSpeech: "The model did not detect speech."
    case .invalidAudioStream: "The live audio stream became inconsistent."
    }
  }
}
