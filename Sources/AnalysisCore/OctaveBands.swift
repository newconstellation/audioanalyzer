import Foundation

/// Fractional-octave bands per IEC 61260-1 (base-10 octave ratio G = 10^0.3).
public enum OctaveFraction: Int, Sendable, CaseIterable, Codable {
    case octave = 1
    case third = 3
    case sixth = 6
    case twelfth = 12

    public var label: String {
        switch self {
        case .octave: "Octave"
        case .third: "1/3 octave"
        case .sixth: "1/6 octave"
        case .twelfth: "1/12 octave"
        }
    }
}

public struct OctaveBand: Sendable, Equatable {
    /// Exact mid-band frequency.
    public var center: Double
    public var lower: Double
    public var upper: Double
    /// Nominal frequency for labels (31.5, 63, 125, ... for octaves).
    public var nominal: Double
}

/// The bands whose mid-band frequency falls within `range`, lowest first.
public func octaveBands(_ fraction: OctaveFraction, in range: ClosedRange<Double> = 20...20000) -> [OctaveBand] {
    let b = Double(fraction.rawValue)
    let g = pow(10, 0.3)
    // Mid-band frequencies are 1 kHz * G^(x/b) for odd b, G^((2x+1)/(2b)) for even b.
    func center(_ x: Int) -> Double {
        fraction.rawValue % 2 == 1 ? 1000 * pow(g, Double(x) / b) : 1000 * pow(g, (2 * Double(x) + 1) / (2 * b))
    }
    let lo = Int((log(range.lowerBound / 1000) / log(g) * b).rounded(.down)) - 1
    let hi = Int((log(range.upperBound / 1000) / log(g) * b).rounded(.up)) + 1
    return (lo...hi).compactMap { x in
        let fm = center(x)
        guard fm >= range.lowerBound * 0.99, fm <= range.upperBound * 1.01 else { return nil }
        let edge = pow(g, 1 / (2 * b))
        return OctaveBand(center: fm, lower: fm / edge, upper: fm * edge, nominal: nominalFrequency(fm))
    }
}

/// Rounds an exact mid-band frequency to the familiar label: the R10
/// preferred numbers for octave and third-octave bands, three significant
/// figures otherwise.
public func nominalFrequency(_ f: Double) -> Double {
    let decade = pow(10, floor(log10(f)))
    let m = f / decade
    let r10: [Double] = [1, 1.25, 1.6, 2, 2.5, 3.15, 4, 5, 6.3, 8, 10]
    if let near = r10.first(where: { abs($0 / m - 1) < 0.015 }) { return near * decade }
    let digits = pow(10, floor(log10(f)) - 2)
    return (f / digits).rounded() * digits
}

/// Short label: "31.5", "1k", "12.5k".
public func frequencyLabel(_ f: Double) -> String {
    func trim(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%.3g", v)
    }
    return f >= 1000 ? trim(f / 1000) + "k" : trim(f)
}

/// Integrates a spectrum into bands. `spectrumDB` is per bin, calibrated so
/// a sine reads its level (as `SpectrumAnalyzer` produces); `enbwBins` is the
/// window's equivalent noise bandwidth in bins. Each bin is treated as
/// covering ±half a bin and shared between bands by overlap, so narrow low
/// bands (narrower than a bin) still get a sensible share.
///
/// Levels are in dBFS where a full-scale sine is 0 dB: a sine inside a band
/// reads its own level, and noise reads 3 dB above its RMS in dBFS.
public func bandLevels(spectrumDB: [Double], binWidth: Double, enbwBins: Double,
                       bands: [OctaveBand]) -> [Double] {
    guard spectrumDB.count > 1, binWidth > 0, enbwBins > 0 else {
        return Array(repeating: floorDB, count: bands.count)
    }
    let power = spectrumDB.map { pow(10, $0 / 10) }
    return bands.map { band in
        let first = max(1, Int((band.lower / binWidth - 0.5).rounded(.down)))
        let last = min(power.count - 1, Int((band.upper / binWidth + 0.5).rounded(.up)))
        guard first <= last else { return floorDB }
        var sum = 0.0
        for k in first...last {
            let a = (Double(k) - 0.5) * binWidth, b = (Double(k) + 0.5) * binWidth
            let overlap = min(b, band.upper) - max(a, band.lower)
            if overlap > 0 { sum += power[k] * overlap / binWidth }
        }
        return powerToDB(sum / enbwBins)
    }
}
