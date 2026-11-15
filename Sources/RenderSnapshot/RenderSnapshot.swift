import AnalysisCore
import AnalyzerUI
import AppKit
import SwiftUI

/// Renders each page of the analyzer window, fed with a synthetic test
/// signal, to PNGs, so the UI can be checked on a machine with no audio input
/// (for example CI).
///
///     swift run RenderSnapshot OUTPUT_DIR
@main
struct RenderSnapshot {
    static let fs = 48_000.0

    @MainActor
    static func main() throws {
        let dir = CommandLine.arguments.dropFirst().first ?? "."
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let pages: [(InstrumentPage, String, AnalyzerSnapshot)] = [
            (.meters, "meters", analyse(metersSignal())),
            (.transferFunction, "transfer-function", analyse(transferSignal(), findDelay: true)),
            (.distortion, "thd", analyse(distortionSignal())),
        ]
        for (page, name, snapshot) in pages {
            let path = (dir as NSString).appendingPathComponent("\(name).png")
            try render(AnalyzerView(snapshot: snapshot, page: page), to: path)
        }
    }

    /// ImageRenderer draws the SwiftUI view directly, with no window or
    /// window server, so it can't hang on a headless CI machine.
    @MainActor
    static func render(_ view: AnalyzerView, to path: String) throws {
        let renderer = ImageRenderer(content: view.frame(width: 1000, height: 640))
        renderer.scale = 2
        guard let cg = renderer.cgImage,
              let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
        else { throw CocoaError(.fileWriteUnknown) }
        try png.write(to: URL(fileURLWithPath: path))
        print("wrote \(path) (\(cg.width)x\(cg.height))")
    }

    static func analyse(_ signal: (left: [Float], right: [Float]), findDelay: Bool = false) -> AnalyzerSnapshot {
        let engine = AnalysisEngine(sampleRate: fs, channelCount: 2)
        func feed() {
            signal.left.withUnsafeBufferPointer { lp in
                signal.right.withUnsafeBufferPointer { rp in
                    var i = 0
                    while i < signal.left.count {
                        let len = min(1024, signal.left.count - i)
                        engine.process(channels: [lp.baseAddress! + i, rp.baseAddress! + i], frameCount: len)
                        i += len
                    }
                }
            }
        }
        feed()
        if findDelay {
            engine.findAndApplyDelay()
            feed()
        }
        return engine.snapshot
    }

    /// 3 s of stereo: pink noise at -26 dBFS RMS plus tones at 100 Hz (-18 dBFS)
    /// and 1 kHz (-12 dBFS). The right channel is 80% left plus its own noise.
    static func metersSignal() -> (left: [Float], right: [Float]) {
        let n = Int(3 * fs)
        var rng = SplitMix64(seed: 20261105)
        var pinkL = PinkNoise(), pinkR = PinkNoise()
        var left = [Float](repeating: 0, count: n), right = left
        let noiseGain = dbToAmplitude(-26) / 0.15 // the pink filter's output RMS is about 0.15
        for i in 0..<n {
            let t = Double(i) / fs
            let tones = dbToAmplitude(-12) * sin(2 * .pi * 1000 * t) + dbToAmplitude(-18) * sin(2 * .pi * 100 * t)
            let l = tones + noiseGain * pinkL.next(rng.nextGaussian())
            left[i] = Float(l)
            right[i] = Float(0.8 * l + 0.45 * noiseGain * pinkR.next(rng.nextGaussian()))
        }
        return (left, right)
    }

    /// A "device under test": pink noise through an 80 Hz high-pass, a +6 dB
    /// bell at 1 kHz and a -4 dB high shelf at 8 kHz, 2.5 ms of latency, and a
    /// little added noise (so coherence drops where the source is weak).
    static func transferSignal() -> (left: [Float], right: [Float]) {
        let n = Int(6 * fs)
        var rng = SplitMix64(seed: 7)
        var pink = PinkNoise()
        let source = (0..<n).map { _ in dbToAmplitude(-20) / 0.15 * pink.next(rng.nextGaussian()) }
        var hp = Biquad.highPass(f: 80, q: 0.707, fs: fs)
        var bell = Biquad.peaking(f: 1000, q: 1.4, gainDB: 6, fs: fs)
        var shelf = Biquad.highShelf(f: 8000, gainDB: -4, fs: fs)
        let latency = Int(0.0025 * fs)
        var response = [Double](repeating: 0, count: n)
        for i in 0..<n {
            let x = i >= latency ? source[i - latency] : 0
            response[i] = shelf.process(bell.process(hp.process(x))) + dbToAmplitude(-70) * rng.nextGaussian()
        }
        return (source.map(Float.init), response.map(Float.init))
    }

    /// 1 kHz at -6 dBFS through a gently asymmetric soft clipper, plus noise
    /// at -110 dBFS: a mix of odd and even harmonics.
    static func distortionSignal() -> (left: [Float], right: [Float]) {
        let n = Int(2 * fs)
        var rng = SplitMix64(seed: 11)
        let drive = 1.2
        let out: [Float] = (0..<n).map { i in
            let x = dbToAmplitude(-6) * sin(2 * .pi * 1000 * Double(i) / fs)
            let y = tanh(drive * x) / drive + 0.002 * x * x
            return Float(y + dbToAmplitude(-110) * rng.nextGaussian())
        }
        return (out, out)
    }
}

/// RBJ cookbook biquad, transposed direct form II.
struct Biquad {
    var b0, b1, b2, a1, a2: Double
    var z1 = 0.0, z2 = 0.0

    mutating func process(_ x: Double) -> Double {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }

    private static func make(_ b: (Double, Double, Double), _ a: (Double, Double, Double)) -> Biquad {
        Biquad(b0: b.0 / a.0, b1: b.1 / a.0, b2: b.2 / a.0, a1: a.1 / a.0, a2: a.2 / a.0)
    }

    static func highPass(f: Double, q: Double, fs: Double) -> Biquad {
        let w = 2 * .pi * f / fs, alpha = sin(w) / (2 * q), c = cos(w)
        return make(((1 + c) / 2, -(1 + c), (1 + c) / 2), (1 + alpha, -2 * c, 1 - alpha))
    }

    static func peaking(f: Double, q: Double, gainDB: Double, fs: Double) -> Biquad {
        let a = pow(10, gainDB / 40), w = 2 * .pi * f / fs, alpha = sin(w) / (2 * q), c = cos(w)
        return make((1 + alpha * a, -2 * c, 1 - alpha * a), (1 + alpha / a, -2 * c, 1 - alpha / a))
    }

    static func highShelf(f: Double, gainDB: Double, fs: Double) -> Biquad {
        let a = pow(10, gainDB / 40), w = 2 * .pi * f / fs, c = cos(w)
        let alpha = sin(w) / 2 * 2.0.squareRoot() // shelf slope 1
        let sa = 2 * a.squareRoot() * alpha
        return make((a * ((a + 1) + (a - 1) * c + sa), -2 * a * ((a - 1) + (a + 1) * c), a * ((a + 1) + (a - 1) * c - sa)),
                    ((a + 1) - (a - 1) * c + sa, 2 * ((a - 1) - (a + 1) * c), (a + 1) - (a - 1) * c - sa))
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
