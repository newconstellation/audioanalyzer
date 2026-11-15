import AnalysisCore
import XCTest

final class SpatialAverageTests: XCTestCase {
    func testPowerAverageOfSpectra() {
        let a = [Double](repeating: -10, count: 100), b = [Double](repeating: -20, count: 100)
        let avg = averageSpectra([a, b], binWidth: 100, mode: .power)
        XCTAssertEqual(avg[50], powerToDB((0.1 + 0.01) / 2), accuracy: 1e-9)
        XCTAssertEqual(averageSpectra([a], binWidth: 100, mode: .power), a)
    }

    func testNormalisedPowerRemovesLevelDifferences() {
        let a = (0..<200).map { -20 - Double($0 % 7) }
        let b = a.map { $0 - 6 }
        let avg = averageSpectra([a, b], binWidth: 50, mode: .normalizedPower)
        for k in [10, 60, 150] { XCTAssertEqual(avg[k], a[k], accuracy: 1e-6) }
    }

    private func result(db: Double, phase: Double, coherence: Double, bins: Int = 10) -> TransferFunctionResult {
        var r = TransferFunctionResult()
        r.frequencies = (1...bins).map { Double($0) * 100 }
        r.magnitudeDB = Array(repeating: db, count: bins)
        r.phaseDegrees = Array(repeating: phase, count: bins)
        r.coherence = Array(repeating: coherence, count: bins)
        r.averages = 4
        return r
    }

    func testTransferFunctionAverages() {
        let a = result(db: 0, phase: 0, coherence: 1), b = result(db: -6, phase: 90, coherence: 0.25)
        let cw = averageTransferFunctions([a, b], mode: .coherenceWeighted)
        XCTAssertEqual(cw.magnitudeDB[3], (0 * 1 + -6 * 0.25) / 1.25, accuracy: 1e-9)
        XCTAssertEqual(cw.coherence[3], 0.625, accuracy: 1e-9)
        let pw = averageTransferFunctions([a, b], mode: .power)
        XCTAssertEqual(pw.magnitudeDB[3], powerToDB((1 + pow(10, -0.6)) / 2), accuracy: 1e-9)
        // Equal magnitudes at 0 and 90 degrees average to 45.
        let c = result(db: 0, phase: 90, coherence: 1)
        XCTAssertEqual(averageTransferFunctions([a, c], mode: .power).phaseDegrees[0], 45, accuracy: 1e-9)
    }

    func testRoutingValidation() {
        var r = ChannelRouting()
        r.spectrumChannels = [5, 1, 1]
        r.reference = 1
        r.measurementChannels = [0, 1, 2, 2, 7]
        let v = r.validated(channelCount: 3)
        XCTAssertEqual(v.spectrumChannels, [1])
        XCTAssertEqual(v.reference, 1)
        XCTAssertEqual(v.measurementChannels, [0, 2])
    }

    func testEngineAveragesTwoMics() {
        let fs = 48_000.0
        let engine = AnalysisEngine(sampleRate: fs, channelCount: 3)
        var routing = ChannelRouting()
        routing.measurementChannels = [1, 2]
        routing.transferAverage = .power
        engine.routing = routing
        XCTAssertEqual(engine.transferFunctions.count, 2)

        var state: UInt64 = 7
        let n = Int(8 * fs)
        let ref: [Float] = (0..<n).map { _ in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Float(Double(state >> 11) / Double(1 << 53) - 0.5)
        }
        let mic1: [Float] = (0..<n).map { $0 >= 10 ? 0.5 * ref[$0 - 10] : 0 }
        let mic2: [Float] = (0..<n).map { $0 >= 40 ? 0.25 * ref[$0 - 40] : 0 }
        func feed(_ range: Range<Int>) {
            ref.withUnsafeBufferPointer { r in
                mic1.withUnsafeBufferPointer { a in
                    mic2.withUnsafeBufferPointer { b in
                        var i = range.lowerBound
                        while i < range.upperBound {
                            let len = min(1024, range.upperBound - i)
                            engine.process(channels: [r.baseAddress! + i, a.baseAddress! + i, b.baseAddress! + i], frameCount: len)
                            i += len
                        }
                    }
                }
            }
        }
        feed(0..<(n / 2))
        engine.findAndApplyDelay()
        XCTAssertEqual(engine.transferFunctions.map(\.delayCompensation), [10, 40])
        feed((n / 2)..<n)
        let s = engine.snapshot
        XCTAssertEqual(s.transferFunctionsPerMic.count, 2)
        guard let tf = s.transferFunction else { return XCTFail("no transfer function") }
        let k = tf.frequencies.firstIndex { $0 >= 1000 }!
        XCTAssertEqual(tf.magnitudeDB[k], powerToDB((0.25 + 0.0625) / 2), accuracy: 0.3)
        XCTAssertEqual(tf.phaseDegrees[k], 0, accuracy: 5)
        XCTAssertGreaterThan(tf.coherence[k], 0.95)
    }
}
