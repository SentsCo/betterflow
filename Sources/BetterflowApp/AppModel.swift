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
  let cloudCredentials: CloudCredentials
  let coordinator: RecognitionCoordinator
  let modelDownloads: ModelDownloadManager
  let cleanupModelDownloads: CleanupModelDownloadManager
  let screenshots: ScreenshotAnnotationController

  @Published private(set) var microphoneGranted = AppPermission.microphoneGranted
  @Published private(set) var accessibilityGranted = AppPermission.accessibilityGranted
  @Published private(set) var screenRecordingGranted = AppPermission.screenRecordingGranted
  @Published private(set) var audioDevices: [AudioInputDevice] = []

  private var overlay: OverlayController?
  private var settingsWindow: BetterflowSettingsWindowController?
  private var hotkey: HotkeyMonitor?
  private var audioDeviceObserver: AudioDeviceChangeObserver?
  private var audioDeviceRefreshTask: Task<Void, Never>?
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
    let cloudCredentials = CloudCredentials()
    self.cloudCredentials = cloudCredentials
    coordinator = RecognitionCoordinator(
      settings: settings,
      history: history,
      sounds: sounds,
      cleanupRuntime: cleanupRuntime,
      cloudCredentials: cloudCredentials
    )
    modelDownloads = ModelDownloadManager(settings: settings, coordinator: coordinator)
    cleanupModelDownloads = CleanupModelDownloadManager(
      settings: settings,
      runtime: cleanupRuntime
    )
    screenshots = ScreenshotAnnotationController()
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
      screenshotShortcut: settings.screenshotShortcut,
      onScreenshot: { [weak self] in self?.beginScreenshot() },
      onFinish: { [coordinator] in coordinator.finishDictation() },
      onQueueReturn: { [coordinator] in coordinator.queueReturnAfterInsertion() },
      onInsertCurrent: { [coordinator] in coordinator.insertCurrentTranscript() },
      onToggleCleanup: { [coordinator] in coordinator.toggleCleanup() },
      onCancel: { [coordinator] in coordinator.cancelDictation() }
    )
    coordinator.onKeyboardModeChange = { [weak hotkey] mode in
      hotkey?.setDictationMode(mode)
    }
    settings.$screenshotShortcut
      .sink { [weak hotkey] shortcut in hotkey?.setScreenshotShortcut(shortcut) }
      .store(in: &cancellables)
    screenshots.onCopied = { [sounds] in sounds.play(.textCopied) }
    screenshots.onFailure = { [weak self] message in self?.showScreenshotError(message) }
    audioDeviceObserver = AudioDeviceChangeObserver { [weak self] in
      self?.refreshAudioDevices()
    }
    hotkey?.start()
    modelDownloads.refresh(prepareSelectedModel: true)
    cleanupModelDownloads.refresh(prepareSelectedModel: true)
    refreshPermissions()
    refreshAudioDevices()
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

  func requestScreenRecording() {
    _ = AppPermission.requestScreenRecording()
    schedulePermissionRefresh()
  }

  func beginScreenshot() {
    guard !screenshots.isActive else { return }
    guard AppPermission.screenRecordingGranted else {
      requestScreenRecording()
      showSettings()
      return
    }
    if coordinator.state != .idle { coordinator.cancelDictation() }
    screenshots.start()
  }

  func copyTranscript(_ text: String) {
    TextDelivery.copy(text)
    sounds.play(.textCopied)
  }

  func refreshPermissions() {
    let accessibilityWasGranted = accessibilityGranted
    let currentMicrophone = AppPermission.microphoneGranted
    let currentAccessibility = AppPermission.accessibilityGranted
    let currentScreenRecording = AppPermission.screenRecordingGranted
    if microphoneGranted != currentMicrophone {
      microphoneGranted = currentMicrophone
    }
    if accessibilityGranted != currentAccessibility {
      accessibilityGranted = currentAccessibility
    }
    if screenRecordingGranted != currentScreenRecording {
      screenRecordingGranted = currentScreenRecording
    }
    if accessibilityGranted, !accessibilityWasGranted {
      hotkey?.start()
    }
  }

  func refreshAudioDevices() {
    audioDeviceRefreshTask?.cancel()
    audioDeviceRefreshTask = Task {
      let devices = await Task.detached(priority: .utility) {
        AudioDeviceCatalog.inputDevices()
      }.value
      guard !Task.isCancelled else { return }
      audioDevices = devices
      coordinator.updateAudioDevices(devices)
      settings.rememberMicrophones(devices)
      audioDeviceRefreshTask = nil
    }
  }

  func quit() {
    audioDeviceRefreshTask?.cancel()
    hotkey?.stop()
    screenshots.cancel()
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

  private func showScreenshotError(_ message: String) {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = "Screenshot Failed"
    alert.informativeText = message
    alert.runModal()
  }
}
