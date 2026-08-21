import Foundation

struct TranscriptionHistoryItem: Codable, Identifiable, Sendable {
  let id: UUID
  let text: String
  let rawText: String?
  let recognitionEngine: String?
  let createdAt: Date
}

@MainActor
final class TranscriptionHistory: ObservableObject {
  @Published private(set) var items: [TranscriptionHistoryItem]
  @Published private(set) var persistenceError: String?

  private let fileURL: URL
  private let persistenceQueue = DispatchQueue(
    label: "com.zachsents.betterflow.transcription-history",
    qos: .utility
  )

  init(fileURL: URL = TranscriptionHistory.defaultFileURL) {
    self.fileURL = fileURL
    do {
      let data = try Data(contentsOf: fileURL)
      items = try JSONDecoder().decode([TranscriptionHistoryItem].self, from: data)
        .sorted { $0.createdAt > $1.createdAt }
    } catch CocoaError.fileReadNoSuchFile {
      items = []
    } catch {
      items = []
      persistenceError = error.localizedDescription
    }
  }

  func add(_ text: String, rawText: String? = nil, recognitionEngine: String? = nil) {
    items.insert(
      TranscriptionHistoryItem(
        id: UUID(),
        text: text,
        rawText: rawText,
        recognitionEngine: recognitionEngine,
        createdAt: Date()
      ),
      at: 0
    )
    save()
  }

  func waitForPersistence() async {
    await withCheckedContinuation { continuation in
      persistenceQueue.async { continuation.resume() }
    }
  }

  private func save() {
    let fileURL = fileURL
    let items = items
    persistenceQueue.async { [weak self] in
      let errorMessage: String?
      do {
        try FileManager.default.createDirectory(
          at: fileURL.deletingLastPathComponent(),
          withIntermediateDirectories: true
        )
        try JSONEncoder().encode(items).write(to: fileURL, options: .atomic)
        errorMessage = nil
      } catch {
        errorMessage = error.localizedDescription
      }
      DispatchQueue.main.async {
        MainActor.assumeIsolated { self?.persistenceError = errorMessage }
      }
    }
  }

  private static var defaultFileURL: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Betterflow", isDirectory: true)
      .appendingPathComponent("transcription-history.json")
  }
}
