import Accelerate
import Foundation

/// One transfer-function measurement: how the response channel relates to the
/// source channel at each frequency.
public struct TransferFunctionResult: Sendable {
    /// Bin centre frequencies, bin 1 to Nyquist - 1.
    public var frequencies: [Double] = []
    /// Response / source level, in dB.
    public var magnitudeDB: [Double] = []
    /// Response phase relative to source, in degrees, wrapped to -180...180.
    public var phaseDegrees: [Double] = []
    /// Magnitude-squared coherence, 0 (unrelated) to 1 (fully explained by the source).
    public var coherence: [Double] = []
    /// Delay currently removed from the response before analysis, in samples.
    public var delayCompensationSamples: Int = 0
    public var sampleRate: Double = 0
    /// Frames averaged so far.
    public var averages: Int = 0

    public init() {}
}

/// Dual-channel FFT transfer function (H1 estimator) with coherence and a
/// delay finder. Works with any source signal that has energy at the
/// frequencies of interest: noise, sweeps, or programme material.
///
/// Feed it matching blocks of source and response with `process`. Frames of
/// `fftSize` samples with 50% overlap are Hann-windowed; the auto- and cross-
/// spectra are averaged (linear up to `maxAverages`, exponential after).
/// Not thread-safe.
public final class TransferFunctionAnalyzer {
    public let fftSize: Int
    public let sampleRate: Double
    public var maxAverages: Int

    /// Samples the response is delayed by before comparing, so a system's
    /// latency doesn't show as phase wrap and lost coherence. Negative values
    /// delay the source instead. Limited to +/- fftSize.
    public var delayCompensation: Int = 0 {
        didSet { delayCompensation = max(-fftSize, min(fftSize, delayCompensation)) }
    }

    private let fft: SpectrumAnalyzer
    private let inverse: vDSP.DFT<Float>
    private var source: [Float] = []
    private var response: [Float] = []
    private var readPosition = 0
    private var gxx: [Double], gyy: [Double], gxyRe: [Double], gxyIm: [Double]
    private var frames = 0

    public init?(fftSize: Int = 16384, sampleRate: Double, maxAverages: Int = 16) {
        guard let fft = SpectrumAnalyzer(fftSize: fftSize, window: .hann, sampleRate: sampleRate),
              let inverse = vDSP.DFT(count: fftSize, direction: .inverse,
                                     transformType: .complexComplex, ofType: Float.self)
        else { return nil }
        self.fftSize = fftSize
        self.sampleRate = sampleRate
        self.maxAverages = maxAverages
        self.fft = fft
        self.inverse = inverse
        let bins = fftSize / 2 + 1
        gxx = .init(repeating: 0, count: bins)
        gyy = .init(repeating: 0, count: bins)
        gxyRe = .init(repeating: 0, count: bins)
        gxyIm = .init(repeating: 0, count: bins)
    }

    public var binWidth: Double { sampleRate / Double(fftSize) }

    public func reset() {
        source = []; response = []; readPosition = 0; frames = 0
        for i in gxx.indices { gxx[i] = 0; gyy[i] = 0; gxyRe[i] = 0; gxyIm[i] = 0 }
    }

    /// Clears the averages but keeps the buffered audio.
    public func resetAverages() {
        frames = 0
        for i in gxx.indices { gxx[i] = 0; gyy[i] = 0; gxyRe[i] = 0; gxyIm[i] = 0 }
    }

    public func process(source s: UnsafeBufferPointer<Float>, response r: UnsafeBufferPointer<Float>) {
        precondition(s.count == r.count)
        source.append(contentsOf: s)
        response.append(contentsOf: r)

        let hop = fftSize / 2
        let sourceOffset = max(0, -delayCompensation)
        let responseOffset = max(0, delayCompensation)
        while readPosition + sourceOffset + fftSize <= source.count,
              readPosition + responseOffset + fftSize <= response.count {
            let a = readPosition + sourceOffset, b = readPosition + responseOffset
            let x = source.withUnsafeBufferPointer { fft.complexSpectrum(UnsafeBufferPointer(rebasing: $0[a..<(a + fftSize)])) }
            let y = response.withUnsafeBufferPointer { fft.complexSpectrum(UnsafeBufferPointer(rebasing: $0[b..<(b + fftSize)])) }
            accumulate(x, y)
            readPosition += hop
        }

        // Drop audio that no future frame needs.
        if readPosition > 4 * fftSize {
            source.removeFirst(readPosition)
            response.removeFirst(readPosition)
            readPosition = 0
        }
    }

    private func accumulate(_ x: (re: [Float], im: [Float]), _ y: (re: [Float], im: [Float])) {
        frames += 1
        let k = 1 / Double(min(frames, maxAverages))
        for i in gxx.indices {
            let xr = Double(x.re[i]), xi = Double(x.im[i])
            let yr = Double(y.re[i]), yi = Double(y.im[i])
            gxx[i] += k * (xr * xr + xi * xi - gxx[i])
            gyy[i] += k * (yr * yr + yi * yi - gyy[i])
            // conj(X) * Y
            gxyRe[i] += k * (xr * yr + xi * yi - gxyRe[i])
            gxyIm[i] += k * (xr * yi - xi * yr - gxyIm[i])
        }
    }

    public var result: TransferFunctionResult {
        var r = TransferFunctionResult()
        r.sampleRate = sampleRate
        r.delayCompensationSamples = delayCompensation
        r.averages = frames
        guard frames > 0 else { return r }
        let half = fftSize / 2
        r.frequencies.reserveCapacity(half - 1)
        for i in 1..<half {
            let cross2 = gxyRe[i] * gxyRe[i] + gxyIm[i] * gxyIm[i]
            r.frequencies.append(Double(i) * binWidth)
            // |H|^2 = |Gxy|^2 / Gxx^2, so its power in dB is 20 log10 |H|.
            r.magnitudeDB.append(gxx[i] > 0 ? powerToDB(cross2 / (gxx[i] * gxx[i])) : floorDB)
            r.phaseDegrees.append(atan2(gxyIm[i], gxyRe[i]) * 180 / .pi)
            let denom = gxx[i] * gyy[i]
            r.coherence.append(denom > 0 ? min(1, cross2 / denom) : 0)
        }
        return r
    }

    /// The impulse response from the averaged transfer function (H1 =
    /// Gxy / Gxx, inverse FFT), `fftSize` samples long. It is rotated so the
    /// first `preDelay` samples come before time zero (after delay
    /// compensation), which keeps any pre-ringing visible. Nil before any data.
    public func impulseResponse(preDelay: Int = 256) -> ImpulseResponse? {
        guard frames > 0 else { return nil }
        let n = fftSize, half = n / 2
        var re = [Float](repeating: 0, count: n), im = [Float](repeating: 0, count: n)
        for i in 0...half where gxx[i] > 0 {
            re[i] = Float(gxyRe[i] / gxx[i])
            im[i] = Float(gxyIm[i] / gxx[i])
            if i > 0 && i < half {
                re[n - i] = re[i]
                im[n - i] = -im[i]
            }
        }
        im[0] = 0; im[half] = 0
        var outRe = [Float](repeating: 0, count: n), outIm = [Float](repeating: 0, count: n)
        inverse.transform(inputReal: re, inputImaginary: im, outputReal: &outRe, outputImaginary: &outIm)
        let pre = max(0, min(preDelay, n / 2))
        let scale = 1 / Float(n)
        let samples = (0..<n).map { k in outRe[(k - pre + n) % n] * scale }
        return ImpulseResponse(samples: samples, sampleRate: sampleRate, zeroIndex: pre)
    }

    /// Estimates the remaining delay of the response relative to the source,
    /// in samples (fractional), from the averaged cross-spectrum using
    /// coherence-weighted phase transform (GCC-PHAT). Add it to
    /// `delayCompensation` to align the channels. Nil before any data.
    public func findDelay() -> Double? {
        guard frames > 0 else { return nil }
        let n = fftSize, half = n / 2
        var re = [Float](repeating: 0, count: n), im = [Float](repeating: 0, count: n)
        for i in 1..<half {
            let mag = (gxyRe[i] * gxyRe[i] + gxyIm[i] * gxyIm[i]).squareRoot()
            let denom = gxx[i] * gyy[i]
            guard mag > 0, denom > 0 else { continue }
            let w = min(1, mag * mag / denom) / mag
            re[i] = Float(gxyRe[i] * w)
            im[i] = Float(gxyIm[i] * w)
            re[n - i] = re[i]
            im[n - i] = -im[i]
        }
        var outRe = [Float](repeating: 0, count: n), outIm = [Float](repeating: 0, count: n)
        inverse.transform(inputReal: re, inputImaginary: im, outputReal: &outRe, outputImaginary: &outIm)
        guard let peak = outRe.indices.max(by: { outRe[$0] < outRe[$1] }), outRe[peak] > 0 else { return nil }
        // Parabolic interpolation around the peak.
        let a = Double(outRe[(peak - 1 + n) % n]), b = Double(outRe[peak]), c = Double(outRe[(peak + 1) % n])
        let d = a - 2 * b + c
        let frac = d != 0 ? 0.5 * (a - c) / d : 0
        let lag = Double(peak) + frac
        return lag > Double(half) ? lag - Double(n) : lag
    }
}
