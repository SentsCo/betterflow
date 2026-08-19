import BetterflowBenchmarkCore
import Foundation

enum ReportWriter {
  static func write(_ report: BenchmarkReport, directory: URL) throws -> (json: URL, markdown: URL)
  {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let jsonURL = directory.appendingPathComponent("report.json")
    let markdownURL = directory.appendingPathComponent("report.md")

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(report).write(to: jsonURL, options: .atomic)
    try markdown(report).write(to: markdownURL, atomically: true, encoding: .utf8)
    return (jsonURL, markdownURL)
  }

  static func markdown(_ report: BenchmarkReport) -> String {
    var lines = [
      "# Betterflow local ASR benchmark",
      "",
      "Host: \(report.host)  ",
      "Cadence: \(Int(report.cadenceMilliseconds)) ms  ",
      "Realtime pacing: \(report.realtimePacing ? "yes" : "no")",
      "",
      "| Model | Guidance | Case | WER | Guide recall | False guides | First text | Final lag | Revisions | Compute RTF |",
      "|---|---:|---|---:|---:|---:|---:|---:|---:|---:|",
    ]
    for item in report.runs {
      let metrics = item.metrics
      lines.append(
        "| \(item.run.model.shortName) | \(item.run.guidance.rawValue) | \(item.run.caseID) "
          + "| \(percent(metrics.wordErrorRate)) | \(percent(metrics.guideWordRecall)) "
          + "| \(metrics.guideWordFalsePositives) | \(milliseconds(metrics.firstTextLatencyMilliseconds)) "
          + "| \(milliseconds(metrics.finalizationLatencyMilliseconds)) | \(metrics.revisions) "
          + "| \(String(format: "%.2f", metrics.computeRealTimeFactor)) |"
      )
    }

    lines.append(contentsOf: ["", "## Guided versus unguided", ""])
    lines.append("| Model | Case | Δ WER | Δ guide recall | Δ first text |")
    lines.append("|---|---|---:|---:|---:|")
    let groups = Dictionary(grouping: report.runs) { "\($0.run.model.rawValue)|\($0.run.caseID)" }
    for group in groups.values.sorted(by: {
      ($0.first?.run.model.rawValue ?? "") + ($0.first?.run.caseID ?? "")
        < ($1.first?.run.model.rawValue ?? "") + ($1.first?.run.caseID ?? "")
    }) {
      guard
        let off = group.first(where: { $0.run.guidance == .off }),
        let on = group.first(where: { $0.run.guidance == .on })
      else { continue }
      let firstDelta: String
      if let offFirst = off.metrics.firstTextLatencyMilliseconds,
        let onFirst = on.metrics.firstTextLatencyMilliseconds
      {
        firstDelta = String(format: "%+.0f ms", onFirst - offFirst)
      } else {
        firstDelta = "n/a"
      }
      lines.append(
        "| \(on.run.model.shortName) | \(on.run.caseID) "
          + "| \(signedPercent(on.metrics.wordErrorRate - off.metrics.wordErrorRate)) "
          + "| \(guideDelta(on.metrics.guideWordRecall, off.metrics.guideWordRecall)) "
          + "| \(firstDelta) |"
      )
    }

    lines.append(contentsOf: ["", "## Final transcripts", ""])
    for item in report.runs {
      lines.append(
        "- **\(item.run.model.shortName) / \(item.run.guidance.rawValue) / \(item.run.caseID):** \(item.metrics.finalText)"
      )
    }
    if !report.failures.isEmpty {
      lines.append(contentsOf: ["", "## Unavailable or failed trials", ""])
      for failure in report.failures {
        let trial = [failure.guidance?.rawValue, failure.caseID]
          .compactMap { $0 }
          .joined(separator: " / ")
        let suffix = trial.isEmpty ? "" : " / \(trial)"
        lines.append(
          "- **\(failure.model.shortName) / \(failure.stage)\(suffix):** \(failure.message.replacingOccurrences(of: "\n", with: " "))"
        )
      }
    }
    lines.append("")
    return lines.joined(separator: "\n")
  }

  private static func percent(_ value: Double) -> String { String(format: "%.1f%%", value * 100) }
  private static func percent(_ value: Double?) -> String { value.map(percent) ?? "n/a" }
  private static func signedPercent(_ value: Double) -> String {
    String(format: "%+.1f pp", value * 100)
  }
  private static func guideDelta(_ on: Double?, _ off: Double?) -> String {
    guard let on, let off else { return "n/a" }
    return signedPercent(on - off)
  }
  private static func milliseconds(_ value: Double?) -> String {
    value.map { String(format: "%.0f ms", $0) } ?? "n/a"
  }
}
