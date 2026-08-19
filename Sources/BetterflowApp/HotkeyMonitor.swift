import AppKit

private let returnKeyCodes: Set<Int64> = [36, 76]

enum DictationKeyboardMode: Sendable {
  case none
  case recording
  case finalizing
}

enum DictationKeyCommand: Equatable {
  case finish
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
  return mode == .recording ? .finish : nil
}

private extension PushToTalkKey {
  var eventFlag: CGEventFlags {
    switch self {
    case .leftCommand, .rightCommand: .maskCommand
    case .leftOption, .rightOption: .maskAlternate
    case .leftControl, .rightControl: .maskControl
    case .function: .maskSecondaryFn
    }
  }
}

struct PushToTalkGesture {
  enum ReleaseAction: Equatable {
    case latch
    case finish
    case none
  }

  private enum Phase {
    case idle
    case tapped
    case held
    case ignored
  }

  private var phase = Phase.idle

  var isTracking: Bool {
    phase == .tapped
  }

  mutating func press(dictationStarted: Bool) {
    phase = dictationStarted ? .tapped : .ignored
  }

  mutating func holdThresholdReached() {
    if phase == .tapped { phase = .held }
  }

  mutating func release() -> ReleaseAction {
    defer { phase = .idle }
    switch phase {
    case .tapped: return .latch
    case .held: return .finish
    case .idle, .ignored: return .none
    }
  }

  mutating func cancel() {
    phase = .idle
  }
}

@MainActor
final class HotkeyMonitor {
  private static let holdThreshold = Duration.milliseconds(250)

  private let key: () -> PushToTalkKey
  private let onPress: () -> Bool
  private let onHoldRelease: () -> Void
  private let commandInterceptor: KeyCommandInterceptor
  private var globalMonitor: Any?
  private var localMonitor: Any?
  private var eventTap: CFMachPort?
  private var eventTapSource: CFRunLoopSource?
  private var holdTask: Task<Void, Never>?
  private var gesture = PushToTalkGesture()
  private var pressed = false

  init(
    key: @escaping () -> PushToTalkKey,
    onPress: @escaping () -> Bool,
    onHoldRelease: @escaping () -> Void,
    onFinish: @escaping @MainActor @Sendable () -> Void,
    onInsertCurrent: @escaping @MainActor @Sendable () -> Void,
    onToggleCleanup: @escaping @MainActor @Sendable () -> Void,
    onCancel: @escaping @MainActor @Sendable () -> Void
  ) {
    self.key = key
    self.onPress = onPress
    self.onHoldRelease = onHoldRelease
    commandInterceptor = KeyCommandInterceptor(
      onFinish: onFinish,
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
    holdTask?.cancel()
    holdTask = nil
    pressed = false
    gesture.cancel()
    commandInterceptor.setMode(.none)
  }

  func setDictationMode(_ mode: DictationKeyboardMode) {
    commandInterceptor.setMode(mode, ignoring: key().eventFlag)
    if mode != .recording {
      holdTask?.cancel()
      holdTask = nil
      gesture.cancel()
    }
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
    if isDown {
      gesture.press(dictationStarted: onPress())
      guard gesture.isTracking else { return }
      holdTask = Task { [weak self] in
        try? await Task.sleep(for: Self.holdThreshold)
        guard !Task.isCancelled else { return }
        self?.gesture.holdThresholdReached()
      }
      return
    }

    holdTask?.cancel()
    holdTask = nil
    switch gesture.release() {
    case .latch: break
    case .finish: onHoldRelease()
    case .none: break
    }
  }
}

private final class KeyCommandInterceptor: @unchecked Sendable {
  private let lock = NSLock()
  private let onFinish: @MainActor @Sendable () -> Void
  private let onInsertCurrent: @MainActor @Sendable () -> Void
  private let onToggleCleanup: @MainActor @Sendable () -> Void
  private let onCancel: @MainActor @Sendable () -> Void
  private var mode = DictationKeyboardMode.none
  private var ignoredModifierFlags: CGEventFlags = []
  private var swallowedKeyCodes: Set<Int64> = []

  init(
    onFinish: @escaping @MainActor @Sendable () -> Void,
    onInsertCurrent: @escaping @MainActor @Sendable () -> Void,
    onToggleCleanup: @escaping @MainActor @Sendable () -> Void,
    onCancel: @escaping @MainActor @Sendable () -> Void
  ) {
    self.onFinish = onFinish
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

  func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
    let result: (consume: Bool, command: DictationKeyCommand?) = lock.withLock {
      if type == .keyUp, swallowedKeyCodes.remove(keyCode) != nil {
        return (true, nil)
      }
      guard type == .keyDown else { return (false, nil) }

      let command = dictationKeyCommand(
        keyCode: keyCode,
        flags: event.flags,
        mode: mode,
        ignoring: ignoredModifierFlags
      )
      guard let command else { return (false, nil) }
      let isFirstPress = swallowedKeyCodes.insert(keyCode).inserted
      return (true, isFirstPress ? command : nil)
    }
    if let command = result.command {
      Task { @MainActor in
        switch command {
        case .finish: onFinish()
        case .insertCurrent: onInsertCurrent()
        case .toggleCleanup: onToggleCleanup()
        case .cancel: onCancel()
        }
      }
    }
    return result.consume ? nil : Unmanaged.passUnretained(event)
  }
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
