# Betterflow

Native macOS voice dictation and annotated screenshots.

[Download the latest release](https://github.com/zachsents/betterflow/releases/latest). Betterflow requires Apple Silicon and macOS 14 or newer. Updates are delivered through Sparkle.

## Features

- Press the configurable key once to start recording and again to finish.
- See the transcript revise itself live before insertion.
- Choose from nine local or Apple-managed engines with model-native guide words.
- Optionally clean up transcripts on-device with Apple Foundation Models or Qwen3 0.6B.
- Keep history, fall back to the clipboard, and configure a persistent microphone priority list.
- Draw over a frozen desktop, then copy a selected area or full display to the clipboard.

## Build

Requires Apple Silicon, macOS 14 or newer, and Xcode 16 or newer.

```sh
Scripts/build-app.sh
open dist/Betterflow.app
```

Qwen cleanup also requires `xcodebuild -downloadComponent MetalToolchain`.

On first launch, grant Microphone and Accessibility access. Betterflow then runs from the menu bar. The default dictation key is Right Control.

## Controls

- `Enter`: finish and insert; press again while finalizing to send afterward
- `Command-Enter`: immediately insert the current transcript
- `Escape`: cancel
- `Z`: toggle cleanup for the current transcription
- `Command-Shift-2`: annotate a screenshot
- In screenshot mode: `P` selects pen, `A` arrow, `R` rectangle, `T` comment, `Return` selects an area (or copies the display if already selecting), `Command-Return` copies the display, `Command-Z` undoes, and `Escape` cancels
- While editing a comment: `Return` commits, `Shift-Return` adds a line break, and `Escape` discards it

The repository also includes `betterflow-bench` for comparing recognition engines. Model downloads and results stay outside Git.

## Release

Push a semantic version tag such as `v1.0.0`. The Blacksmith macOS workflow builds, signs, notarizes, and publishes the DMG, ZIP, checksums, and Sparkle appcast. Required repository secrets are documented in [RELEASING.md](RELEASING.md).
