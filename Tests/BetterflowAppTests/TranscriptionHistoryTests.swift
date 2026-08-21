import Foundation
import Testing

@testable import BetterflowApp

@MainActor
@Test
func transcriptionHistoryPersistsNewestFirst() async throws {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  let fileURL = directory.appendingPathComponent("history.json")
  defer { try? FileManager.default.removeItem(at: directory) }

  let history = TranscriptionHistory(fileURL: fileURL)
  history.add("First transcription")
  history.add(
    "Latest transcription",
    rawText: "Um latest transcription",
    recognitionEngine: "OpenAI GPT Live Transcribe"
  )
  await history.waitForPersistence()

  #expect(history.items.map(\.text) == ["Latest transcription", "First transcription"])
  #expect(history.persistenceError == nil)

  let restored = TranscriptionHistory(fileURL: fileURL)
  #expect(restored.items.map(\.text) == ["Latest transcription", "First transcription"])
  #expect(restored.items.first?.rawText == "Um latest transcription")
  #expect(restored.items.first?.recognitionEngine == "OpenAI GPT Live Transcribe")
  #expect(restored.items.last?.rawText == nil)
  #expect(restored.items.last?.recognitionEngine == nil)
}
