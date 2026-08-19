import Testing

@testable import BetterflowBenchmarkCore

@Test func wordErrorRateAndGuideRecall() throws {
  let run = EngineRun(
    model: .parakeet,
    guidance: .on,
    caseID: "guide",
    reference: "Zach uses TanStack with Postgres",
    guideWords: ["Zach", "Sara", "TanStack", "Postgres"],
    guidanceMechanism: "test",
    audioDurationSeconds: 2,
    speechStartSeconds: 0.1,
    modelLoadMilliseconds: 10,
    inferenceMilliseconds: 200,
    peakResidentMegabytes: nil,
    events: [
      HypothesisEvent(
        elapsedMilliseconds: 600, audioMilliseconds: 500, text: "Zack uses tan stack",
        isFinal: false),
      HypothesisEvent(
        elapsedMilliseconds: 2_100, audioMilliseconds: 2_000,
        text: "Zach uses TanStack with Postgres", isFinal: true),
    ]
  )

  let metrics = try Metrics.score(run)
  #expect(metrics.wordErrorRate == 0)
  #expect(metrics.guideWordRecall == 1)
  #expect(metrics.guideWordHits == 3)
  #expect(metrics.guideWordFalsePositives == 0)
  #expect(metrics.revisions == 1)
  #expect(metrics.firstTextLatencyMilliseconds == 500)
  #expect(metrics.finalizationLatencyMilliseconds == 100)
}

@Test func levenshteinDistance() {
  #expect(Metrics.editDistance(["a", "b", "c"], ["a", "x", "c", "d"]) == 2)
  #expect(Metrics.editDistance([String](), ["a"]) == 1)
}
