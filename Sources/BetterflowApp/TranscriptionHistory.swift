import Foundation

struct TranscriptionHistoryItem: Codable, Identifiable, Sendable {
  let id: UUID
  let text: String
  let rawText: String?
  let createdAt: Date
}

@MainActor
final class TranscriptionHistory: ObservableObject {
  @Published private(set) var items: [TranscriptionHistoryItem]
  @Published private(set) var persistenceError: String?

  private let fileURL: URL

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

  func add(_ text: String, rawText: String? = nil) {
    items.insert(
      TranscriptionHistoryItem(
        id: UUID(),
        text: text,
        rawText: rawText,
        createdAt: Date()
      ),
      at: 0
    )
    save()
  }

  private func save() {
    do {
      try FileManager.default.createDirectory(
        at: fileURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try JSONEncoder().encode(items).write(to: fileURL, options: .atomic)
      persistenceError = nil
    } catch {
      persistenceError = error.localizedDescription
    }
  }

  private static var defaultFileURL: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Betterflow", isDirectory: true)
      .appendingPathComponent("transcription-history.json")
  }
}
