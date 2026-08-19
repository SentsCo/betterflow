# Betterflow

Betterflow is a native macOS push-to-talk dictation app with a live, self-correcting transcript bubble. Hold Right Control, speak, watch the selected model revise its hypothesis, and release to insert the final text once into the focused app.

## Build and run the app

Requirements: Apple Silicon, macOS 14 or newer, and Xcode 16 or newer.

Qwen cleanup also requires Apple's Metal Toolchain component. Install it once with
`xcodebuild -downloadComponent MetalToolchain`; the app packaging script then builds and
embeds MLX's shader library automatically.

```sh
Scripts/build-app.sh
open dist/Betterflow.app
```

The packaging script uses the first available Apple Development signing identity so macOS permission grants remain attached across local rebuilds. Set `BETTERFLOW_SIGNING_IDENTITY` to select a different identity; without one it falls back to ad-hoc signing.

Betterflow lives in the menu bar. On first launch it opens Settings so macOS can grant Microphone and Accessibility access. Accessibility authorizes both final text insertion and the global push-to-talk monitor. The push-to-talk key is configurable; the first-run default is specifically **Right Control**, not either Control key.

The app includes:

- a non-activating floating bubble that displays replacement transcript snapshots;
- final-only Accessibility insertion, with Unicode keyboard-event fallback;
- model-native guide words—never transcript search-and-replace;
- all nine local model adapters in the Models setting;
- a system-default microphone mode and an optional ordered device-priority list;
- model prewarming, launch-at-login, permission status, and actionable errors;
- optional on-device transcript cleanup with Apple Foundation Models or Qwen3 0.6B 4-bit;
- per-dictation cleanup toggling with `Z`, with the original transcript retained in history;
- the benchmark CLI, using the exact same recognition-engine library as the app.

```text
Right Control down → chosen microphone → revisable model snapshot → floating bubble
Right Control up   → final recognition → focused text field (one insertion)
```

The app defaults to Moonshine Small Streaming. Append-only models remain selectable for comparison, but Settings labels them as ineligible for Betterflow's self-correction requirement.

## Local model lab

The four strongest original candidates run by default in the benchmark. Five additional engines remain available explicitly so speed, guidance, and revision assumptions can be tested instead of argued from model cards.

## Model catalog

| Tier | CLI name | Engine | Live revision strategy | Model-level guide mechanism |
|---|---|---|---|---|
| Default | `parakeet` | Parakeet TDT-CTC 110M / FluidAudio | Re-decodes the growing utterance | CTC acoustic keyword spotting and constrained rescoring |
| Default | `moonshine-small` | Moonshine Small Streaming | Native mutable streaming lines | Decoder keyterms |
| Default | `moonshine-medium` | Moonshine Medium Streaming | Native mutable streaming lines | Decoder keyterms |
| Default | `whisper` | Whisper Large v3 Turbo / WhisperKit | Re-decodes the growing utterance | Whisper prompt tokens |
| Optional | `apple-speech` | Apple SpeechTranscriber | Native volatile results | `AnalysisContext` contextual strings |
| Optional | `apple-dictation` | Apple DictationTranscriber | Native volatile results | `AnalysisContext` contextual strings |
| Optional | `parakeet-eou` | Parakeet EOU 120M / FluidAudio | Append-only stream | None |
| Optional | `nemotron` | Nemotron Streaming 0.6B / FluidAudio | Append-only stream | None |
| Optional | `qwen` | Qwen3-ASR 0.6B 8-bit / MLX Audio | Re-decodes the growing utterance | Model system prompt |

Append-only models cannot satisfy Betterflow's self-correction requirement, but they are useful speed controls. The runner labels their capabilities and skips the meaningless guidance-on pass.

Both Apple adapters require macOS 26 or newer. `apple-speech` exercises Apple's newer on-device model; `apple-dictation` exercises the dictation/Siri-lineage model through the same current streaming API. Qwen is fully local but launches an optional persistent Python/MLX worker and fails after a bounded startup timeout if that runtime stalls.

## What the benchmark measures

Every guidance-capable model runs each recording twice: guidance off, then guidance on. Append-only controls run once because they expose no guide interface. The default guide terms are `Zach`, `Sara`, `WorkflowDog`, `TanStack`, and `Postgres`.

The JSON and Markdown reports include:

- final word error rate;
- guide-word recall and false guide insertions;
- speech-to-first-text latency;
- end-of-audio-to-final-text latency;
- number of visible revisions and characters revised;
- inference compute real-time factor;
- model load time and resident memory;
- every intermediate hypothesis, with wall-clock and audio timestamps.

No benchmark adapter performs a string replacement. Guidance is passed to the decoder or acoustic rescoring implementation exposed by that engine.

## Build and use the benchmark

Requirements: Apple Silicon, macOS 14 or newer, and Xcode 16 or newer.

```sh
swift build -c release

# Required before running MLX/Qwen from a command-line SwiftPM build
Scripts/prepare-mlx.sh release

# See model details
.build/release/betterflow-bench models

# Download and warm the recommended engines
.build/release/betterflow-bench prepare

# Generate deterministic TTS files for a plumbing smoke test
.build/release/betterflow-bench fixtures

# Validate an audio file before a long model run
.build/release/betterflow-bench inspect-audio Benchmarks/audio/guided-terms.aiff

# Run guided and unguided trials at wall-clock speed
.build/release/betterflow-bench run
```

Optional engines never join a no-argument run. Select them by name, or deliberately request the entire catalog:

```sh
.build/release/betterflow-bench prepare --models apple-speech apple-dictation
.build/release/betterflow-bench run --models parakeet apple-speech apple-dictation
.build/release/betterflow-bench run --models all
```

An unavailable optional runtime is recorded in `report.json` and `report.md`; the remaining selected engines continue. `--models all` can trigger several large model downloads and Qwen's Python environment setup.

Select one or more models and change the visible update cadence:

```sh
.build/release/betterflow-bench run \
  --models parakeet moonshine-small moonshine-medium \
  --cadence 500 \
  --manifest Benchmarks/manifest.json \
  --output Benchmarks/results/local
```

Use `--unpaced` only for throughput testing. It feeds audio as quickly as inference permits; latency numbers from an unpaced run are not user-perceived latency.

## Record real fixtures

Synthetic voices are useful for checking the harness, not for choosing a model. Record natural speech, hesitations, corrections, background noise, and multiple microphones:

```sh
.build/release/betterflow-bench record \
  --output Benchmarks/audio/zach-guide-terms.caf
```

Add the audio path and exact reference transcript to `Benchmarks/manifest.json`. Include both guide-heavy cases and negative controls that contain none of the guide terms.

## macOS architecture

The app is native Swift. SwiftUI owns settings and menu content, while AppKit owns the non-activating floating panel, global push-to-talk input, Accessibility insertion, and application focus handling. Core Audio captures from the system-default input unless an optional ordered microphone policy selects the first available preferred device.

Recognition should emit replacement snapshots, not append operations:

```text
audio frames → selected local engine → mutable transcript snapshot → overlay
                                            │
push-to-talk released ──────────────────────┴→ final snapshot → insert once
```

The bubble replaces its displayed hypothesis as the model revises it and inserts only the final snapshot into the focused app. This keeps revisions visible without repeatedly modifying the destination document.

Guide terms belong in a shared semantic configuration (`preferred spelling`, optional spoken aliases, scope), but each engine adapter must translate that configuration into its model-native bias mechanism. The insertion layer never applies those aliases as replacements.

## Current benchmark caveats

- Model downloads are cached outside the repository by their respective runtimes.
- Moonshine's Swift binary dependency is currently large before its language model download.
- Qwen3-ASR 0.6B previously took minutes in older MLX experiments. The current pinned 8-bit `mlx-audio` worker loaded in about one second from cache and sustained roughly 0.28 compute RTF in the synthetic live-cadence smoke test, so it is now a serious candidate. It remains optional until natural-speech results justify taking on the Python runtime, and retains a 120-second timeout.
- Apple's model assets are installed and updated by macOS. Record the macOS build in comparisons because the underlying Apple model can change independently of this package.
- Re-decoding a growing prefix proves revision behavior but may fall behind real time. That is a result the bake-off is designed to expose.
- FluidAudio CTC vocabulary rescoring is acoustically grounded, but requires conservative similarity thresholds and negative-control recordings to prevent over-biasing.
