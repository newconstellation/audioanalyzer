# Audio Analyzer

A native real-time audio measurement app for current macOS (Apple Silicon
and Intel), written in Swift with CoreAudio, Accelerate and SwiftUI.

**Status:** early. Level meters, FFT spectrum and stereo correlation work.
More instruments are planned: waterfall, oscilloscope, vectorscope,
correlation and power histories, phase vs frequency, transfer function and a
signal generator.

## Layout

| Path | What |
|---|---|
| `Sources/AnalysisCore` | DSP library: level meter (peak, RMS, VU, PPM, overs), FFT spectrum up to 64k points, windows, averaging, correlation and balance |
| `Sources/AnalyzerUI` | SwiftUI views for the instruments |
| `Sources/AnalyzerApp` | The app: live input from the default audio device |
| `Sources/RenderSnapshot` | Renders the window with a synthetic signal to a PNG (used in CI) |
| `Tests/AnalysisCoreTests` | Unit tests against synthetic signals |
| `tools/testsignals` | Generates reference WAV test signals (`python3 generate.py OUT_DIR`, needs numpy) |

## Build and run

Needs Xcode 16 or later on macOS 14+.

```sh
swift test             # run the DSP tests
swift run AnalyzerApp  # run the app
swift run RenderSnapshot out.png
```

Running from Terminal, macOS asks for microphone access for Terminal the
first time. Choose the input device in System Settings > Sound > Input.
