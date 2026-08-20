# Betterflow

Native macOS voice dictation with local models, a live self-correcting transcript, guide words, and optional on-device cleanup.

## Features

- Press the configurable key once to start recording and again to finish.
- See the transcript revise itself live before insertion.
- Choose from nine local or Apple-managed engines with model-native guide words.
- Optionally clean up transcripts on-device with Apple Foundation Models or Qwen3 0.6B.
- Keep history, fall back to the clipboard, and configure a persistent microphone priority list.

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

The repository also includes `betterflow-bench` for comparing recognition engines. Model downloads and results stay outside Git.
