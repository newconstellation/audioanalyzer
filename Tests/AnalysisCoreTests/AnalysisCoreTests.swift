import AnalysisCore
import XCTest

private let fs = 48_000.0

private func sine(_ freq: Double, seconds: Double, dbfs: Double, phase: Double = 0) -> [Float] {
    let a = dbToAmplitude(dbfs)
    return (0..<Int(seconds * fs)).map { Float(a * sin(2 * .pi * freq * Double($0) / fs + phase)) }
}

private func feed(_ meter: LevelMeter, _ x: [Float], block: Int = 512) {
    x.withUnsafeBufferPointer { p in
        var i = 0
        while i < p.count {
            let n = min(block, p.count - i)
            meter.process(UnsafeBufferPointer(rebasing: p[i..<(i + n)]))
            i += n
        }
    }
}

final class LevelMeterTests: XCTestCase {
    func testSineMinus20ReadsPeakAndTrueRMS() {
        let m = LevelMeter(sampleRate: fs)
        feed(m, sine(1000, seconds: 3, dbfs: -20))
        let r = m.reading
        XCTAssertEqual(r.peakDB, -20, accuracy: 0.05)
        XCTAssertEqual(r.rmsDB, -23.01, accuracy: 0.05)
        XCTAssertEqual(r.vuDB, -23.01, accuracy: 0.1)
        XCTAssertEqual(r.overs, 0)
    }

    func testSineReferencedRMSReadsPeak() {
        var b = MeterBallistics()
        b.rmsReference = .sineReferenced
        let m = LevelMeter(sampleRate: fs, ballistics: b)
        feed(m, sine(1000, seconds: 3, dbfs: -20))
        XCTAssertEqual(m.reading.rmsDB, -20, accuracy: 0.05)
        XCTAssertEqual(m.reading.vuDB, -20, accuracy: 0.1)
    }

    func testPeakCrawlbackRate() {
        let m = LevelMeter(sampleRate: fs) // 20 dB/s default
        feed(m, sine(1000, seconds: 0.5, dbfs: -10))
        feed(m, [Float](repeating: 0, count: Int(fs))) // 1 s of silence
        XCTAssertEqual(m.reading.peakDB, -30, accuracy: 0.3)
    }

    func testVURisesTo99PercentIn300ms() {
        let m = LevelMeter(sampleRate: fs)
        feed(m, sine(1000, seconds: 0.3, dbfs: -20), block: 48)
        // 99% of the steady value is -0.087 dB below it.
        XCTAssertEqual(m.reading.vuDB, -23.01 - 0.087, accuracy: 0.15)
    }

    func testOversCountedOnlyForSustainedFullScale() {
        let m = LevelMeter(sampleRate: fs)
        feed(m, sine(1000, seconds: 1, dbfs: -0.0001))
        XCTAssertEqual(m.reading.overs, 0, "a 0 dBFS sine only touches full scale for one sample per peak")
        feed(m, [Float](repeating: 1, count: 10) + [0] + [Float](repeating: -1, count: 2))
        XCTAssertEqual(m.reading.overs, 1)
    }

    func testSilenceReadsFloor() {
        let m = LevelMeter(sampleRate: fs)
        feed(m, [Float](repeating: 0, count: 4800))
        XCTAssertEqual(m.reading.peakDB, floorDB)
        XCTAssertEqual(m.reading.rmsDB, floorDB)
        XCTAssertEqual(m.reading.vuDB, floorDB)
    }
}

final class SpectrumAnalyzerTests: XCTestCase {
    func testBinCentredSineReadsItsLevel() throws {
        for window in WindowFunction.allCases {
            let a = try XCTUnwrap(SpectrumAnalyzer(fftSize: 4096, window: window, sampleRate: fs))
            let bin = 100
            let x = sine(a.frequency(ofBin: bin), seconds: 0.1, dbfs: -20)
            let db = x.withUnsafeBufferPointer { a.spectrumDB($0) }
            XCTAssertEqual(db[bin], -20, accuracy: 0.01, "\(window)")
            XCTAssertEqual(db.firstIndex(of: db.max()!), bin, "\(window)")
        }
    }

    func testFlatTopReadsOffBinSineAccurately() throws {
        let a = try XCTUnwrap(SpectrumAnalyzer(fftSize: 4096, window: .flatTop, sampleRate: fs))
        let x = sine(1000, seconds: 0.1, dbfs: -20) // 85.33 bins: between bins
        let db = x.withUnsafeBufferPointer { a.spectrumDB($0) }
        XCTAssertEqual(db.max()!, -20, accuracy: 0.05)
        let peakFreq = a.frequency(ofBin: db.firstIndex(of: db.max()!)!)
        XCTAssertEqual(peakFreq, 1000, accuracy: a.binWidth)
    }

    func testRectangularHasNoLeakageForBinCentredSine() throws {
        let a = try XCTUnwrap(SpectrumAnalyzer(fftSize: 1024, window: .rectangular, sampleRate: fs))
        let x = sine(a.frequency(ofBin: 64), seconds: 0.05, dbfs: 0)
        let db = x.withUnsafeBufferPointer { a.spectrumDB($0) }
        XCTAssertLessThan(db[200], -100)
    }

    func testDCAndNyquistScale() throws {
        let a = try XCTUnwrap(SpectrumAnalyzer(fftSize: 1024, window: .rectangular, sampleRate: fs))
        let dc = [Float](repeating: 0.1, count: 1024)
        XCTAssertEqual(dc.withUnsafeBufferPointer { a.spectrumDB($0) }[0], -20, accuracy: 0.01)
        let nyq = (0..<1024).map { Float($0 % 2 == 0 ? 0.1 : -0.1) }
        XCTAssertEqual(nyq.withUnsafeBufferPointer { a.spectrumDB($0) }[512], -20, accuracy: 0.01)
    }

    func testResolvesTonesThreeHertzApartAt64k() throws {
        let a = try XCTUnwrap(SpectrumAnalyzer(fftSize: 65536, window: .hann, sampleRate: fs))
        let x = zip(sine(1000, seconds: 1.4, dbfs: -20), sine(1003, seconds: 1.4, dbfs: -20)).map { $0 + $1 }
        let db = x.withUnsafeBufferPointer { a.spectrumDB($0) }
        let b1 = Int((1000 / a.binWidth).rounded()), b2 = Int((1003 / a.binWidth).rounded())
        let mid = (b1 + b2) / 2
        XCTAssertGreaterThan(db[b1] - db[mid], 6)
        XCTAssertGreaterThan(db[b2] - db[mid], 6)
    }

    func testRejectsInvalidSize() {
        XCTAssertNil(SpectrumAnalyzer(fftSize: 1000, sampleRate: fs))
        XCTAssertNil(SpectrumAnalyzer(fftSize: 16, sampleRate: fs))
    }

    func testAveragerPeakHold() {
        var avg = SpectrumAverager(mode: .exponential(seconds: 1))
        avg.add([-20, -40], updateInterval: 0.1)
        avg.add([-60, -10], updateInterval: 0.1)
        XCTAssertEqual(avg.peakDB, [-20, -10])
        XCTAssertLessThan(avg.averageDB[0], -20)
        XCTAssertGreaterThan(avg.averageDB[0], -60)
    }
}

final class CorrelationMeterTests: XCTestCase {
    private func measure(_ l: [Float], _ r: [Float]) -> CorrelationMeter {
        let c = CorrelationMeter(sampleRate: fs)
        l.withUnsafeBufferPointer { lp in r.withUnsafeBufferPointer { rp in c.process(left: lp, right: rp) } }
        return c
    }

    func testIdenticalInvertedQuadrature() {
        let s = sine(1000, seconds: 2, dbfs: -20)
        XCTAssertEqual(measure(s, s).correlation, 1, accuracy: 1e-6)
        XCTAssertEqual(measure(s, s.map { -$0 }).correlation, -1, accuracy: 1e-6)
        XCTAssertEqual(measure(s, sine(1000, seconds: 2, dbfs: -20, phase: .pi / 2)).correlation, 0, accuracy: 0.02)
    }

    func testBalanceSixDBLeft() {
        let c = measure(sine(1000, seconds: 2, dbfs: -20), sine(1000, seconds: 2, dbfs: -26))
        XCTAssertEqual(c.balance, 0.598, accuracy: 0.01)
    }

    func testSilentChannelGivesZero() {
        let c = measure(sine(1000, seconds: 1, dbfs: -20), [Float](repeating: 0, count: 48_000))
        XCTAssertEqual(c.correlation, 0)
        XCTAssertEqual(c.balance, 1, accuracy: 1e-9)
    }
}
