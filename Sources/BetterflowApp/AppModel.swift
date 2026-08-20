import AppKit
import Combine
import Foundation

@MainActor
final class AppModel: ObservableObject {
  static let shared = AppModel()

  let settings: AppSettings
  let history: TranscriptionHistory
  let sounds: AppSoundPlayer
  let cleanupRuntime: TranscriptCleanupRuntime
  let coordinator: RecognitionCoordinator
  let modelDownloads: ModelDownloadManager
  let cleanupModelDownloads: CleanupModelDownloadManager

  @Published private(set) var microphoneGranted = AppPermission.microphoneGranted
  @Published private(set) var accessibilityGranted = AppPermission.accessibilityGranted

  private var overlay: OverlayController?
  private var settingsWindow: BetterflowSettingsWindowController?
  private var hotkey: HotkeyMonitor?
  private var cancellables: Set<AnyCancellable> = []
  private var started = false

  private init() {
    let settings = AppSettings()
    let history = TranscriptionHistory()
    let sounds = AppSoundPlayer()
    self.settings = settings
    self.history = history
    self.sounds = sounds
    let cleanupRuntime = TranscriptCleanupRuntime()
    self.cleanupRuntime = cleanupRuntime
    coordinator = RecognitionCoordinator(
      settings: settings,
      history: history,
      sounds: sounds,
      cleanupRuntime: cleanupRuntime
    )
    modelDownloads = ModelDownloadManager(settings: settings, coordinator: coordinator)
    cleanupModelDownloads = CleanupModelDownloadManager(
      settings: settings,
      runtime: cleanupRuntime
    )
    coordinator.objectWillChange
      .sink { [weak self] in self?.objectWillChange.send() }
      .store(in: &cancellables)
    settings.objectWillChange
      .sink { [weak self] in self?.objectWillChange.send() }
      .store(in: &cancellables)
  }

  func start() {
    guard !started else { return }
    started = true
    let overlay = OverlayController(coordinator: coordinator)
    self.overlay = overlay
    settingsWindow = BetterflowSettingsWindowController(model: self)
    coordinator.onOverlayVisibility = { [weak overlay] visible in
      if visible {
        overlay?.show()
      } else {
        overlay?.hide()
      }
    }
    hotkey = HotkeyMonitor(
      key: { [settings] in settings.dictationKey },
      onToggle: { [coordinator] in coordinator.toggleDictation() },
      onFinish: { [coordinator] in coordinator.finishDictation() },
      onQueueReturn: { [coordinator] in coordinator.queueReturnAfterInsertion() },
      onInsertCurrent: { [coordinator] in coordinator.insertCurrentTranscript() },
      onToggleCleanup: { [coordinator] in coordinator.toggleCleanup() },
      onCancel: { [coordinator] in coordinator.cancelDictation() }
    )
    coordinator.onKeyboardModeChange = { [weak hotkey] mode in
      hotkey?.setDictationMode(mode)
    }
    hotkey?.start()
    modelDownloads.refresh(prepareSelectedModel: true)
    cleanupModelDownloads.refresh(prepareSelectedModel: true)
    refreshPermissions()
    Timer.publish(every: 0.75, on: .main, in: .common)
      .autoconnect()
      .sink { [weak self] _ in self?.refreshPermissions() }
      .store(in: &cancellables)
    NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
      .sink { [weak self] _ in self?.refreshPermissions() }
      .store(in: &cancellables)
  }

  func requestMicrophone() {
    Task {
      _ = await AppPermission.requestMicrophone()
      refreshPermissions()
    }
  }

  func showSettings() {
    refreshPermissions()
    settingsWindow?.show()
  }

  func requestAccessibility() {
    AppPermission.requestAccessibility()
    schedulePermissionRefresh()
  }

  func copyTranscript(_ text: String) {
    TextDelivery.copy(text)
    sounds.play(.textCopied)
  }

  func refreshPermissions() {
    let accessibilityWasGranted = accessibilityGranted
    let currentMicrophone = AppPermission.microphoneGranted
    let currentAccessibility = AppPermission.accessibilityGranted
    if microphoneGranted != currentMicrophone {
      microphoneGranted = currentMicrophone
    }
    if accessibilityGranted != currentAccessibility {
      accessibilityGranted = currentAccessibility
    }
    if accessibilityGranted, !accessibilityWasGranted {
      hotkey?.start()
    }
  }

  func quit() {
    hotkey?.stop()
    coordinator.shutdown()
    NSApplication.shared.terminate(nil)
  }

  private func schedulePermissionRefresh() {
    Task {
      for _ in 0..<20 {
        try? await Task.sleep(for: .milliseconds(500))
        refreshPermissions()
      }
    }
  }
}
