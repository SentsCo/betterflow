import AppKit
import SwiftUI

@main
struct BetterflowApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @StateObject private var model = AppModel.shared

  var body: some Scene {
    MenuBarExtra("Betterflow", systemImage: menuIcon) {
      MenuContentView(model: model, coordinator: model.coordinator)
    }
    .menuBarExtraStyle(.window)
  }

  private var menuIcon: String {
    model.coordinator.state == .listening ? "waveform.circle.fill" : "waveform.circle"
  }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_: Notification) {
    NSApplication.shared.setActivationPolicy(.accessory)
    AppModel.shared.start()
    if ProcessInfo.processInfo.arguments.contains("--show-settings")
      || !AppPermission.microphoneGranted
      || !AppPermission.accessibilityGranted
    {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
        AppModel.shared.showSettings()
      }
    }
  }

  func applicationWillTerminate(_: Notification) {
    AppModel.shared.coordinator.shutdown()
  }
}
