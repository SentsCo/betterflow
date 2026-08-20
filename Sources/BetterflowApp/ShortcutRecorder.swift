import AppKit
import SwiftUI

struct ShortcutRecorder: NSViewRepresentable {
  @Binding var shortcut: ScreenshotShortcut

  func makeCoordinator() -> Coordinator {
    Coordinator(shortcut: $shortcut)
  }

  func makeNSView(context: Context) -> ShortcutRecorderButton {
    let button = ShortcutRecorderButton()
    button.onChange = { context.coordinator.shortcut.wrappedValue = $0 }
    button.shortcut = shortcut
    return button
  }

  func updateNSView(_ button: ShortcutRecorderButton, context _: Context) {
    guard !button.isRecording else { return }
    button.shortcut = shortcut
  }

  final class Coordinator {
    let shortcut: Binding<ScreenshotShortcut>

    init(shortcut: Binding<ScreenshotShortcut>) {
      self.shortcut = shortcut
    }
  }
}

final class ShortcutRecorderButton: NSButton {
  var onChange: ((ScreenshotShortcut) -> Void)?
  var shortcut = ScreenshotShortcut.standard {
    didSet { if !isRecording { title = shortcut.label } }
  }
  private(set) var isRecording = false
  private var eventMonitor: Any?

  init() {
    super.init(frame: .zero)
    bezelStyle = .rounded
    target = self
    action = #selector(beginRecording)
    title = shortcut.label
    toolTip = "Click, then press a shortcut"
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    nil
  }

  @objc private func beginRecording() {
    guard !isRecording else { return }
    isRecording = true
    title = "Press shortcut…"
    window?.makeFirstResponder(self)
    eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
      [weak self] event in
      guard let self, self.isRecording else { return event }
      self.record(event)
      return nil
    }
  }

  private func record(_ event: NSEvent) {
    guard event.keyCode != 53 else {
      finishRecording()
      return
    }
    let key = shortcutKeyLabel(for: event)
    guard !key.isEmpty else { return }
    let updated = ScreenshotShortcut(
      keyCode: event.keyCode,
      modifierFlagsRawValue: event.modifierFlags
        .intersection(.deviceIndependentFlagsMask).rawValue,
      key: key
    )
    shortcut = updated
    onChange?(updated)
    finishRecording()
  }

  private func finishRecording() {
    if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
    eventMonitor = nil
    isRecording = false
    title = shortcut.label
  }
}

private func shortcutKeyLabel(for event: NSEvent) -> String {
  switch event.keyCode {
  case 36, 76: "↩"
  case 48: "⇥"
  case 49: "Space"
  case 51: "⌫"
  case 53: "Esc"
  case 115: "Home"
  case 116: "Page Up"
  case 117: "⌦"
  case 119: "End"
  case 121: "Page Down"
  case 123: "←"
  case 124: "→"
  case 125: "↓"
  case 126: "↑"
  case 122: "F1"
  case 120: "F2"
  case 99: "F3"
  case 118: "F4"
  case 96: "F5"
  case 97: "F6"
  case 98: "F7"
  case 100: "F8"
  case 101: "F9"
  case 109: "F10"
  case 103: "F11"
  case 111: "F12"
  default: event.charactersIgnoringModifiers?.uppercased() ?? ""
  }
}
