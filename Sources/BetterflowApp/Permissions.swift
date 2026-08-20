import AVFoundation
import ApplicationServices
import Foundation

@MainActor
enum AppPermission {
  static var microphoneGranted: Bool {
    AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
  }

  static var accessibilityGranted: Bool {
    AXIsProcessTrusted()
  }

  static var screenRecordingGranted: Bool {
    CGPreflightScreenCaptureAccess()
  }

  static func requestMicrophone() async -> Bool {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized: true
    case .notDetermined: await AVCaptureDevice.requestAccess(for: .audio)
    default: false
    }
  }

  @discardableResult
  static func requestAccessibility() -> Bool {
    let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
    return AXIsProcessTrustedWithOptions(options)
  }

  @discardableResult
  static func requestScreenRecording() -> Bool {
    CGRequestScreenCaptureAccess()
  }
}
