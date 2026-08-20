import AppKit

private let returnKeyCodes: Set<Int64> = [36, 76]

enum DictationKeyboardMode: Sendable {
  case none
  case recording
  case finalizing
}

enum DictationKeyCommand: Equatable {
  case finish
  case queueReturn
  case insertCurrent
  case toggleCleanup
  case cancel
}

func dictationKeyCommand(
  keyCode: Int64,
  flags: CGEventFlags,
  mode: DictationKeyboardMode,
  ignoring ignoredFlags: CGEventFlags = []
) -> DictationKeyCommand? {
  let effectiveFlags = flags.subtracting(ignoredFlags)
  if keyCode == 53, mode != .none { return .cancel }
  if keyCode == 6, mode != .none,
    effectiveFlags.intersection([.maskCommand, .maskControl, .maskAlternate]).isEmpty
  {
    return .toggleCleanup
  }
  guard returnKeyCodes.contains(keyCode) else { return nil }
  if effectiveFlags.contains(.maskCommand), mode != .none { return .insertCurrent }
  switch mode {
  case .recording: return .finish
  case .finalizing: return .queueReturn
  case .none: return nil
  }
}

extension DictationKey {
  fileprivate var eventFlag: CGEventFlags {
    switch self {
    case .leftCommand, .rightCommand: .maskCommand
    case .leftOption, .rightOption: .maskAlternate
    case .leftControl, .rightControl: .maskControl
    case .function: .maskSecondaryFn
    }
  }
}

extension ScreenshotShortcut {
  fileprivate var eventFlags: CGEventFlags {
    CGEventFlags(rawValue: UInt64(modifierFlagsRawValue))
  }

  fileprivate func matches(keyCode: Int64, flags: CGEventFlags) -> Bool {
    let modifierMask: CGEventFlags = [
      .maskCommand, .maskControl, .maskAlternate, .maskShift, .maskSecondaryFn,
    ]
    return keyCode == Int64(self.keyCode)
      && flags.intersection(modifierMask) == eventFlags
  }
}

@MainActor
final class HotkeyMonitor {
  private let key: () -> DictationKey
  private let onToggle: () -> Void
  private let commandInterceptor: KeyCommandInterceptor
  private var globalMonitor: Any?
  private var localMonitor: Any?
  private var eventTap: CFMachPort?
  private var eventTapSource: CFRunLoopSource?
  private var pressed = false

  init(
    key: @escaping () -> DictationKey,
    onToggle: @escaping () -> Void,
    screenshotShortcut: ScreenshotShortcut,
    onScreenshot: @escaping @MainActor @Sendable () -> Void,
    onFinish: @escaping @MainActor @Sendable () -> Void,
    onQueueReturn: @escaping @MainActor @Sendable () -> Void,
    onInsertCurrent: @escaping @MainActor @Sendable () -> Void,
    onToggleCleanup: @escaping @MainActor @Sendable () -> Void,
    onCancel: @escaping @MainActor @Sendable () -> Void
  ) {
    self.key = key
    self.onToggle = onToggle
    commandInterceptor = KeyCommandInterceptor(
      screenshotShortcut: screenshotShortcut,
      onScreenshot: onScreenshot,
      onFinish: onFinish,
      onQueueReturn: onQueueReturn,
      onInsertCurrent: onInsertCurrent,
      onToggleCleanup: onToggleCleanup,
      onCancel: onCancel
    )
  }

  func start() {
    stop()
    globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) {
      [weak self] event in
      Task { @MainActor in self?.handle(event) }
    }
    localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
      self?.handle(event)
      return event
    }
    startCommandInterceptor()
  }

  func stop() {
    if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
    if let localMonitor { NSEvent.removeMonitor(localMonitor) }
    if let eventTapSource {
      CFRunLoopRemoveSource(CFRunLoopGetMain(), eventTapSource, .commonModes)
    }
    if let eventTap { CFMachPortInvalidate(eventTap) }
    globalMonitor = nil
    localMonitor = nil
    eventTap = nil
    eventTapSource = nil
    pressed = false
    commandInterceptor.setMode(.none)
  }

  func setDictationMode(_ mode: DictationKeyboardMode) {
    commandInterceptor.setMode(mode, ignoring: key().eventFlag)
  }

  func setScreenshotShortcut(_ shortcut: ScreenshotShortcut) {
    commandInterceptor.setScreenshotShortcut(shortcut)
  }

  private func startCommandInterceptor() {
    let eventMask =
      CGEventMask(1 << CGEventType.keyDown.rawValue)
      | CGEventMask(1 << CGEventType.keyUp.rawValue)
    guard
      let eventTap = CGEvent.tapCreate(
        tap: .cgSessionEventTap,
        place: .headInsertEventTap,
        options: .defaultTap,
        eventsOfInterest: eventMask,
        callback: keyCommandEventTapCallback,
        userInfo: Unmanaged.passUnretained(commandInterceptor).toOpaque()
      )
    else { return }
    let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
    self.eventTap = eventTap
    eventTapSource = source
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    CGEvent.tapEnable(tap: eventTap, enable: true)
  }

  private func handle(_ event: NSEvent) {
    let isDown: Bool
    switch key() {
    case .leftCommand:
      guard event.keyCode == 55 else { return }
      isDown = event.modifierFlags.contains(.command)
    case .rightCommand:
      guard event.keyCode == 54 else { return }
      isDown = event.modifierFlags.contains(.command)
    case .leftOption:
      guard event.keyCode == 58 else { return }
      isDown = event.modifierFlags.contains(.option)
    case .rightOption:
      guard event.keyCode == 61 else { return }
      isDown = event.modifierFlags.contains(.option)
    case .leftControl:
      guard event.keyCode == 59 else { return }
      isDown = event.modifierFlags.contains(.control)
    case .rightControl:
      guard event.keyCode == 62 else { return }
      isDown = event.modifierFlags.contains(.control)
    case .function:
      guard event.keyCode == 63 else { return }
      isDown = event.modifierFlags.contains(.function)
    }
    guard isDown != pressed else { return }
    pressed = isDown
    if isDown { onToggle() }
  }
}

private final class KeyCommandInterceptor: @unchecked Sendable {
  private let lock = NSLock()
  private let onScreenshot: @MainActor @Sendable () -> Void
  private let onFinish: @MainActor @Sendable () -> Void
  private let onQueueReturn: @MainActor @Sendable () -> Void
  private let onInsertCurrent: @MainActor @Sendable () -> Void
  private let onToggleCleanup: @MainActor @Sendable () -> Void
  private let onCancel: @MainActor @Sendable () -> Void
  private var mode = DictationKeyboardMode.none
  private var ignoredModifierFlags: CGEventFlags = []
  private var screenshotShortcut: ScreenshotShortcut
  private var swallowedKeyCodes: Set<Int64> = []

  init(
    screenshotShortcut: ScreenshotShortcut,
    onScreenshot: @escaping @MainActor @Sendable () -> Void,
    onFinish: @escaping @MainActor @Sendable () -> Void,
    onQueueReturn: @escaping @MainActor @Sendable () -> Void,
    onInsertCurrent: @escaping @MainActor @Sendable () -> Void,
    onToggleCleanup: @escaping @MainActor @Sendable () -> Void,
    onCancel: @escaping @MainActor @Sendable () -> Void
  ) {
    self.screenshotShortcut = screenshotShortcut
    self.onScreenshot = onScreenshot
    self.onFinish = onFinish
    self.onQueueReturn = onQueueReturn
    self.onInsertCurrent = onInsertCurrent
    self.onToggleCleanup = onToggleCleanup
    self.onCancel = onCancel
  }

  func setMode(_ mode: DictationKeyboardMode, ignoring ignoredFlags: CGEventFlags = []) {
    lock.withLock {
      self.mode = mode
      ignoredModifierFlags = ignoredFlags
    }
  }

  func setScreenshotShortcut(_ shortcut: ScreenshotShortcut) {
    lock.withLock { screenshotShortcut = shortcut }
  }

  func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
    if event.getIntegerValueField(.eventSourceUserData)
      == betterflowSyntheticKeyEventMarker
    {
      return Unmanaged.passUnretained(event)
    }
    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
    let result: (consume: Bool, command: InterceptedKeyCommand?) = lock.withLock {
      if type == .keyUp, swallowedKeyCodes.remove(keyCode) != nil {
        return (true, nil)
      }
      guard type == .keyDown else { return (false, nil) }

      if screenshotShortcut.matches(keyCode: keyCode, flags: event.flags) {
        let isFirstPress = swallowedKeyCodes.insert(keyCode).inserted
        return (true, isFirstPress ? .screenshot : nil)
      }

      let command = dictationKeyCommand(
        keyCode: keyCode,
        flags: event.flags,
        mode: mode,
        ignoring: ignoredModifierFlags
      )
      guard let command else { return (false, nil) }
      let isFirstPress = swallowedKeyCodes.insert(keyCode).inserted
      return (true, isFirstPress ? .dictation(command) : nil)
    }
    if let command = result.command {
      Task { @MainActor in
        switch command {
        case .screenshot: onScreenshot()
        case .dictation(let command):
          switch command {
          case .finish: onFinish()
          case .queueReturn: onQueueReturn()
          case .insertCurrent: onInsertCurrent()
          case .toggleCleanup: onToggleCleanup()
          case .cancel: onCancel()
          }
        }
      }
    }
    return result.consume ? nil : Unmanaged.passUnretained(event)
  }
}

private enum InterceptedKeyCommand {
  case screenshot
  case dictation(DictationKeyCommand)
}

private func keyCommandEventTapCallback(
  _: CGEventTapProxy,
  type: CGEventType,
  event: CGEvent,
  userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
  guard let userInfo else { return Unmanaged.passUnretained(event) }
  let interceptor = Unmanaged<KeyCommandInterceptor>.fromOpaque(userInfo).takeUnretainedValue()
  return interceptor.handle(type: type, event: event)
}
