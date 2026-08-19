import AppKit
import SwiftUI

@MainActor
final class BetterflowSettingsWindowController: NSWindowController, NSWindowDelegate {
  init(model: AppModel) {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 720, height: 580),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false
    )
    window.title = "Betterflow Settings"
    window.minSize = NSSize(width: 680, height: 540)
    window.isReleasedWhenClosed = false
    window.contentView = NSHostingView(rootView: SettingsView(model: model))
    super.init(window: window)
    window.delegate = self
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    nil
  }

  func show() {
    guard let window else { return }
    NSApplication.shared.setActivationPolicy(.regular)
    window.center()
    showWindow(nil)
    NSApplication.shared.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)
  }

  func windowWillClose(_: Notification) {
    NSApplication.shared.setActivationPolicy(.accessory)
  }
}
