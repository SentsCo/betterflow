@preconcurrency import AVFoundation
import Foundation

enum Recorder {
  static func record(to output: URL, seconds: Double?) async throws {
    let allowed: Bool
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized: allowed = true
    case .notDetermined: allowed = await AVCaptureDevice.requestAccess(for: .audio)
    default: allowed = false
    }
    guard allowed else { throw RecorderError.microphoneDenied }

    try FileManager.default.createDirectory(
      at: output.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let engine = AVAudioEngine()
    let input = engine.inputNode
    let format = input.outputFormat(forBus: 0)
    let file = try AVAudioFile(forWriting: output, settings: format.settings)
    input.installTap(onBus: 0, bufferSize: 1_024, format: format) { buffer, _ in
      do { try file.write(from: buffer) } catch {
        fputs("Recording write failed: \(error)\n", stderr)
      }
    }
    defer {
      input.removeTap(onBus: 0)
      engine.stop()
    }
    engine.prepare()
    try engine.start()
    print("Recording \(output.path)…")
    if let seconds {
      print(String(format: "Stopping after %.1f seconds.", seconds))
      try await Task.sleep(for: .seconds(seconds))
    } else {
      print("Press Return to stop.")
      _ = readLine()
    }
  }
}

enum RecorderError: LocalizedError {
  case microphoneDenied

  var errorDescription: String? {
    "Microphone access is required. Allow your terminal in System Settings → Privacy & Security → Microphone."
  }
}
