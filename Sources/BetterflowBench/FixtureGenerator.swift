import BetterflowBenchmarkCore
import Foundation

enum FixtureGenerator {
  static let cases = [
    BenchmarkCase(
      id: "guided-terms",
      audio: "audio/guided-terms.aiff",
      reference:
        "Zach and Sara use WorkflowDog to manage a TanStack application backed by Postgres."
    ),
    BenchmarkCase(
      id: "guided-terms-in-context",
      audio: "audio/guided-terms-in-context.aiff",
      reference:
        "Sara asked Zach whether WorkflowDog should move its TanStack data layer from SQLite to Postgres."
    ),
    BenchmarkCase(
      id: "negative-control",
      audio: "audio/negative-control.aiff",
      reference:
        "The design review starts tomorrow morning, and everyone should bring their latest notes."
    ),
  ]

  static func generate(at benchmarkDirectory: URL) throws -> URL {
    let audioDirectory = benchmarkDirectory.appendingPathComponent("audio", isDirectory: true)
    try FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
    for item in cases {
      let output = benchmarkDirectory.appendingPathComponent(item.audio)
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
      process.arguments = ["-v", "Samantha", "-r", "190", "-o", output.path, item.reference]
      try process.run()
      process.waitUntilExit()
      guard process.terminationStatus == 0 else {
        throw FixtureError.sayFailed(item.id)
      }
    }

    let manifest = BenchmarkManifest(
      guideWords: ["Zach", "Sara", "WorkflowDog", "TanStack", "Postgres"],
      cases: cases
    )
    let manifestURL = benchmarkDirectory.appendingPathComponent("manifest.json")
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(manifest).write(to: manifestURL, options: .atomic)
    return manifestURL
  }
}

enum FixtureError: LocalizedError {
  case sayFailed(String)

  var errorDescription: String? {
    switch self {
    case .sayFailed(let id): "macOS say failed while generating fixture '\(id)'."
    }
  }
}
