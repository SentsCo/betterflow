// swift-tools-version: 6.1

import PackageDescription

let package = Package(
  name: "Betterflow",
  platforms: [.macOS(.v14)],
  products: [
    .library(name: "BetterflowBenchmarkCore", targets: ["BetterflowBenchmarkCore"]),
    .library(name: "BetterflowEngine", targets: ["BetterflowEngine"]),
    .executable(name: "betterflow-bench", targets: ["BetterflowBench"]),
    .executable(name: "Betterflow", targets: ["BetterflowApp"]),
  ],
  dependencies: [
    .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
    .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.15.6"),
    .package(url: "https://github.com/moonshine-ai/moonshine-swift.git", from: "0.1.3"),
    .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", from: "1.1.0"),
    .package(
      url: "https://github.com/ml-explore/mlx-swift-lm.git",
      from: "3.31.3"
    ),
    .package(url: "https://github.com/ml-explore/mlx-swift.git", from: "0.31.1"),
    .package(url: "https://github.com/huggingface/swift-huggingface.git", from: "0.9.0"),
    .package(url: "https://github.com/huggingface/swift-transformers.git", from: "1.3.0"),
    .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.9.6"),
  ],
  targets: [
    .target(name: "BetterflowBenchmarkCore"),
    .target(
      name: "BetterflowEngine",
      dependencies: [
        "BetterflowBenchmarkCore",
        .product(name: "FluidAudio", package: "FluidAudio"),
        .product(name: "MoonshineVoice", package: "moonshine-swift"),
        .product(name: "WhisperKit", package: "argmax-oss-swift"),
      ],
      resources: [.process("Resources")]
    ),
    .executableTarget(
      name: "BetterflowBench",
      dependencies: [
        "BetterflowBenchmarkCore",
        "BetterflowEngine",
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
      ]
    ),
    .executableTarget(
      name: "BetterflowApp",
      dependencies: [
        "BetterflowBenchmarkCore",
        "BetterflowEngine",
        .product(name: "MLXLLM", package: "mlx-swift-lm"),
        .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
        .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
        .product(name: "MLX", package: "mlx-swift"),
        .product(name: "HuggingFace", package: "swift-huggingface"),
        .product(name: "Tokenizers", package: "swift-transformers"),
        .product(name: "Sparkle", package: "Sparkle"),
      ]
    ),
    .testTarget(
      name: "BetterflowBenchmarkCoreTests",
      dependencies: ["BetterflowBenchmarkCore"]
    ),
    .testTarget(
      name: "BetterflowAppTests",
      dependencies: ["BetterflowApp"]
    ),
  ]
)
