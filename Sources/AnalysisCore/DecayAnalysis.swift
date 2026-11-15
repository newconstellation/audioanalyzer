import Foundation

/// A measured impulse response.
public struct ImpulseResponse: Sendable {
    public var samples: [Float]
    public var sampleRate: Double
    /// Index of time zero (the samples before it are pre-delay).
    public var zeroIndex: Int

    public init(samples: [Float], sampleRate: Double, zeroIndex: Int = 0) {
        self.samples = samples
        self.sampleRate = sampleRate
        self.zeroIndex = zeroIndex
    }

    /// Index of the largest absolute sample.
    public var peakIndex: Int {
        samples.indices.max { abs(samples[$0]) < abs(samples[$1]) } ?? 0
    }
}

public struct DecaySettings: Sendable, Equatable, Codable {
    /// Time from the impulse peak to the start of the last slice, in ms.
    public var rangeMs: Double = 150
    public var slices: Int = 30
    /// Length of each slice's analysis window, in ms.
    public var windowMs: Double = 150
    /// Half-Hann fade-in at the start of each slice, in ms.
    public var riseMs: Double = 0.5
    /// Fractional-octave smoothing (bands per octave), or nil for none.
    public var smoothing: Int? = 12
    public var columns = 300
    public var minFrequency = 20.0
    public var maxFrequency = 20000.0
    public init() {}
}

/// Cumulative spectral decay: the spectrum of the impulse response from a
/// series of start times onward, showing how each frequency dies away.
public struct DecayResult: Sendable {
    /// Start time of each slice after the impulse peak, in ms.
    public var timesMs: [Double] = []
    /// Per slice: `columns` log-spaced levels from minFrequency to maxFrequency,
    /// in dB relative to the first slice's maximum.
    public var slicesDB: [[Double]] = []
    public var minFrequency = 20.0
    public var maxFrequency = 20000.0
    public init() {}
}

/// Computes a cumulative spectral decay from an impulse response. Each slice
/// starts `riseMs` before its start time with a half-Hann fade-in, then
/// covers `windowMs` with a half-Hann fade-out over the last half. Samples
/// past the end of the response count as zero.
public func cumulativeSpectralDecay(_ ir: ImpulseResponse, settings s: DecaySettings = DecaySettings()) -> DecayResult {
    var out = DecayResult()
    out.minFrequency = s.minFrequency
    out.maxFrequency = s.maxFrequency
    let fs = ir.sampleRate
    guard fs > 0, ir.samples.count > 1, s.slices > 0, s.columns > 0, s.windowMs > 0 else { return out }

    let peak = ir.peakIndex
    let rise = max(0, Int(s.riseMs / 1000 * fs))
    let length = max(16, Int(s.windowMs / 1000 * fs))
    var fftSize = 1024
    while fftSize < rise + length { fftSize *= 2 }
    fftSize = min(fftSize, 65536)
    guard let fft = SpectrumAnalyzer(fftSize: fftSize, window: .rectangular, sampleRate: fs) else { return out }
    let segment = min(rise + length, fftSize)

    // Fixed window: half-Hann up over `rise`, flat, half-Hann down over the last half of `length`.
    let fall = length / 2
    let window: [Float] = (0..<segment).map { i in
        if i < rise { return Float(0.5 - 0.5 * cos(.pi * Double(i) / Double(rise))) }
        let j = i - rise
        if j < length - fall { return 1 }
        let k = Double(j - (length - fall)) / Double(fall)
        return Float(0.5 + 0.5 * cos(.pi * k))
    }

    var frame = [Float](repeating: 0, count: fftSize)
    for k in 0..<s.slices {
        let t = s.slices > 1 ? s.rangeMs * Double(k) / Double(s.slices - 1) : 0
        let start = peak + Int((t / 1000 * fs).rounded()) - rise
        for i in 0..<fftSize {
            let idx = start + i
            frame[i] = i < segment && idx >= 0 && idx < ir.samples.count ? ir.samples[idx] * window[i] : 0
        }
        let db = frame.withUnsafeBufferPointer { fft.spectrumDB($0) }
        out.timesMs.append(t)
        out.slicesDB.append(logColumns(db, binWidth: fft.binWidth, settings: s))
    }
    // Relative to the first slice's maximum.
    let ref = out.slicesDB.first?.max() ?? 0
    out.slicesDB = out.slicesDB.map { $0.map { $0 - ref } }
    return out
}

/// Power-averages bins into log-spaced columns, optionally widening each
/// column to a fractional-octave band around it for smoothing.
private func logColumns(_ db: [Double], binWidth: Double, settings s: DecaySettings) -> [Double] {
    let power = db.map { pow(10, $0 / 10) }
    let ratio = log(s.maxFrequency / s.minFrequency)
    let halfBand = s.smoothing.map { pow(2, 0.5 / Double(max(1, $0))) } ?? 1
    return (0..<s.columns).map { c in
        let f = s.minFrequency * exp(ratio * (Double(c) + 0.5) / Double(s.columns))
        let colLo = s.minFrequency * exp(ratio * Double(c) / Double(s.columns))
        let colHi = s.minFrequency * exp(ratio * Double(c + 1) / Double(s.columns))
        let lo = min(colLo, f / halfBand), hi = max(colHi, f * halfBand)
        let a = max(1, Int((lo / binWidth).rounded()))
        let b = min(power.count - 1, max(a, Int((hi / binWidth).rounded())))
        guard a <= b else { return floorDB }
        var sum = 0.0
        for k in a...b { sum += power[k] }
        return powerToDB(sum / Double(b - a + 1))
    }
}
