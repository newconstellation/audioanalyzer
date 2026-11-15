import AnalysisCore
import XCTest

final class OctaveBandTests: XCTestCase {
    func testThirdOctaveNominalFrequencies() {
        let bands = octaveBands(.third)
        XCTAssertEqual(bands.count, 31)
        XCTAssertEqual(bands.first?.nominal, 20)
        XCTAssertEqual(bands.last?.nominal, 20000)
        let nominals = bands.map(\.nominal)
        for f in [25.0, 31.5, 63, 125, 250, 315, 1000, 1250, 3150, 6300, 12500] {
            XCTAssertTrue(nominals.contains { abs($0 - f) < 1e-6 * f }, "missing \(f)")
        }
        // Adjacent bands share edges.
        for (a, b) in zip(bands, bands.dropFirst()) {
            XCTAssertEqual(a.upper, b.lower, accuracy: 1e-9 * b.lower)
        }
    }

    func testOctaveBands() {
        let bands = octaveBands(.octave)
        XCTAssertEqual(bands.map(\.nominal), [31.5, 63, 125, 250, 500, 1000, 2000, 4000, 8000, 16000])
        let k = bands.first { $0.nominal == 1000 }!
        XCTAssertEqual(k.center, 1000, accuracy: 1e-9)
        XCTAssertEqual(k.upper / k.lower, pow(10, 0.3), accuracy: 1e-9)
    }

    func testLabels() {
        XCTAssertEqual(frequencyLabel(31.5), "31.5")
        XCTAssertEqual(frequencyLabel(1000), "1k")
        XCTAssertEqual(frequencyLabel(1250), "1.25k")
        XCTAssertEqual(frequencyLabel(12500), "12.5k")
    }

    private func spectrum(of x: [Float], fs: Double) throws -> (SpectrumAnalyzer, [Double]) {
        let a = try XCTUnwrap(SpectrumAnalyzer(fftSize: x.count, window: .hann, sampleRate: fs))
        return (a, x.withUnsafeBufferPointer { a.spectrumDB($0) })
    }

    func testSineReadsItsLevelInItsBand() throws {
        let fs = 48_000.0, n = 8192
        let x = (0..<n).map { Float(0.25 * sin(2 * .pi * 1000 * Double($0) / fs)) } // -12 dBFS
        let (a, db) = try spectrum(of: x, fs: fs)
        let bands = octaveBands(.third)
        let levels = bandLevels(spectrumDB: db, binWidth: a.binWidth, enbwBins: a.equivalentNoiseBandwidth, bands: bands)
        let i = bands.firstIndex { $0.nominal == 1000 }!
        XCTAssertEqual(levels[i], amplitudeToDB(0.25), accuracy: 0.3)
        XCTAssertLessThan(levels[i + 3], levels[i] - 40)
    }

    func testWhiteNoiseRisesThreeDBPerOctave() throws {
        let fs = 48_000.0, n = 65536
        var state: UInt64 = 12345
        let x: [Float] = (0..<n).map { _ in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Float(Double(state >> 11) / Double(1 << 53) - 0.5) // uniform, RMS 1/sqrt(12)
        }
        let (a, db) = try spectrum(of: x, fs: fs)
        let bands = octaveBands(.octave)
        let levels = bandLevels(spectrumDB: db, binWidth: a.binWidth, enbwBins: a.equivalentNoiseBandwidth, bands: bands)
        // Bands double in width each octave, so white noise gains 3 dB per band.
        let slope = (levels[8] - levels[4]) / 4
        XCTAssertEqual(slope, 3.01, accuracy: 0.3)
        // Total power over all bins (with the sine-referenced scale) is RMS + 3 dB.
        let total = bandLevels(spectrumDB: db, binWidth: a.binWidth, enbwBins: a.equivalentNoiseBandwidth,
                               bands: [OctaveBand(center: 12000, lower: 1, upper: 24000, nominal: 12000)])[0]
        XCTAssertEqual(total, amplitudeToDB(1 / 12.0.squareRoot()) + 3.01, accuracy: 0.3)
    }
}
