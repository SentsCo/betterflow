import Foundation

public enum Metrics {
  public static func score(_ run: EngineRun) throws -> BenchmarkMetrics {
    guard let finalEvent = run.events.last else { throw BenchmarkError.noEvents }

    let referenceWords = words(run.reference)
    let outputWords = words(finalEvent.text)
    let errors = editDistance(referenceWords, outputWords)
    let wordErrorRate =
      referenceWords.isEmpty
      ? (outputWords.isEmpty ? 0 : 1)
      : Double(errors) / Double(referenceWords.count)

    let normalizedReference = normalized(run.reference)
    let normalizedOutput = normalized(finalEvent.text)
    let expectedTerms = run.guideWords.filter { containsTerm($0, in: normalizedReference) }
    let hitTerms = expectedTerms.filter { containsTerm($0, in: normalizedOutput) }
    let unexpectedTerms = run.guideWords.filter { !containsTerm($0, in: normalizedReference) }
    let falsePositives = unexpectedTerms.filter { containsTerm($0, in: normalizedOutput) }.count

    let firstText = run.events.first {
      !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    let speechStartMilliseconds = run.speechStartSeconds * 1_000
    let firstLatency = firstText.map {
      max(0, $0.elapsedMilliseconds - speechStartMilliseconds)
    }
    let audioMilliseconds = run.audioDurationSeconds * 1_000
    let finalizationLatency = max(0, finalEvent.elapsedMilliseconds - audioMilliseconds)

    var revisions = 0
    var revisedCharacters = 0
    for pair in zip(run.events, run.events.dropFirst()) {
      let old = pair.0.text
      let new = pair.1.text
      guard old != new, !new.hasPrefix(old) else { continue }
      revisions += 1
      let shared = commonPrefixLength(old, new)
      revisedCharacters += old.count - shared
    }

    return BenchmarkMetrics(
      finalText: finalEvent.text,
      wordErrorRate: wordErrorRate,
      guideWordRecall: expectedTerms.isEmpty
        ? nil : Double(hitTerms.count) / Double(expectedTerms.count),
      guideWordHits: hitTerms.count,
      guideWordExpected: expectedTerms.count,
      guideWordFalsePositives: falsePositives,
      firstTextLatencyMilliseconds: firstLatency,
      finalizationLatencyMilliseconds: finalizationLatency,
      partialUpdates: run.events.filter { !$0.isFinal }.count,
      revisions: revisions,
      revisedCharacters: revisedCharacters,
      computeRealTimeFactor: run.audioDurationSeconds > 0
        ? (run.inferenceMilliseconds / 1_000) / run.audioDurationSeconds
        : 0
    )
  }

  public static func normalized(_ text: String) -> String {
    text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
      .unicodeScalars
      .map { CharacterSet.alphanumerics.contains($0) ? Character(String($0)) : " " }
      .reduce(into: "") { $0.append($1) }
      .split(whereSeparator: \Character.isWhitespace)
      .joined(separator: " ")
  }

  public static func words(_ text: String) -> [String] {
    normalized(text).split(separator: " ").map(String.init)
  }

  public static func editDistance<T: Equatable>(_ left: [T], _ right: [T]) -> Int {
    guard !left.isEmpty else { return right.count }
    guard !right.isEmpty else { return left.count }

    var previous = Array(0...right.count)
    for (leftIndex, leftItem) in left.enumerated() {
      var current = Array(repeating: 0, count: right.count + 1)
      current[0] = leftIndex + 1
      for (rightIndex, rightItem) in right.enumerated() {
        current[rightIndex + 1] = min(
          current[rightIndex] + 1,
          previous[rightIndex + 1] + 1,
          previous[rightIndex] + (leftItem == rightItem ? 0 : 1)
        )
      }
      previous = current
    }
    return previous[right.count]
  }

  private static func containsTerm(_ term: String, in normalizedText: String) -> Bool {
    let value = normalized(term)
    return " \(normalizedText) ".contains(" \(value) ")
  }

  private static func commonPrefixLength(_ left: String, _ right: String) -> Int {
    zip(left, right).prefix(while: ==).count
  }
}
