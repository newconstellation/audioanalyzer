import AnalysisCore
import XCTest

final class SoundLevelTests: XCTestCase {
    private let fs = 48_000.0

    func testWeightingCurvesMatchIEC61672() {
        let a = WeightingFilter(.a, sampleRate: fs), c = WeightingFilter(.c, sampleRate: fs), z = WeightingFilter(.z, sampleRate: fs)
        // Nominal values from IEC 61672-1 table 3.
        let expectedA: [(Double, Double)] = [(31.5, -39.4), (63, -26.2), (100, -19.1), (250, -8.6), (500, -3.2),
                                             (1000, 0), (2000, 1.2), (4000, 1.0), (8000, -1.1)]
        for (f, db) in expectedA {
            XCTAssertEqual(a.responseDB(at: f), db, accuracy: f >= 8000 ? 1.0 : 0.15, "A at \(f) Hz")
        }
        let expectedC: [(Double, Double)] = [(31.5, -3.0), (63, -0.8), (100, -0.3), (1000, 0), (4000, -0.8), (8000, -3.0)]
        for (f, db) in expectedC {
            XCTAssertEqual(c.responseDB(at: f), db, accuracy: f >= 8000 ? 1.0 : 0.15, "C at \(f) Hz")
        }
        XCTAssertEqual(z.responseDB(at: 50), 0, accuracy: 1e-9)
    }

    private func sine(_ f: Double, amplitude: Double, seconds: Double) -> [Float] {
        (0..<Int(seconds * fs)).map { Float(amplitude * sin(2 * .pi * f * Double($0) / fs)) }
    }

    private func feed(_ m: SoundLevelMeter, _ x: [Float]) {
        x.withUnsafeBufferPointer { p in
            var i = 0
            while i < p.count {
                let n = min(512, p.count - i)
                m.process(UnsafeBufferPointer(rebasing: p[i..<(i + n)]))
                i += n
            }
        }
    }

    func testSineLevels() {
        let m = SoundLevelMeter(sampleRate: fs, weighting: .z)
        feed(m, sine(1000, amplitude: 0.5, seconds: 6))
        let r = m.reading
        let rms = amplitudeToDB(0.5) - 3.0103
        XCTAssertEqual(r.fast, rms, accuracy: 0.05)
        XCTAssertEqual(r.slow, rms, accuracy: 0.05)
        XCTAssertEqual(r.leq, rms, accuracy: 0.05)
        XCTAssertEqual(r.periodLeq, rms, accuracy: 0.05)
        XCTAssertEqual(r.maxFast, rms, accuracy: 0.1)
        XCTAssertEqual(r.peak, amplitudeToDB(0.5), accuracy: 0.05)
        XCTAssertEqual(r.duration, 6, accuracy: 0.01)
    }

    func testAWeightingAppliesToLevel() {
        let m = SoundLevelMeter(sampleRate: fs, weighting: .a)
        feed(m, sine(100, amplitude: 1, seconds: 4))
        XCTAssertEqual(m.reading.slow, -3.01 - 19.1, accuracy: 0.3)
    }

    func testFastFallsFasterThanSlow() {
        let m = SoundLevelMeter(sampleRate: fs, weighting: .z)
        m.leqPeriodSeconds = 1
        feed(m, sine(1000, amplitude: 1, seconds: 3))
        feed(m, [Float](repeating: 0, count: Int(0.5 * fs)))
        let r = m.reading
        // 0.5 s of silence: Fast falls 4.34 dB per 125 ms (17.4 dB), Slow 4.34 dB per second (2.2 dB).
        XCTAssertEqual(r.fast, -3.01 - 17.37, accuracy: 0.3)
        XCTAssertEqual(r.slow, -3.01 - 2.17, accuracy: 0.3)
        XCTAssertEqual(r.maxFast, -3.01, accuracy: 0.1)
        XCTAssertLessThan(r.periodLeq, r.leq) // the last second is half silence
    }

    func testCalibratorGivesOffset() throws {
        let cal = LevelCalibrator(sampleRate: fs, referenceSPL: 94, seconds: 2)
        let tone = sine(1000, amplitude: 0.1, seconds: 2.5)
        tone.withUnsafeBufferPointer { cal.process($0) }
        XCTAssertTrue(cal.isDone)
        let offset = try XCTUnwrap(cal.offset)
        // 0.1 peak = -23.0 dB RMS re 1, so the offset is 94 + 23.0.
        XCTAssertEqual(offset, 94 - (amplitudeToDB(0.1) - 3.0103), accuracy: 0.05)

        let quiet = LevelCalibrator(sampleRate: fs, seconds: 0.5)
        sine(1000, amplitude: 0.0001, seconds: 1).withUnsafeBufferPointer { quiet.process($0) }
        XCTAssertNil(quiet.offset)
    }
}

final class EngineCalibrationTests: XCTestCase {
    func testEngineCalibratesAChannel() throws {
        let fs = 48_000.0
        let engine = AnalysisEngine(sampleRate: fs, channelCount: 2)
        engine.startCalibration(channel: 1, referenceSPL: 114, seconds: 1)
        let silent = [Float](repeating: 0, count: 512)
        var phase = 0.0
        for _ in 0..<Int(1.5 * fs / 512) {
            let tone: [Float] = (0..<512).map { _ in
                phase += 2 * .pi * 1000 / fs
                return Float(0.25 * sin(phase))
            }
            silent.withUnsafeBufferPointer { a in
                tone.withUnsafeBufferPointer { b in engine.process(channels: [a.baseAddress!, b.baseAddress!], frameCount: 512) }
            }
        }
        let status = try XCTUnwrap(engine.snapshot.calibration)
        XCTAssertEqual(status.channel, 1)
        XCTAssertEqual(status.progress, 1)
        let expected = 114 - (amplitudeToDB(0.25) - 3.0103)
        XCTAssertEqual(try XCTUnwrap(status.offset), expected, accuracy: 0.05)
        let applied = try XCTUnwrap(engine.applyCalibration())
        XCTAssertEqual(applied.channel, 1)
        XCTAssertNil(engine.snapshot.calibration)
        XCTAssertNil(engine.calibrationOffsets[0])
        XCTAssertEqual(try XCTUnwrap(engine.calibrationOffsets[1]), expected, accuracy: 0.05)
        // The calibrated channel's A-weighted Leq now reads about 114 dB SPL (A is 0 dB at 1 kHz).
        // (Slow would still be settling after 1.5 s: its time constant is 1 s.)
        let la = engine.snapshot.soundLevels[1].a.leq + expected
        XCTAssertEqual(la, 114, accuracy: 0.3)
    }
}
