import Foundation

/// How several mics' measurements are combined into one trace.
public enum SpatialAverage: String, Sendable, CaseIterable, Codable {
    /// Mean of power (linear magnitude squared).
    case power = "Power"
    /// Each trace is first shifted to a common level over a mid band (125 Hz
    /// to 4 kHz for spectra, relative to the first mic; 225 Hz to 8.8 kHz for
    /// transfer functions, to 0 dB), then power averaged. Takes out level
    /// differences between mic positions.
    case normalizedPower = "Normalised power"
    /// Transfer functions only: mean of dB magnitude with every point weighted
    /// by its coherence, so comb-filter nulls, reverberant and noisy points
    /// count for less. Spectra fall back to power averaging.
    case coherenceWeighted = "Coherence-weighted dB"
}

/// Which inputs feed which measurements.
public struct ChannelRouting: Sendable, Equatable, Codable {
    /// Inputs averaged for the spectrum, octave and THD pages (THD uses the first).
    public var spectrumChannels: [Int] = [0]
    public var spectrumAverage: SpatialAverage = .power
    /// The transfer function's reference (source) input.
    public var reference: Int = 0
    /// Measurement mic inputs, each with its own transfer function and delay,
    /// averaged into one.
    public var measurementChannels: [Int] = [1]
    public var transferAverage: SpatialAverage = .coherenceWeighted

    public init() {}

    /// Removes out-of-range and duplicate channels, and the reference from the
    /// measurement list; keeps at least one spectrum channel.
    public func validated(channelCount: Int) -> ChannelRouting {
        var r = self
        func clean(_ list: [Int]) -> [Int] {
            var seen = Set<Int>()
            return list.filter { $0 >= 0 && $0 < channelCount && seen.insert($0).inserted }
        }
        r.spectrumChannels = clean(spectrumChannels)
        if r.spectrumChannels.isEmpty { r.spectrumChannels = [0] }
        r.reference = min(max(reference, 0), max(channelCount - 1, 0))
        r.measurementChannels = clean(measurementChannels).filter { $0 != r.reference }
        return r
    }
}

private func meanDB(_ db: [Double], binWidth: Double, band: ClosedRange<Double>) -> Double? {
    guard binWidth > 0 else { return nil }
    let lo = max(1, Int((band.lowerBound / binWidth).rounded(.up)))
    let hi = min(db.count - 1, Int((band.upperBound / binWidth).rounded(.down)))
    guard lo <= hi else { return nil }
    return db[lo...hi].reduce(0, +) / Double(hi - lo + 1)
}

/// Averages spectra (dB per bin, all the same length).
public func averageSpectra(_ spectra: [[Double]], binWidth: Double, mode: SpatialAverage) -> [Double] {
    guard let first = spectra.first else { return [] }
    guard spectra.count > 1 else { return first }
    var shifts = [Double](repeating: 0, count: spectra.count)
    if mode == .normalizedPower, let ref = meanDB(first, binWidth: binWidth, band: 125...4000) {
        for (i, s) in spectra.enumerated() {
            if let m = meanDB(s, binWidth: binWidth, band: 125...4000) { shifts[i] = ref - m }
        }
    }
    return first.indices.map { k in
        var sum = 0.0
        for (i, s) in spectra.enumerated() where k < s.count { sum += pow(10, (s[k] + shifts[i]) / 10) }
        return powerToDB(sum / Double(spectra.count))
    }
}

/// Averages transfer functions measured at several mics (all the same
/// frequencies). Magnitude per `mode`; phase from the complex average (each
/// mic's response as a vector); coherence is the mean.
public func averageTransferFunctions(_ results: [TransferFunctionResult], mode: SpatialAverage) -> TransferFunctionResult {
    guard var out = results.first else { return TransferFunctionResult() }
    guard results.count > 1 else { return out }
    let bins = results.map(\.frequencies.count).min() ?? 0
    let n = Double(results.count)
    let binWidth = bins > 1 ? out.frequencies[1] - out.frequencies[0] : 0
    // TransferFunctionResult starts at bin 1, so index = bin - 1.
    let shifts: [Double] = results.map { r in
        guard mode == .normalizedPower, binWidth > 0 else { return 0 }
        let lo = max(0, Int((225 / binWidth).rounded(.up)) - 1)
        let hi = min(bins - 1, Int((8800 / binWidth).rounded(.down)) - 1)
        guard lo <= hi else { return 0 }
        return -r.magnitudeDB[lo...hi].reduce(0, +) / Double(hi - lo + 1)
    }
    out.frequencies = Array(out.frequencies.prefix(bins))
    out.magnitudeDB = []
    out.phaseDegrees = []
    out.coherence = []
    out.averages = results.map(\.averages).min() ?? 0
    for k in 0..<bins {
        var re = 0.0, im = 0.0, power = 0.0, wSum = 0.0, wdB = 0.0, coh = 0.0
        for (i, r) in results.enumerated() {
            let db = r.magnitudeDB[k] + shifts[i]
            let a = pow(10, r.magnitudeDB[k] / 20), phi = r.phaseDegrees[k] * .pi / 180
            re += a * cos(phi); im += a * sin(phi)
            power += pow(10, db / 10)
            let w = max(r.coherence[k], 1e-3)
            wSum += w; wdB += w * db
            coh += r.coherence[k]
        }
        out.magnitudeDB.append(mode == .coherenceWeighted ? wdB / wSum : powerToDB(power / n))
        out.phaseDegrees.append(atan2(im, re) * 180 / .pi)
        out.coherence.append(coh / n)
    }
    return out
}
