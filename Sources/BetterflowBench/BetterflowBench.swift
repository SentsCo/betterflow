import ArgumentParser
import BetterflowBenchmarkCore
import BetterflowEngine
import Foundation

@main
struct BetterflowBench: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "betterflow-bench",
    abstract: "Benchmark local-first speech recognition on Apple Silicon.",
    subcommands: [
      Models.self, Fixtures.self, InspectAudio.self, Record.self, Prepare.self, Run.self,
    ],
    defaultSubcommand: Models.self
  )
}

extension BetterflowBench {
  struct Models: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Show every available benchmark engine.")

    func run() {
      print("RECOMMENDED DEFAULTS")
      BenchmarkModel.recommendedCases.forEach(printModel)
      print("\nOPTIONAL LAB ENGINES")
      BenchmarkModel.allCases.filter { !$0.isRecommended }.forEach(printModel)
      print(
        "\nNo --models option runs the recommended defaults. Use --models all explicitly for every engine."
      )
    }
  }

  struct Fixtures: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Generate deterministic macOS TTS smoke-test audio and a manifest."
    )

    @Option(name: .long, help: "Benchmark directory.")
    var directory = "Benchmarks"

    func run() throws {
      let url = URL(fileURLWithPath: directory, isDirectory: true)
      let manifest = try FixtureGenerator.generate(at: url)
      print("Generated smoke fixtures and \(manifest.path)")
      print("Use real recordings for model selection; synthetic speech is only a plumbing check.")
    }
  }

  struct Record: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Record a real microphone fixture.")

    @Option(name: .long, help: "Output audio file (.caf recommended).")
    var output: String

    @Option(name: .long, help: "Stop automatically after this many seconds.")
    var seconds: Double?

    func run() async throws {
      try await Recorder.record(to: URL(fileURLWithPath: output), seconds: seconds)
      print("Saved \(URL(fileURLWithPath: output).path)")
    }
  }

  struct InspectAudio: ParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "inspect-audio",
      abstract: "Validate and summarize an audio fixture."
    )

    @Argument(help: "Path to an audio file.")
    var path: String

    func run() throws {
      let audio = try AudioIO.load(url: URL(fileURLWithPath: path))
      print(
        String(
          format: "%.3f s · %.0f Hz · %d samples · speech starts %.3f s",
          audio.durationSeconds, audio.sampleRate, audio.samples.count, audio.speechStartSeconds))
    }
  }

  struct Prepare: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Download and warm selected models.")

    @Option(
      name: .long, parsing: .upToNextOption,
      help: "Model names, comma-separated names, or all. Defaults to the recommended four.")
    var models: [String] = []

    func run() async throws {
      let selected = try parseModels(models)
      let guideWords = ["Zach", "Sara", "WorkflowDog", "TanStack", "Postgres"]
      for model in selected {
        print("Preparing \(model.rawValue)…")
        let adapter = AdapterFactory.make(model)
        do {
          try await adapter.prepare(guideWords: guideWords)
          print("Ready: \(model.rawValue)")
        } catch {
          print("Unavailable: \(model.rawValue) — \(error.localizedDescription)")
        }
        await adapter.close()
      }
    }
  }

  struct Run: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Run guided and unguided real-time trials.")

    @Option(name: .long, help: "Path to the benchmark manifest.")
    var manifest = "Benchmarks/manifest.json"

    @Option(
      name: .long, parsing: .upToNextOption,
      help: "Model names, comma-separated names, or all. Defaults to the recommended four.")
    var models: [String] = []

    @Option(name: .long, help: "Milliseconds of new audio per visible update.")
    var cadence: Double = 750

    @Flag(name: .long, help: "Skip wall-clock input pacing to measure throughput only.")
    var unpaced = false

    @Option(name: .long, help: "Directory for report.json and report.md.")
    var output = "Benchmarks/results/latest"

    func validate() throws {
      guard cadence >= 100 else { throw ValidationError("--cadence must be at least 100 ms.") }
    }

    func run() async throws {
      let selected = try parseModels(models)
      let report = try await BenchmarkRunner(
        manifestURL: URL(fileURLWithPath: manifest),
        models: selected,
        cadenceMilliseconds: cadence,
        realtime: !unpaced
      ).run()
      let files = try ReportWriter.write(report, directory: URL(fileURLWithPath: output))
      if !report.failures.isEmpty {
        print("\nCompleted with \(report.failures.count) unavailable or failed trial(s).")
      }
      print("\nJSON: \(files.json.path)")
      print("Markdown: \(files.markdown.path)")
    }
  }
}

private func parseModels(_ values: [String]) throws -> [BenchmarkModel] {
  if values.isEmpty { return BenchmarkModel.recommendedCases }
  let names = values.flatMap { $0.split(separator: ",").map(String.init) }
  if names.contains("all") {
    guard names == ["all"] else {
      throw ValidationError("Use --models all by itself.")
    }
    return BenchmarkModel.allCases
  }
  let parsed = try names.map { try BenchmarkModel.parse($0) }
  return parsed.reduce(into: []) { models, model in
    if !models.contains(model) { models.append(model) }
  }
}

private func printModel(_ model: BenchmarkModel) {
  print(
    """
      \(model.shortName)  \(model.displayName)
        revisions: \(model.supportsRevisions ? "yes" : "no") (\(model.revisionStrategy))
        guidance:  \(model.supportsGuidance ? "yes" : "no") (\(model.guidanceMechanism))
        requires:  \(model.requirements)
    """)
}
