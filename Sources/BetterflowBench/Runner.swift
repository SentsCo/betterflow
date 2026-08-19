import BetterflowBenchmarkCore
import BetterflowEngine
import Foundation

struct BenchmarkRunner {
  let manifestURL: URL
  let models: [BenchmarkModel]
  let cadenceMilliseconds: Double
  let realtime: Bool

  func run() async throws -> BenchmarkReport {
    let data = try Data(contentsOf: manifestURL)
    let manifest = try JSONDecoder().decode(BenchmarkManifest.self, from: data)
    guard !manifest.guideWords.isEmpty else {
      throw BenchmarkError.invalidManifest("The manifest must contain guideWords.")
    }
    guard !manifest.cases.isEmpty else {
      throw BenchmarkError.invalidManifest("The manifest must contain at least one case.")
    }

    var scoredRuns: [ScoredRun] = []
    var failures: [BenchmarkFailure] = []
    for model in models {
      print("\nPreparing \(model.rawValue)…")
      let adapter = AdapterFactory.make(model)
      let loadStart = ContinuousClock.now
      do {
        try await adapter.prepare(guideWords: manifest.guideWords)
      } catch {
        let failure = BenchmarkFailure(
          model: model,
          stage: "prepare",
          message: error.localizedDescription
        )
        failures.append(failure)
        print("Unavailable: \(failure.message)")
        await adapter.close()
        continue
      }
      let loadMilliseconds = loadStart.duration(to: .now).milliseconds
      print(String(format: "Loaded in %.0f ms", loadMilliseconds))

      for benchmarkCase in manifest.cases {
        let audioURL = resolveAudio(benchmarkCase.audio)
        let audio = try AudioIO.load(url: audioURL)
        let guidanceModes: [GuidanceMode] = model.supportsGuidance ? [.off, .on] : [.off]
        for guidance in guidanceModes {
          print("\n[\(model.shortName)] [\(guidance.rawValue)] \(benchmarkCase.id)")
          do {
            let output = try await adapter.transcribe(
              audio: audio,
              guidance: guidance,
              cadenceMilliseconds: cadenceMilliseconds,
              realtime: realtime
            ) { event in
              let marker = event.isFinal ? "final" : "live "
              print(
                String(format: "  %@ %7.0f ms  %@", marker, event.elapsedMilliseconds, event.text))
            }
            let run = EngineRun(
              model: model,
              guidance: guidance,
              caseID: benchmarkCase.id,
              reference: benchmarkCase.reference,
              guideWords: manifest.guideWords,
              guidanceMechanism: output.guidanceMechanism,
              audioDurationSeconds: audio.durationSeconds,
              speechStartSeconds: audio.speechStartSeconds,
              modelLoadMilliseconds: loadMilliseconds,
              inferenceMilliseconds: output.inferenceMilliseconds,
              peakResidentMegabytes: Memory.residentMegabytes,
              events: output.events
            )
            let scored = ScoredRun(run: run, metrics: try Metrics.score(run))
            scoredRuns.append(scored)
            print(
              String(
                format: "  WER %.1f%% · guide %@ · first %@ · revisions %d · compute RTF %.2f",
                scored.metrics.wordErrorRate * 100,
                scored.metrics.guideWordRecall.map { String(format: "%.0f%%", $0 * 100) } ?? "n/a",
                scored.metrics.firstTextLatencyMilliseconds.map { String(format: "%.0f ms", $0) }
                  ?? "n/a",
                scored.metrics.revisions,
                scored.metrics.computeRealTimeFactor
              )
            )
          } catch {
            let failure = BenchmarkFailure(
              model: model,
              guidance: guidance,
              caseID: benchmarkCase.id,
              stage: "transcribe",
              message: error.localizedDescription
            )
            failures.append(failure)
            print("  Failed: \(failure.message)")
          }
        }
      }
      await adapter.close()
    }

    return BenchmarkReport(
      generatedAt: Date(),
      host: hostDescription(),
      cadenceMilliseconds: cadenceMilliseconds,
      realtimePacing: realtime,
      runs: scoredRuns,
      failures: failures
    )
  }

  private func resolveAudio(_ path: String) -> URL {
    if NSString(string: path).isAbsolutePath {
      return URL(fileURLWithPath: path)
    }
    return manifestURL.deletingLastPathComponent().appendingPathComponent(path)
  }

  private func hostDescription() -> String {
    "\(ProcessInfo.processInfo.operatingSystemVersionString); \(ProcessInfo.processInfo.processorCount) logical cores"
  }
}
