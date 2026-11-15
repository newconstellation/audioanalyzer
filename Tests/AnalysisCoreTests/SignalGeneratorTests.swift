import AnalysisCore
import XCTest

private let fs = 48_000.0

private func render(_ g: SignalGenerator, seconds: Double, block: Int = 512) -> [Float] {
    let n = Int(seconds * fs)
    var out = [Float](repeating: 0, count: n)
    out.withUnsafeMutableBufferPointer { p in
        var i = 0
        while i < n {
            let len = min(block, n - i)
            g.render(into: p.baseAddress! + i, frameCount: len)
            i += len
        }
    }
    return out
}

private func rmsDB<C: Collection>(_ x: C) -> Double where C.Element == Float {
    powerToDB(x.reduce(0) { $0 + Double($1) * Double($1) } / Double(x.count))
}

private func settings(_ configure: (inout GeneratorSettings) -> Void) -> GeneratorSettings {
    var s = GeneratorSettings()
    s.enabled = true
    s.tones = []
    configure(&s)
    return s
}

final class SignalGeneratorTests: XCTestCase {
    func testDisabledIsSilent() {
        var s = GeneratorSettings()
        s.enabled = false
        let x = render(SignalGenerator(sampleRate: fs, settings: s), seconds: 0.1)
        XCTAssertTrue(x.allSatisfy { $0 == 0 })
    }

    func testToneLevelAndFrequency() throws {
        let g = SignalGenerator(sampleRate: fs, settings: settings { $0.tones = [ToneSettings(frequency: 997, levelDBFS: -20)] })
        let x = render(g, seconds: 1)
        XCTAssertEqual(amplitudeToDB(Double(x.map(abs).max()!)), -20, accuracy: 0.01)
        XCTAssertEqual(rmsDB(x), -23.01, accuracy: 0.02)
        let d = try XCTUnwrap(DistortionAnalyzer(sampleRate: fs))
        let r = try XCTUnwrap(x.withUnsafeBufferPointer { d.analyze($0) })
        XCTAssertEqual(r.fundamentalHz, 997, accuracy: 0.02)
        XCTAssertLessThan(r.thdDB, -110, "the generator itself must be far cleaner than anything it measures")
    }

    func testMultipleTonesAndDisabledTone() throws {
        let g = SignalGenerator(sampleRate: fs, settings: settings {
            $0.tones = [ToneSettings(frequency: 1000, levelDBFS: -20),
                        ToneSettings(frequency: 5000, levelDBFS: -30),
                        ToneSettings(enabled: false, frequency: 300, levelDBFS: -6)]
        })
        let x = render(g, seconds: 0.5)
        let a = try XCTUnwrap(SpectrumAnalyzer(fftSize: 16384, window: .flatTop, sampleRate: fs))
        let db = x.withUnsafeBufferPointer { a.spectrumDB($0) }
        func level(at f: Double) -> Double {
            let k = Int((f / a.binWidth).rounded())
            return db[(k - 3)...(k + 3)].max()!
        }
        XCTAssertEqual(level(at: 1000), -20, accuracy: 0.05)
        XCTAssertEqual(level(at: 5000), -30, accuracy: 0.05)
        XCTAssertLessThan(level(at: 300), -100)
    }

    func testFFTSyncSnapsToBinCentre() throws {
        let g = SignalGenerator(sampleRate: fs, settings: settings {
            $0.tones = [ToneSettings(frequency: 1000, levelDBFS: -20)]
            $0.fftSyncSize = 4096
        })
        XCTAssertEqual(g.effectiveFrequency(1000), 85 * fs / 4096, accuracy: 1e-9)
        // With a rectangular window, a bin-centred tone has no leakage.
        let x = render(g, seconds: 0.2)
        let a = try XCTUnwrap(SpectrumAnalyzer(fftSize: 4096, window: .rectangular, sampleRate: fs))
        let db = x.withUnsafeBufferPointer { a.spectrumDB($0) }
        XCTAssertEqual(db[85], -20, accuracy: 0.01)
        XCTAssertLessThan(db[300], -100)
    }

    func testWhiteNoiseLevel() {
        let g = SignalGenerator(sampleRate: fs, settings: settings { $0.whiteNoiseDBFS = -30 })
        XCTAssertEqual(rmsDB(render(g, seconds: 2)), -30, accuracy: 0.1)
    }

    func testPinkNoiseLevelAndEqualPowerPerOctave() throws {
        let g = SignalGenerator(sampleRate: fs, settings: settings { $0.pinkNoiseDBFS = -30 })
        let x = render(g, seconds: 8)
        XCTAssertEqual(rmsDB(x), -30, accuracy: 0.4)

        // Average power spectra over many frames, then compare octave bands.
        let n = 8192
        let a = try XCTUnwrap(SpectrumAnalyzer(fftSize: n, window: .hann, sampleRate: fs))
        var power = [Double](repeating: 0, count: n / 2 + 1)
        var frames = 0
        x.withUnsafeBufferPointer { p in
            var i = 0
            while i + n <= p.count {
                for (k, m) in a.magnitudes(UnsafeBufferPointer(rebasing: p[i..<(i + n)])).enumerated() {
                    power[k] += Double(m) * Double(m)
                }
                frames += 1; i += n / 2
            }
        }
        func octave(_ lo: Double) -> Double {
            let a0 = Int(lo / a.binWidth), b0 = Int(2 * lo / a.binWidth)
            return power[a0..<b0].reduce(0, +)
        }
        let ref = octave(1000)
        for lo in [125.0, 250, 500, 2000, 4000, 8000] {
            XCTAssertEqual(powerToDB(octave(lo) / ref), 0, accuracy: 1.0, "octave from \(lo) Hz")
        }
    }

    func testLogSweepInstantaneousFrequency() {
        let g = SignalGenerator(sampleRate: fs, settings: settings {
            $0.tones = [ToneSettings(frequency: 20, levelDBFS: -6,
                                     sweep: Sweep(endFrequency: 20000, seconds: 2, logarithmic: true, mode: .once))]
        })
        let x = render(g, seconds: 2)
        // At the midpoint a log sweep from 20 Hz to 20 kHz is at sqrt(20 * 20000) = 632.5 Hz.
        // Count zero crossings in a 50 ms window centred there.
        let mid = Int(fs), half = Int(0.025 * fs)
        var crossings = 0
        for i in (mid - half + 1)..<(mid + half) where (x[i - 1] < 0) != (x[i] < 0) { crossings += 1 }
        let f = Double(crossings) / 2 / 0.05
        XCTAssertEqual(f, 632.5, accuracy: 632.5 * 0.03)
    }

    func testBurstGating() {
        let g = SignalGenerator(sampleRate: fs, settings: settings {
            $0.tones = [ToneSettings(frequency: 1000, levelDBFS: -20)]
            $0.burst = Burst(onSeconds: 0.1, offSeconds: 0.1, rampSeconds: 0.005)
        })
        let x = render(g, seconds: 0.4)
        let on = x[Int(0.02 * fs)..<Int(0.08 * fs)]
        let off = x[Int(0.105 * fs)..<Int(0.195 * fs)]
        let on2 = x[Int(0.22 * fs)..<Int(0.28 * fs)]
        XCTAssertEqual(rmsDB(on), -23.01, accuracy: 0.05)
        XCTAssertEqual(rmsDB(on2), -23.01, accuracy: 0.05)
        XCTAssertTrue(off.allSatisfy { $0 == 0 })
        XCTAssertEqual(x[0], 0, "bursts start from silence (raised-cosine ramp)")
    }

    func testDitherQuantisesToGridWithExpectedNoise() {
        let g = SignalGenerator(sampleRate: fs, settings: settings { $0.ditherBits = 16 })
        let x = render(g, seconds: 2)
        let lsb = 1.0 / 32768
        for v in x.prefix(10000) {
            let steps = Double(v) / lsb
            XCTAssertEqual(steps, steps.rounded(), accuracy: 1e-3)
        }
        // TPDF dither on silence: 0 with p = 0.75, +/-1 LSB with p = 0.125 each,
        // so RMS = LSB / 2. LSB = 2^-15 (-90.3 dBFS), so RMS = -96.3 dBFS.
        XCTAssertEqual(rmsDB(x), -96.33, accuracy: 0.2)
        let mean = x.reduce(0) { $0 + Double($1) } / Double(x.count)
        XCTAssertEqual(mean, 0, accuracy: lsb * 0.02)
    }

    func testOutputIsClipped() {
        let g = SignalGenerator(sampleRate: fs, settings: settings {
            $0.tones = [ToneSettings(frequency: 100, levelDBFS: 0), ToneSettings(frequency: 100, levelDBFS: 0)]
        })
        XCTAssertLessThanOrEqual(render(g, seconds: 0.1).map(abs).max()!, 1)
    }
}
