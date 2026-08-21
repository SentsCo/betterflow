import BetterflowBenchmarkCore
import BetterflowEngine
import Combine
import Foundation
import OSLog

private let recognitionLogger = Logger(
  subsystem: "com.zachsents.betterflow",
  category: "Recognition"
)

struct LiveInferenceGate {
  static let minimumAudioSeconds = 0.3
  static let inferenceHeadroom = 2.0

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
  private var loadedGuideWordStrength = GuideWordStrength.normal

  func prepare(
    model: BenchmarkModel,
    guideWords: [String],
    guideWordStrength: GuideWordStrength
  ) async throws {
    guard
      loadedModel != model || loadedGuideWords != guideWords
        || loadedGuideWordStrength != guideWordStrength || adapter == nil
    else { return }
    await liveSession?.close()
    liveSession = nil
    liveSampleCount = 0
    await adapter?.close()
    adapter = nil
    loadedModel = nil
    let newAdapter = AdapterFactory.make(model)
    do {
      try await newAdapter.prepare(guideWords: guideWords, strength: guideWordStrength)
      adapter = newAdapter
      loadedModel = model
      loadedGuideWords = guideWords
      loadedGuideWordStrength = guideWordStrength
    } catch {
      await newAdapter.close()
      throw error
    }
  }

  func startLive(
    model: BenchmarkModel,
    guideWords: [String],
    guideWordStrength: GuideWordStrength
  ) async throws {
    try await prepare(
      model: model,
      guideWords: guideWords,
      guideWordStrength: guideWordStrength
    )
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
    guideWordStrength: GuideWordStrength,
    onHypothesis: @escaping @Sendable (HypothesisEvent) -> Void
  ) async throws -> String {
    try await prepare(
      model: model,
      guideWords: guideWords,
      guideWordStrength: guideWordStrength
    )
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
    loadedGuideWordStrength = .normal
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
  @Published private(set) var recognitionEngine = ""

  let audioMeter = AudioMeterState()

  var onOverlayVisibility: ((Bool) -> Void)?
  var onKeyboardModeChange: ((DictationKeyboardMode) -> Void)?

  private let settings: AppSettings
  private let history: TranscriptionHistory
  private let sounds: AppSoundPlayer
  private let cleanupRuntime: TranscriptCleanupRuntime
  private let cloudCredentials: CloudCredentials
  private let capture: MicrophoneCapture
  private let captureLifecycle: MicrophoneCaptureLifecycle
  private let runtime = RecognitionRuntime()
  private var modelPreparationTask: Task<Void, Never>?
  private var insertionTargetTask: Task<Void, Never>?
  private var startupTask: Task<Void, Never>?
  private var liveTask: Task<Void, Never>?
  private var cloudUpdatesTask: Task<Void, Never>?
  private var audioMeterTask: Task<Void, Never>?
  private var finalizationTask: Task<Void, Never>?
  private var runtimeCancellationTask: Task<Void, Never>?
  private var currentSession = UUID()
  private var insertionTarget: TextInsertionTarget?
  private var cleanupModelForSession = CleanupModel.appleFoundation
  private var localModelForSession = BenchmarkModel.moonshineSmall
  private var guideWordsForSession: [String] = []
  private var localGuideWordStrengthForSession = GuideWordStrength.normal
  private var transcriptionModeForSession = TranscriptionMode.localOnly
  private var cloudProviderForSession = CloudTranscriptionProvider.deepgram
  private var cloudGuideWordStrengthForSession = GuideWordStrength.normal
  private var cloudSession: CloudTranscriptionSession?
  private var returnAfterInsertion = false
  private var dictationActive = false
  private var recording = false

  init(
    settings: AppSettings,
    history: TranscriptionHistory,
    sounds: AppSoundPlayer,
    cleanupRuntime: TranscriptCleanupRuntime,
    cloudCredentials: CloudCredentials
  ) {
    let capture = MicrophoneCapture()
    self.settings = settings
    self.history = history
    self.sounds = sounds
    self.cleanupRuntime = cleanupRuntime
    self.cloudCredentials = cloudCredentials
    self.capture = capture
    captureLifecycle = MicrophoneCaptureLifecycle(capture: capture)
  }

  func prepareSelectedModel() {
    guard !recording, !dictationActive, state != .finalizing else { return }
    modelPreparationTask?.cancel()
    state = .preparing
    let model = settings.selectedModel
    let guideWords = settings.cleanGuideWords()
    let guideWordStrength = settings.guideWordStrength(for: model)
    modelPreparationTask = Task {
      guard await ModelStorage.isDownloaded(model) else {
        if state == .preparing, settings.selectedModel == model { state = .idle }
        return
      }
      guard !Task.isCancelled, settings.selectedModel == model else { return }
      do {
        try await runtime.prepare(
          model: model,
          guideWords: guideWords,
          guideWordStrength: guideWordStrength
        )
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
    recognitionLogger.info("Dictation started session=\(session.uuidString, privacy: .public)")
    insertionTargetTask?.cancel()
    insertionTargetTask = nil
    insertionTarget = TextInserter.captureTarget(context: "recording-start")
    if insertionTarget == nil {
      insertionTargetTask = Task { [weak self] in
        let retryDelays = [40, 160, 800, 1_200]
        for (index, delay) in retryDelays.enumerated() {
          try? await Task.sleep(for: .milliseconds(delay))
          guard !Task.isCancelled, let self, self.currentSession == session else { return }
          if let target = TextInserter.captureTarget(context: "recording-retry-\(index + 1)") {
            self.insertionTarget = target
            self.insertionTargetTask = nil
            return
          }
        }
        self?.insertionTargetTask = nil
      }
    }
    cleanupEnabled = settings.cleanupEnabledByDefault
    cleanupModelForSession = settings.cleanupModel
    localModelForSession = settings.selectedModel
    guideWordsForSession = settings.cleanGuideWords()
    localGuideWordStrengthForSession = settings.guideWordStrength(for: settings.selectedModel)
    transcriptionModeForSession = settings.transcriptionMode
    cloudProviderForSession = settings.cloudProvider
    cloudGuideWordStrengthForSession = settings.guideWordStrength(for: settings.cloudProvider)
    recognitionEngine = settings.selectedModel.displayName
    returnAfterInsertion = false
    transcript = ""
    audioMeter.reset()
    state = .preparing
    if settings.showOverlay { onOverlayVisibility?(true) }
    startupTask = Task { [weak self] in
      await self?.beginCapture(session: session)
    }
    sounds.play(.recordingStarted)
  }

  func finishDictation() {
    let finishRequested = ContinuousClock.now
    dictationActive = false
    guard recording else {
      startupTask?.cancel()
      startupTask = nil
      if state == .preparing { state = .idle }
      insertionTargetTask?.cancel()
      insertionTargetTask = nil
      insertionTarget = nil
      returnAfterInsertion = false
      onOverlayVisibility?(false)
      onKeyboardModeChange?(.none)
      beginBackgroundCleanup()
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
    audioMeter.reset()
    state = .finalizing
    onKeyboardModeChange?(.finalizing)
    let session = currentSession
    let captureLifecycle = captureLifecycle
    finalizationTask = Task { [weak self] in
      let samples = await captureLifecycle.stop()
      recognitionLogger.info(
        "Capture stopped samples=\(samples.count) elapsedMs=\(finishRequested.duration(to: .now).milliseconds)"
      )
      await pendingStartup?.value
      await pendingLiveUpdate?.value
      recognitionLogger.info(
        "Live inference drained elapsedMs=\(finishRequested.duration(to: .now).milliseconds)"
      )
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
    cloudUpdatesTask?.cancel()
    cloudUpdatesTask = nil
    let pendingCloud = cloudSession
    cloudSession = nil
    audioMeterTask?.cancel()
    finalizationTask?.cancel()
    finalizationTask = nil
    insertionTargetTask?.cancel()
    insertionTargetTask = nil
    insertionTarget = nil
    onKeyboardModeChange?(.none)
    let captureLifecycle = captureLifecycle
    Task {
      _ = await captureLifecycle.stop()
      await pendingStartup?.value
      await pendingLiveUpdate?.value
      await pendingCloud?.cancel()
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
    let model = localModelForSession
    let provider = cloudProviderForSession
    let cloudKey = cloudCredentials.key(for: provider)
    let useCloud = transcriptionModeForSession != .localOnly && cloudKey != nil
    if transcriptionModeForSession == .cloudOnly, cloudKey == nil {
      fail("Add a \(provider.displayName) API key in Settings.", session: session)
      return
    }
    if !useCloud, !(await ModelStorage.isDownloaded(model)) {
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
      let audioUpdates = try await captureLifecycle.start(deviceUID: device?.id)
      guard dictationActive, currentSession == session else { return }
      selectedMicrophone = device?.name ?? "System Default"
      recording = true
      state = .listening
      startAudioMeter(session: session)
      if useCloud, let cloudKey {
        do {
          try await startCloudTranscription(
            provider: provider,
            apiKey: cloudKey,
            audioUpdates: audioUpdates,
            session: session
          )
        } catch {
          if transcriptionModeForSession == .automatic {
            recognitionLogger.notice(
              "Cloud startup failed provider=\(provider.rawValue, privacy: .public) error=\(error.localizedDescription, privacy: .public); using local fallback"
            )
            try await startLocalTranscription(audioUpdates: audioUpdates, session: session)
          } else {
            throw error
          }
        }
      } else {
        try await startLocalTranscription(audioUpdates: audioUpdates, session: session)
      }
    } catch {
      fail(error.localizedDescription, session: session)
    }
  }

  private func startCloudTranscription(
    provider: CloudTranscriptionProvider,
    apiKey: String,
    audioUpdates: AsyncStream<Int>,
    session: UUID
  ) async throws {
    let cloud = try await CloudTranscriptionSession.connect(
      provider: provider,
      apiKey: apiKey,
      guideWords: guideWordsForSession,
      guideWordStrength: cloudGuideWordStrengthForSession
    )
    guard currentSession == session else {
      await cloud.cancel()
      return
    }
    cloudSession = cloud
    recognitionEngine = provider.displayName
    cloudUpdatesTask?.cancel()
    cloudUpdatesTask = Task { [weak self] in
      do {
        for try await update in cloud.updates {
          guard !Task.isCancelled, let self,
            self.currentSession == session,
            self.cloudSession === cloud
          else { return }
          self.transcript = update
        }
      } catch {
        recognitionLogger.notice(
          "Cloud update stream failed provider=\(provider.rawValue, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
        )
      }
    }
    if recording {
      startAudioLoop(audioUpdates: audioUpdates, cloud: cloud, session: session)
    }
  }

  private func startLocalTranscription(
    audioUpdates: AsyncStream<Int>,
    session: UUID
  ) async throws {
    let model = localModelForSession
    guard await ModelStorage.isDownloaded(model) else {
      throw RecognitionError.localFallbackUnavailable(model.displayName)
    }
    try await runtime.startLive(
      model: model,
      guideWords: guideWordsForSession,
      guideWordStrength: localGuideWordStrengthForSession
    )
    guard recording, currentSession == session else { return }
    recognitionEngine = model.displayName
    startAudioLoop(audioUpdates: audioUpdates, cloud: nil, session: session)
  }

  private func startAudioLoop(
    audioUpdates: AsyncStream<Int>,
    cloud initialCloud: CloudTranscriptionSession?,
    session: UUID
  ) {
    let capture = capture
    liveTask = Task.detached(priority: .utility) { [weak self] in
      var cloud = initialCloud
      var sentSampleCount = 0
      var inferenceGate = LiveInferenceGate(sampleRate: MicrophoneCapture.sampleRate)
      for await sampleCount in audioUpdates {
        guard !Task.isCancelled, let self else { return }
        if let activeCloud = cloud {
          do {
            // Network providers consume each capture buffer as it arrives. The adaptive
            // inference gate below exists only for expensive local decoding passes.
            let samples = capture.samples(from: sentSampleCount, through: sampleCount)
            try await activeCloud.append(samples: samples)
            sentSampleCount = sampleCount
            continue
          } catch {
            guard await self.activateLocalFallback(
              from: activeCloud,
              error: error,
              session: session
            ) else { return }
            cloud = nil
          }
        }

        guard inferenceGate.shouldRun(at: sampleCount) else { continue }
        let samples = capture.snapshot()
        guard !samples.isEmpty else { continue }
        let inferenceStarted = ContinuousClock.now
        guard
          let processedSampleCount = await self.refreshLiveTranscript(
            samples: samples,
            session: session
          )
        else { return }
        let inferenceSeconds = inferenceStarted.duration(to: .now).milliseconds / 1_000
        if inferenceSeconds >= 0.5 {
          recognitionLogger.notice(
            "Slow live inference audioSeconds=\(Double(processedSampleCount) / MicrophoneCapture.sampleRate) inferenceSeconds=\(inferenceSeconds)"
          )
        }
        inferenceGate.didFinishInference(
          processedSampleCount: processedSampleCount,
          durationSeconds: inferenceSeconds
        )
      }
    }
  }

  private func activateLocalFallback(
    from cloud: CloudTranscriptionSession,
    error: Error,
    session: UUID
  ) async -> Bool {
    guard recording, currentSession == session, cloudSession === cloud else { return false }
    if transcriptionModeForSession == .cloudOnly {
      fail(error.localizedDescription, session: session)
      return false
    }
    cloudSession = nil
    cloudUpdatesTask?.cancel()
    cloudUpdatesTask = nil
    await cloud.cancel()
    do {
      let model = localModelForSession
      guard await ModelStorage.isDownloaded(model) else {
        throw RecognitionError.localFallbackUnavailable(model.displayName)
      }
      try await runtime.startLive(
        model: model,
        guideWords: guideWordsForSession,
        guideWordStrength: localGuideWordStrengthForSession
      )
      recognitionEngine = model.displayName
      recognitionLogger.notice(
        "Cloud transcription failed; local fallback activated provider=\(self.cloudProviderForSession.rawValue, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
      )
      return recording && currentSession == session
    } catch {
      fail(error.localizedDescription, session: session)
      return false
    }
  }

  private func refreshLiveTranscript(samples: [Float], session: UUID) async -> Int? {
    guard recording, currentSession == session else { return nil }
    let model = localModelForSession
    let guideWords = guideWordsForSession
    let guideWordStrength = localGuideWordStrengthForSession
    do {
      if let event = try await runtime.updateLive(samples: samples, final: false) {
        guard recording, currentSession == session else { return nil }
        transcript = event.text
        return samples.count
      }
      let publishesIntermediateResults = model.publishesIntermediateBatchResults
      let result = try await runtime.transcribe(
        samples: samples,
        model: model,
        guideWords: guideWords,
        guideWordStrength: guideWordStrength
      ) { [weak self] event in
        guard publishesIntermediateResults else { return }
        Task { @MainActor in
          guard let self, self.recording, self.currentSession == session else { return }
          self.transcript = event.text
        }
      }
      guard recording, currentSession == session else { return nil }
      transcript = result
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
    let model = localModelForSession
    let recognitionStarted = ContinuousClock.now
    do {
      let final: String
      if let cloud = cloudSession {
        do {
          final = try await cloud.finish(completeAudio: samples)
          transcript = final
          await stopCloudSession(cloud)
        } catch {
          await stopCloudSession(cloud)
          guard transcriptionModeForSession == .automatic else { throw error }
          recognitionLogger.notice(
            "Cloud finalization failed provider=\(self.cloudProviderForSession.rawValue, privacy: .public) error=\(error.localizedDescription, privacy: .public); retrying locally"
          )
          final = try await transcribeLocally(samples: samples, session: session)
          recognitionEngine = model.displayName
        }
      } else {
        final = try await transcribeLocally(samples: samples, session: session)
      }
      recognitionLogger.info(
        "Final recognition completed engine=\(self.recognitionEngine, privacy: .public) audioSeconds=\(Double(samples.count) / MicrophoneCapture.sampleRate) elapsedMs=\(recognitionStarted.duration(to: .now).milliseconds)"
      )
      guard !final.isEmpty else { throw RecognitionError.noSpeech }
      guard !Task.isCancelled, currentSession == session else { return }
      let rawTranscript = final
      let shouldCleanup = cleanupEnabled
      let deliveredTranscript: String
      let appliedCleanup: Bool
      if shouldCleanup {
        let cleanupStarted = ContinuousClock.now
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
        recognitionLogger.info(
          "Transcript cleanup completed model=\(self.cleanupModelForSession.rawValue, privacy: .public) elapsedMs=\(cleanupStarted.duration(to: .now).milliseconds)"
        )
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
      insertionTargetTask?.cancel()
      insertionTargetTask = nil
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
      recognitionLogger.info(
        "Dictation delivered result=\(String(describing: delivery), privacy: .public)"
      )
    } catch RecognitionError.noSpeech {
      guard !Task.isCancelled else { return }
      finishWithoutText(session: session)
    } catch {
      guard !Task.isCancelled else { return }
      fail(error.localizedDescription, session: session)
    }
  }

  private func transcribeLocally(samples: [Float], session: UUID) async throws -> String {
    let model = localModelForSession
    guard await ModelStorage.isDownloaded(model) else {
      throw RecognitionError.localFallbackUnavailable(model.displayName)
    }
    if let event = try await runtime.updateLive(samples: samples, final: true) {
      transcript = event.text
      return event.text
    }
    let publishesIntermediateResults = model.publishesIntermediateBatchResults
    let final = try await runtime.transcribe(
      samples: samples,
      model: model,
      guideWords: guideWordsForSession,
      guideWordStrength: localGuideWordStrengthForSession
    ) { [weak self] event in
      guard publishesIntermediateResults else { return }
      Task { @MainActor in
        guard let self, self.currentSession == session else { return }
        self.transcript = event.text
      }
    }
    transcript = final
    return final
  }

  private func stopCloudSession(_ cloud: CloudTranscriptionSession) async {
    if cloudSession === cloud { cloudSession = nil }
    cloudUpdatesTask?.cancel()
    cloudUpdatesTask = nil
    await cloud.cancel()
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
    insertionTargetTask?.cancel()
    insertionTargetTask = nil
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
    let captureLifecycle = captureLifecycle
    let runtime = runtime
    let cloud = cloudSession
    cloudSession = nil
    cloudUpdatesTask?.cancel()
    cloudUpdatesTask = nil
    let pendingCleanup = runtimeCancellationTask
    runtimeCancellationTask = Task.detached(priority: .utility) {
      await pendingCleanup?.value
      _ = await captureLifecycle.stop()
      await cloud?.cancel()
      await runtime.cancelLive()
    }
  }

  private func fail(_ message: String, session: UUID) {
    guard currentSession == session else { return }
    dictationActive = false
    recording = false
    liveTask?.cancel()
    liveTask = nil
    audioMeterTask?.cancel()
    audioMeterTask = nil
    insertionTarget = nil
    insertionTargetTask?.cancel()
    insertionTargetTask = nil
    returnAfterInsertion = false
    transcript = ""
    audioMeter.reset()
    state = .error(message)
    onOverlayVisibility?(false)
    onKeyboardModeChange?(.none)
    beginBackgroundCleanup()
  }

  private func finishWithoutText(session: UUID) {
    guard currentSession == session else { return }
    recording = false
    insertionTarget = nil
    insertionTargetTask?.cancel()
    insertionTargetTask = nil
    returnAfterInsertion = false
    transcript = ""
    audioMeter.reset()
    state = .idle
    onOverlayVisibility?(false)
    onKeyboardModeChange?(.none)
    beginBackgroundCleanup()
  }
}

private extension BenchmarkModel {
  var publishesIntermediateBatchResults: Bool {
    switch self {
    case .appleSpeech, .appleDictation:
      false
    default:
      true
    }
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
  case localFallbackUnavailable(String)

  var errorDescription: String? {
    switch self {
    case .modelUnavailable: "The selected speech model is unavailable."
    case .modelInUse: "Stop dictation before deleting this model."
    case .noSpeech: "The model did not detect speech."
    case .invalidAudioStream: "The live audio stream became inconsistent."
    case .localFallbackUnavailable(let model):
      "Download \(model) to use local transcription or automatic fallback."
    }
  }
}
