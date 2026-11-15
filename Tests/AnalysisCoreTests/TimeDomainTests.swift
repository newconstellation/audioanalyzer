import AnalysisCore
import XCTest

private let fs = 48_000.0

private func sine(_ f: Double, count: Int, phase: Double = 0) -> [Float] {
    (0..<count).map { Float(sin(2 * .pi * f * Double($0) / fs + phase)) }
}

final class TimeDomainTests: XCTestCase {
    func testRisingTriggerLandsAtPreTrigger() throws {
        // 1 kHz: 48 samples per cycle. Phase offset so no sample is exactly 0.
        let x = sine(1000, count: 4800, phase: 0.3)
        var s = ScopeSettings()
        s.mode = .rising; s.level = 0; s.length = 480; s.preTrigger = 0.25
        let trace = captureScope([x], settings: s, sampleRate: fs)
        let t = try XCTUnwrap(trace.triggerIndex)
        XCTAssertEqual(t, 120)
        let y = trace.channels[0]
        XCTAssertEqual(y.count, 480)
        XCTAssertLessThan(y[t - 1], 0)
        XCTAssertGreaterThanOrEqual(y[t], 0)
    }

    func testFallingTriggerAndLevel() throws {
        let x = sine(1000, count: 4800, phase: 0.3)
        var s = ScopeSettings()
        s.mode = .falling; s.level = 0.5; s.length = 480; s.preTrigger = 0.1
        let trace = captureScope([x, x.map { -$0 }], settings: s, sampleRate: fs)
        let t = try XCTUnwrap(trace.triggerIndex)
        let y = trace.channels[0]
        XCTAssertGreaterThan(y[t - 1], 0.5)
        XCTAssertLessThanOrEqual(y[t], 0.5)
        XCTAssertEqual(trace.channels.count, 2)
        XCTAssertEqual(trace.channels[1][t], -y[t]) // second channel cut at the same point
    }

    func testFreeRunAndNoCrossingShowLatest() {
        let x: [Float] = (0..<1000).map { Float($0) / 1000 } // ramp: never falls
        var s = ScopeSettings()
        s.length = 100
        s.mode = .free
        var trace = captureScope([x], settings: s, sampleRate: fs)
        XCTAssertNil(trace.triggerIndex)
        XCTAssertEqual(trace.channels[0], Array(x.suffix(100)))
        s.mode = .falling
        trace = captureScope([x], settings: s, sampleRate: fs)
        XCTAssertNil(trace.triggerIndex)
        XCTAssertEqual(trace.channels[0], Array(x.suffix(100)))
    }

    func testScopeNeedsEnoughSamples() {
        var s = ScopeSettings()
        s.length = 100
        XCTAssertTrue(captureScope([[0, 1, 2]], settings: s, sampleRate: fs).channels.isEmpty)
    }

    func testHistoryKeepsNewest() {
        var h = History<Int>(capacity: 3)
        for i in 1...5 { h.append(i) }
        XCTAssertEqual(h.values, [3, 4, 5])
        h.removeAll()
        XCTAssertTrue(h.values.isEmpty)
    }

    func testLogReduceTakesColumnMaximum() {
        let binWidth = 10.0
        var spectrum = [Double](repeating: -120, count: 2401) // 0...24 kHz
        spectrum[100] = -6 // 1 kHz
        let row = logReduce(spectrum, binWidth: binWidth, columns: 300)
        XCTAssertEqual(row.count, 300)
        // 1 kHz sits at log(1000/20)/log(1000) of the way across.
        let expected = Int(300 * log(50.0) / log(1000.0))
        let peak = row.indices.max { row[$0] < row[$1] }!
        XCTAssertLessThanOrEqual(abs(peak - expected), 1)
        XCTAssertEqual(row[peak], -6)
        XCTAssertEqual(row[0], -120)
    }

    func testEngineBuildsHistories() {
        let engine = AnalysisEngine(sampleRate: fs, channelCount: 2)
        let left = sine(1000, count: Int(fs), phase: 0.3).map { $0 * 0.5 }
        let right = left.map { -$0 } // out of phase: correlation -1
        left.withUnsafeBufferPointer { l in
            right.withUnsafeBufferPointer { r in
                var i = 0
                while i < left.count {
                    let n = min(512, left.count - i)
                    engine.process(channels: [l.baseAddress! + i, r.baseAddress! + i], frameCount: n)
                    i += n
                }
            }
        }
        let s = engine.snapshot
        // 1 s at one point per 50 ms; blocks of 512 round each step up a little.
        XCTAssertEqual(Double(s.correlationHistory.count), 1 / engine.historyStep, accuracy: 2.5)
        XCTAssertEqual(s.powerHistory.count, 2)
        XCTAssertEqual(s.powerHistory[0].count, s.correlationHistory.count)
        let last = s.powerHistory[0].last!
        XCTAssertEqual(last.peakDB, amplitudeToDB(0.5), accuracy: 0.1)
        XCTAssertEqual(last.rmsDB, amplitudeToDB(0.5) - 3.01, accuracy: 0.1)
        XCTAssertLessThan(s.correlationHistory.last!, -0.9)
        XCTAssertFalse(s.waterfall.isEmpty)
        XCTAssertEqual(s.waterfall.last?.count, AnalysisEngine.waterfallColumns)
        XCTAssertNotNil(s.scope.triggerIndex)
        XCTAssertEqual(s.vectorscope.left.count, 2048)

        engine.resetPeaks()
        XCTAssertTrue(engine.snapshot.waterfall.isEmpty)
        XCTAssertTrue(engine.snapshot.correlationHistory.isEmpty)
    }
}
