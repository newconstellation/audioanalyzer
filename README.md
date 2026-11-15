# Audio Analyzer

A native real-time audio measurement app for current macOS (Apple Silicon
and Intel), written in Swift with CoreAudio, Accelerate and SwiftUI.

**Status:** early. Working: level meters, FFT spectrum, stereo correlation,
dual-channel transfer function (magnitude, phase, coherence, delay finder),
THD / THD+N analysis, and a signal generator (9 tones with sweeps, white and
pink noise, bursts, TPDF dither, FFT-synchronous tones; plays to the output
device or loops back internally). Planned: waterfall, oscilloscope,
vectorscope, histories, phase vs frequency, bit meters, capture and offline
analysis.

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

builds `dist/Audio Analyzer.app` (Apple Silicon, macOS 14+) and a zip of it.
CI does the same on every push and pull request and uploads the zip as the
`AudioAnalyzer-app` artifact. The app is ad-hoc signed, not notarized: the
first time, right-click it and choose Open (or run
`xattr -dr com.apple.quarantine "Audio Analyzer.app"`).
