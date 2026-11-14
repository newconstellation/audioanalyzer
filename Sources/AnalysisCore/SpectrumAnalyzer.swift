import Accelerate
import Foundation

/// Windowed real FFT giving magnitude per bin in dBFS, calibrated so that a
/// full-scale sine centred on a bin reads 0 dBFS.
public final class SpectrumAnalyzer {
    public let fftSize: Int
    public let sampleRate: Double
    public let window: WindowFunction

    private let dft: vDSP.DFT<Float>
    private let windowCoefficients: [Float]
    private var scale: Float = 1
    private var evens: [Float], odds: [Float]
    private var outReal: [Float], outImag: [Float]
    private var windowed: [Float]

    /// Valid sizes are powers of two from 32 to 65536.
    public init?(fftSize: Int, window: WindowFunction = .hann, sampleRate: Double) {
        guard fftSize >= 32, fftSize <= 65536, fftSize & (fftSize - 1) == 0,
              let dft = vDSP.DFT(count: fftSize, direction: .forward,
                                 transformType: .complexReal, ofType: Float.self)
        else { return nil }
        self.fftSize = fftSize
        self.sampleRate = sampleRate
        self.window = window
        self.dft = dft
        windowCoefficients = window.coefficients(count: fftSize)
        let half = fftSize / 2
        evens = .init(repeating: 0, count: half)
        odds = .init(repeating: 0, count: half)
        outReal = .init(repeating: 0, count: half)
        outImag = .init(repeating: 0, count: half)
        windowed = .init(repeating: 0, count: fftSize)

        // Self-calibrate: whatever scaling vDSP and the window apply, a unit
        // sine on bin N/8 must come out with magnitude 1.
        let bin = fftSize / 8
        let probe = (0..<fftSize).map { Float(sin(2 * Double.pi * Double(bin * $0) / Double(fftSize))) }
        let raw = probe.withUnsafeBufferPointer { magnitudes($0) }
        scale = 1 / raw[bin]
    }

    /// Number of output bins: DC through Nyquist.
    public var binCount: Int { fftSize / 2 + 1 }
    public var binWidth: Double { sampleRate / Double(fftSize) }
    public func frequency(ofBin bin: Int) -> Double { Double(bin) * binWidth }

    /// Linear magnitudes (1.0 = full-scale sine) for the last `fftSize` samples.
    public func magnitudes(_ samples: UnsafeBufferPointer<Float>) -> [Float] {
        precondition(samples.count >= fftSize, "need at least fftSize samples")
        let start = samples.count - fftSize
        let input = UnsafeBufferPointer(rebasing: samples[start...])
        vDSP.multiply(input, windowCoefficients, result: &windowed)
        let half = fftSize / 2
        for i in 0..<half {
            evens[i] = windowed[2 * i]
            odds[i] = windowed[2 * i + 1]
        }
        dft.transform(inputReal: evens, inputImaginary: odds,
                      outputReal: &outReal, outputImaginary: &outImag)
        var mags = [Float](repeating: 0, count: half + 1)
        // Packed format: real[0] = DC, imag[0] = Nyquist. Those two bins are
        // not doubled like the others, so halve them to keep one scale.
        mags[0] = abs(outReal[0]) * scale / 2
        mags[half] = abs(outImag[0]) * scale / 2
        for k in 1..<half {
            mags[k] = (outReal[k] * outReal[k] + outImag[k] * outImag[k]).squareRoot() * scale
        }
        return mags
    }

    /// Magnitudes in dBFS.
    public func spectrumDB(_ samples: UnsafeBufferPointer<Float>) -> [Double] {
        magnitudes(samples).map { amplitudeToDB(Double($0)) }
    }
}

/// Averaging and peak hold across successive spectra, done on power.
public struct SpectrumAverager: Sendable {
    public enum Mode: Sendable, Equatable {
        case none
        /// Exponential average with the given time constant, in seconds.
        case exponential(seconds: Double)
    }

    public var mode: Mode
    public private(set) var averageDB: [Double] = []
    public private(set) var peakDB: [Double] = []
    private var avgPower: [Double] = []

    public init(mode: Mode = .exponential(seconds: 0.5)) { self.mode = mode }

    /// `updateInterval` is the time between spectra, in seconds.
    public mutating func add(_ spectrumDB: [Double], updateInterval: Double) {
        let power = spectrumDB.map { pow(10, $0 / 10) }
        if avgPower.count != power.count {
            avgPower = power
            peakDB = spectrumDB
        } else {
            let k: Double
            switch mode {
            case .none: k = 1
            case let .exponential(seconds): k = onePoleCoefficient(tau: seconds, sampleRate: 1 / updateInterval)
            }
            for i in power.indices {
                avgPower[i] += k * (power[i] - avgPower[i])
                peakDB[i] = max(peakDB[i], spectrumDB[i])
            }
        }
        averageDB = avgPower.map(powerToDB)
    }

    public mutating func reset() {
        avgPower = []; averageDB = []; peakDB = []
    }
}
