import AnalysisCore
import XCTest

private let fs = 48_000.0

private struct Noise {
    var state: UInt64
    mutating func next() -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Double(z >> 11) / Double(1 << 53) * 2 - 1 // uniform -1...1
    }
}

private func noise(_ n: Int, seed: UInt64, amplitude: Double = 0.3) -> [Float] {
    var g = Noise(state: seed)
    return (0..<n).map { _ in Float(g.next() * amplitude) }
}

private func feedTF(_ tf: TransferFunctionAnalyzer, _ x: [Float], _ y: [Float], block: Int = 1024) {
    x.withUnsafeBufferPointer { xp in
        y.withUnsafeBufferPointer { yp in
            var i = 0
            while i < x.count {
                let n = min(block, x.count - i)
                tf.process(source: UnsafeBufferPointer(rebasing: xp[i..<(i + n)]),
                           response: UnsafeBufferPointer(rebasing: yp[i..<(i + n)]))
                i += n
            }
        }
    }
}

private func bin(_ r: TransferFunctionResult, near f: Double) -> Int {
    r.frequencies.indices.min(by: { abs(r.frequencies[$0] - f) < abs(r.frequencies[$1] - f) })!
}

final class TransferFunctionTests: XCTestCase {
    func testIdentityIsFlatZeroPhaseFullCoherence() throws {
        let tf = try XCTUnwrap(TransferFunctionAnalyzer(fftSize: 4096, sampleRate: fs))
        let x = noise(48_000, seed: 1)
        feedTF(tf, x, x)
        let r = tf.result
        XCTAssertGreaterThan(r.averages, 10)
        for f in [100.0, 1000, 10000] {
            let i = bin(r, near: f)
            XCTAssertEqual(r.magnitudeDB[i], 0, accuracy: 0.01)
            XCTAssertEqual(r.phaseDegrees[i], 0, accuracy: 0.1)
            XCTAssertEqual(r.coherence[i], 1, accuracy: 1e-4)
        }
    }

    func testGainAndPolarity() throws {
        let tf = try XCTUnwrap(TransferFunctionAnalyzer(fftSize: 4096, sampleRate: fs))
        let x = noise(48_000, seed: 2)
        feedTF(tf, x, x.map { -0.5 * $0 })
        let r = tf.result
        let i = bin(r, near: 1000)
        XCTAssertEqual(r.magnitudeDB[i], -6.02, accuracy: 0.01)
        XCTAssertEqual(abs(r.phaseDegrees[i]), 180, accuracy: 0.1)
    }

    /// y[n] = (x[n] + x[n-1]) / 2 has H(f) = cos(pi f / fs) e^(-j pi f / fs):
    /// at fs/4, -3.01 dB and -45 degrees.
    func testTwoTapAverageMatchesTheory() throws {
        let tf = try XCTUnwrap(TransferFunctionAnalyzer(fftSize: 4096, sampleRate: fs))
        let x = noise(96_000, seed: 3)
        var y = [Float](repeating: 0, count: x.count)
        for n in 1..<x.count { y[n] = 0.5 * (x[n] + x[n - 1]) }
        feedTF(tf, x, y)
        let r = tf.result
        let i = bin(r, near: fs / 4)
        XCTAssertEqual(r.magnitudeDB[i], -3.01, accuracy: 0.05)
        XCTAssertEqual(r.phaseDegrees[i], -45, accuracy: 0.5)
    }

    func testUncorrelatedNoiseHalvesCoherence() throws {
        let tf = try XCTUnwrap(TransferFunctionAnalyzer(fftSize: 2048, sampleRate: fs, maxAverages: 400))
        let x = noise(480_000, seed: 4)
        let n = noise(480_000, seed: 5)
        feedTF(tf, x, zip(x, n).map { $0 + $1 })
        let r = tf.result
        // Equal-power independent noise: coherence 0.5 (averaged over bins).
        let mid = r.coherence[100..<800]
        XCTAssertEqual(mid.reduce(0, +) / Double(mid.count), 0.5, accuracy: 0.03)
        // H1 is unbiased by noise on the response: still 0 dB.
        let mag = r.magnitudeDB[100..<800]
        XCTAssertEqual(mag.reduce(0, +) / Double(mag.count), 0, accuracy: 0.2)
    }

    func testDelayFinderAndCompensation() throws {
        let tf = try XCTUnwrap(TransferFunctionAnalyzer(fftSize: 8192, sampleRate: fs))
        let d = 96 // 2 ms
        let x = noise(96_000, seed: 6)
        let y = [Float](repeating: 0, count: d) + x.dropLast(d)
        feedTF(tf, x, y)
        let found = try XCTUnwrap(tf.findDelay())
        XCTAssertEqual(found, Double(d), accuracy: 0.5)

        // Before compensation the phase rotates with frequency;
        // after it, the channels line up again.
        tf.reset()
        tf.delayCompensation = Int(found.rounded())
        feedTF(tf, x, y)
        let r = tf.result
        let i = bin(r, near: 5000)
        XCTAssertEqual(r.phaseDegrees[i], 0, accuracy: 0.5)
        XCTAssertEqual(r.magnitudeDB[i], 0, accuracy: 0.05)
        XCTAssertEqual(r.coherence[i], 1, accuracy: 1e-3)
        XCTAssertEqual(tf.findDelay() ?? 99, 0, accuracy: 0.5)
    }

    func testNegativeDelayDelaysTheSource() throws {
        let tf = try XCTUnwrap(TransferFunctionAnalyzer(fftSize: 4096, sampleRate: fs))
        let d = 30
        let y = noise(48_000, seed: 7)
        let x = [Float](repeating: 0, count: d) + y.dropLast(d) // source lags response
        feedTF(tf, x, y)
        XCTAssertEqual(try XCTUnwrap(tf.findDelay()), -Double(d), accuracy: 0.5)
    }
}

final class DistortionAnalyzerTests: XCTestCase {
    private func tone(_ f: Double, n: Int, harmonics: [(Int, Double)] = [], dbfs: Double = -6) -> [Float] {
        let a = dbToAmplitude(dbfs)
        return (0..<n).map { i in
            let t = Double(i) / fs
            var v = a * sin(2 * .pi * f * t)
            for (h, dbc) in harmonics { v += a * dbToAmplitude(dbc) * sin(2 * .pi * f * Double(h) * t) }
            return Float(v)
        }
    }

    func testKnownHarmonics() throws {
        let d = try XCTUnwrap(DistortionAnalyzer(fftSize: 32768, sampleRate: fs))
        let x = tone(997, n: 32768, harmonics: [(2, -60), (3, -70)])
        let r = try XCTUnwrap(x.withUnsafeBufferPointer { d.analyze($0) })
        XCTAssertEqual(r.fundamentalHz, 997, accuracy: 0.05)
        XCTAssertEqual(r.fundamentalDBFS, -6, accuracy: 0.02)
        XCTAssertEqual(r.harmonicsDBc[0], -60, accuracy: 0.05)
        XCTAssertEqual(r.harmonicsDBc[1], -70, accuracy: 0.1)
        // THD = sqrt(1e-6 + 1e-7) = 0.1049 %, -59.59 dB
        XCTAssertEqual(r.thdDB, -59.59, accuracy: 0.05)
        XCTAssertEqual(r.thdPercent, 0.1049, accuracy: 0.001)
    }

    func testTHDPlusNoiseIncludesNoise() throws {
        let d = try XCTUnwrap(DistortionAnalyzer(fftSize: 32768, sampleRate: fs))
        // Uniform noise of amplitude a has RMS a / sqrt(3); target -80 dBFS RMS.
        let n = noise(32768, seed: 9, amplitude: dbToAmplitude(-80) * 3.0.squareRoot())
        let x = zip(tone(997, n: 32768, harmonics: [(2, -60), (3, -70)]), n).map { $0 + $1 }
        let r = try XCTUnwrap(x.withUnsafeBufferPointer { d.analyze($0) })
        // Fundamental power 0.1256; harmonics 1.38e-7; noise in 20 Hz-20 kHz 8.3e-9.
        XCTAssertEqual(r.thdnDB, -59.33, accuracy: 0.1)
        XCTAssertEqual(r.sinadDB, 59.33, accuracy: 0.1)
        XCTAssertGreaterThan(r.thdnDB, r.thdDB)
    }

    func testPureToneHasVeryLowTHD() throws {
        let d = try XCTUnwrap(DistortionAnalyzer(fftSize: 32768, sampleRate: fs))
        let x = tone(1234.5, n: 32768)
        let r = try XCTUnwrap(x.withUnsafeBufferPointer { d.analyze($0) })
        XCTAssertEqual(r.fundamentalHz, 1234.5, accuracy: 0.05)
        XCTAssertLessThan(r.thdDB, -110)
    }

    func testHarmonicsAboveBandwidthAreIgnored() throws {
        let d = try XCTUnwrap(DistortionAnalyzer(fftSize: 32768, sampleRate: fs))
        // 7 kHz: H2 = 14 kHz is in band; H3 = 21 kHz is outside 20 kHz.
        let x = tone(7000, n: 32768, harmonics: [(2, -60), (3, -40)])
        let r = try XCTUnwrap(x.withUnsafeBufferPointer { d.analyze($0) })
        XCTAssertEqual(r.harmonicsDBc.count, 1)
        XCTAssertEqual(r.thdDB, -60, accuracy: 0.05)
    }

    func testSilenceGivesNoResult() throws {
        let d = try XCTUnwrap(DistortionAnalyzer(fftSize: 32768, sampleRate: fs))
        let x = [Float](repeating: 0, count: 32768)
        XCTAssertNil(x.withUnsafeBufferPointer { d.analyze($0) })
    }
}
