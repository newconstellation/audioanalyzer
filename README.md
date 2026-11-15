# Acoustic Studio Tools

A native real-time audio measurement app for current macOS (Apple Silicon
and Intel), written in Swift with CoreAudio, Accelerate and SwiftUI.

**Status:** early, not yet tested on real hardware. Working: level meters,
FFT spectrum, fractional-octave bands, SPL meter with calibrator, multi-input
averaging, dual-channel transfer function (magnitude, phase, coherence, polar
phase, delay finder), impulse response and decay waterfall, THD / THD+N,
oscilloscope, vectorscope, spectrogram, histories, signal generator, file
analysis and capture. Planned: bit meters, presets and more.

## Layout

| Path | What |
|---|---|
| `Sources/AnalysisCore` | DSP library: level meter (peak, RMS, VU, PPM, overs), FFT spectrum up to 64k points, windows, averaging, correlation and balance, transfer function (H1, coherence, GCC-PHAT delay), THD / THD+N / harmonics |
| `Sources/AnalyzerUI` | SwiftUI views for the instruments |
| `Sources/AnalyzerApp` | The app: live input from the default audio device |
| `Sources/RenderSnapshot` | Renders each page of the window with synthetic signals to PNGs (used in CI) |
| `Tests/AnalysisCoreTests` | Unit tests against synthetic signals |
| `tools/testsignals` | Generates reference WAV test signals (`python3 generate.py OUT_DIR`, needs numpy) |

## Build and run

Needs Xcode 16 or later on macOS 14+.

```sh
swift test             # run the DSP tests
swift run AnalyzerApp  # run the app
swift run RenderSnapshot out_dir
```

Running from Terminal, macOS asks for microphone access for Terminal the
first time. Choose the input device on the Inputs page.

## App bundle

```sh
tools/package/package-app.sh dist 0.1.0
```

builds `dist/Acoustic Studio Tools.app` (universal: Apple Silicon and Intel, macOS 14+) and a zip of it.
CI does the same on every push and pull request and uploads the zip as the
`AcousticStudioTools-app` artifact. The app is ad-hoc signed, not notarized: the
first time, right-click it and choose Open (or run
`xattr -dr com.apple.quarantine "Acoustic Studio Tools.app"`).
