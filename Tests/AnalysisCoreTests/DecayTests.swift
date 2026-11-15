import AnalysisCore
import XCTest

final class DecayTests: XCTestCase {
    private let fs = 48_000.0

    /// A click plus a 1 kHz mode decaying with a 10 ms time constant.
    private func ringingImpulse() -> ImpulseResponse {
        let n = 16384, start = 256, tau = 0.010
        var x = [Float](repeating: 0, count: n)
        x[start] = 2
        for i in 0..<(n - start) {
            let t = Double(i) / fs
            x[start + i] += Float(0.5 * exp(-t / tau) * sin(2 * .pi * 1000 * t))
        }
        return ImpulseResponse(samples: x, sampleRate: fs, zeroIndex: start)
    }

    func testResonanceDecaysAtItsRate() {
        var s = DecaySettings()
        s.rangeMs = 20
        s.slices = 3 // 0, 10, 20 ms
        s.windowMs = 150
        let ir = ringingImpulse()
        XCTAssertEqual(ir.peakIndex, 256)
        let d = cumulativeSpectralDecay(ir, settings: s)
        XCTAssertEqual(d.timesMs, [0, 10, 20])
        XCTAssertEqual(d.slicesDB.count, 3)
        XCTAssertEqual(d.slicesDB[0].count, s.columns)
        XCTAssertEqual(d.slicesDB[0].max() ?? 1, 0, accuracy: 1e-9)

        let column = Int(Double(s.columns) * log(1000 / s.minFrequency) / log(s.maxFrequency / s.minFrequency))
        // exp(-t / tau) in amplitude: 8.69 dB per time constant.
        let drop10 = d.slicesDB[0][column] - d.slicesDB[1][column]
        let drop20 = d.slicesDB[0][column] - d.slicesDB[2][column]
        XCTAssertEqual(drop10, 8.69, accuracy: 1.5)
        XCTAssertEqual(drop20, 17.37, accuracy: 2)
        // Away from the mode only the click is there, and it's gone after time zero.
        let far = Int(Double(s.columns) * log(8000 / s.minFrequency) / log(s.maxFrequency / s.minFrequency))
        XCTAssertGreaterThan(d.slicesDB[0][far] - d.slicesDB[1][far], 12)
    }

    func testTransferFunctionImpulseOfAPureDelay() throws {
        let tf = try XCTUnwrap(TransferFunctionAnalyzer(fftSize: 4096, sampleRate: fs, maxAverages: 8))
        let delay = 37
        var state: UInt64 = 99
        let n = 4096 * 6
        let source: [Float] = (0..<n).map { _ in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Float(Double(state >> 11) / Double(1 << 53) - 0.5)
        }
        let response: [Float] = (0..<n).map { $0 >= delay ? 0.5 * source[$0 - delay] : 0 }
        source.withUnsafeBufferPointer { s in
            response.withUnsafeBufferPointer { r in tf.process(source: s, response: r) }
        }
        let ir = try XCTUnwrap(tf.impulseResponse(preDelay: 100))
        XCTAssertEqual(ir.samples.count, 4096)
        XCTAssertEqual(ir.zeroIndex, 100)
        XCTAssertEqual(ir.peakIndex, 100 + delay)
        XCTAssertEqual(Double(ir.samples[ir.peakIndex]), 0.5, accuracy: 0.05)
    }
}
