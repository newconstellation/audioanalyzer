import AnalysisCore
import AnalyzerUI
import AppKit
import SwiftUI

/// Renders the analyzer window with a synthetic test signal to a PNG, so the
/// UI can be checked on a machine with no audio input (for example CI).
///
///     swift run RenderSnapshot out.png
@main
struct RenderSnapshot {
    @MainActor
    static func main() throws {
        let path = CommandLine.arguments.dropFirst().first ?? "snapshot.png"
        let snapshot = analyseTestSignal()

        // ImageRenderer draws the SwiftUI view directly, with no window or
        // window server, so it can't hang on a headless CI machine.
        let content = AnalyzerView(snapshot: snapshot)
            .frame(width: 900, height: 460)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        guard let cg = renderer.cgImage else { throw CocoaError(.fileWriteUnknown) }
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try png.write(to: URL(fileURLWithPath: path))
        print("wrote \(path) (\(rep.pixelsWide)x\(rep.pixelsHigh))")
    }

    /// 3 s of stereo: pink noise at -26 dBFS RMS plus tones at 100 Hz (-18 dBFS)
    /// and 1 kHz (-12 dBFS). The right channel is 80% left plus its own noise,
    /// so correlation sits around +0.8.
    static func analyseTestSignal() -> AnalyzerSnapshot {
        let fs = 48_000.0
        let n = Int(3 * fs)
        var rng = SplitMix64(seed: 20261105)
        var pinkL = PinkNoise(), pinkR = PinkNoise()
        var left = [Float](repeating: 0, count: n)
        var right = [Float](repeating: 0, count: n)
        let noiseGain = dbToAmplitude(-26) / 0.15 // the pink filter's output RMS is about 0.15
        for i in 0..<n {
            let t = Double(i) / fs
            let tones = dbToAmplitude(-12) * sin(2 * .pi * 1000 * t) + dbToAmplitude(-18) * sin(2 * .pi * 100 * t)
            let l = tones + noiseGain * pinkL.next(rng.nextGaussian())
            let own = noiseGain * pinkR.next(rng.nextGaussian())
            left[i] = Float(l)
            right[i] = Float(0.8 * l + 0.45 * own)
        }
        let engine = AnalysisEngine(sampleRate: fs, channelCount: 2)
        left.withUnsafeBufferPointer { lp in
            right.withUnsafeBufferPointer { rp in
                var i = 0
                while i < n {
                    let len = min(1024, n - i)
                    engine.process(channels: [lp.baseAddress! + i, rp.baseAddress! + i], frameCount: len)
                    i += len
                }
            }
        }
        return engine.snapshot
    }
}

/// Paul Kellet's economy pink filter (-3 dB/octave from white noise).
struct PinkNoise {
    private var b0 = 0.0, b1 = 0.0, b2 = 0.0
    mutating func next(_ white: Double) -> Double {
        b0 = 0.99765 * b0 + white * 0.0990460
        b1 = 0.96300 * b1 + white * 0.2965164
        b2 = 0.57000 * b2 + white * 1.0526913
        return (b0 + b1 + b2 + white * 0.1848) * 0.05
    }
}

struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func nextUniform() -> Double { Double(next() >> 11) / Double(1 << 53) }
    mutating func nextGaussian() -> Double {
        let u1 = max(nextUniform(), 1e-300), u2 = nextUniform()
        return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }
}
