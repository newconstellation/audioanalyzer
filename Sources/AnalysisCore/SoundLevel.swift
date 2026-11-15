import Foundation

/// Frequency weightings per IEC 61672-1.
public enum FrequencyWeighting: String, Sendable, CaseIterable, Codable {
    case a = "A"
    case c = "C"
    case z = "Z"
}

/// A, C or Z weighting as a cascade of first-order sections, bilinear
/// transformed from the IEC 61672-1 analogue poles and normalised to 0 dB
/// at 1 kHz. Within class 1 tolerances up to about 12 kHz at 48 kHz
/// sample rate (the bilinear transform compresses the top octave).
public final class WeightingFilter {
    public let weighting: FrequencyWeighting
    public let sampleRate: Double

    private struct Section {
        var b0, b1, a1: Double
        var z = 0.0
        mutating func process(_ x: Double) -> Double {
            let y = b0 * x + z
            z = b1 * x - a1 * y
            return y
        }
    }
    private var sections: [Section] = []
    private var gain = 1.0

    // IEC 61672-1 pole frequencies, Hz.
    static let f1 = 20.598997, f2 = 107.65265, f3 = 737.86223, f4 = 12194.217

    public init(_ weighting: FrequencyWeighting, sampleRate: Double) {
        self.weighting = weighting
        self.sampleRate = sampleRate
        let k = 2 * sampleRate
        func w(_ f: Double) -> Double { 2 * .pi * f }
        // s / (s + w) and w / (s + w), bilinear transformed.
        func highPass(_ wc: Double) -> Section { Section(b0: k / (k + wc), b1: -k / (k + wc), a1: (wc - k) / (k + wc)) }
        func lowPass(_ wc: Double) -> Section { Section(b0: wc / (k + wc), b1: wc / (k + wc), a1: (wc - k) / (k + wc)) }
        switch weighting {
        case .z:
            sections = []
        case .c:
            sections = [highPass(w(Self.f1)), highPass(w(Self.f1)), lowPass(w(Self.f4)), lowPass(w(Self.f4))]
        case .a:
            sections = [highPass(w(Self.f1)), highPass(w(Self.f1)), highPass(w(Self.f2)), highPass(w(Self.f3)),
                        lowPass(w(Self.f4)), lowPass(w(Self.f4))]
        }
        gain = 1 / response(at: 1000)
    }

    /// Magnitude response (linear) of the filter as built, before normalisation.
    private func response(at f: Double) -> Double {
        let theta = 2 * .pi * f / sampleRate
        var mag = 1.0
        for s in sections {
            // (b0 + b1 e^-jθ) / (1 + a1 e^-jθ)
            let nr = s.b0 + s.b1 * cos(theta), ni = -s.b1 * sin(theta)
            let dr = 1 + s.a1 * cos(theta), di = -s.a1 * sin(theta)
            mag *= ((nr * nr + ni * ni) / (dr * dr + di * di)).squareRoot()
        }
        return mag
    }

    /// The normalised response in dB at frequency `f`.
    public func responseDB(at f: Double) -> Double { amplitudeToDB(response(at: f) * gain) }

    public func reset() {
        for i in sections.indices { sections[i].z = 0 }
    }

    @inline(__always)
    public func process(_ x: Double) -> Double {
        var y = x
        for i in sections.indices { y = sections[i].process(y) }
        return y * gain
    }
}

/// One sound level reading, in dB relative to a digital RMS of 1 (add the
/// channel's calibration offset to get dB SPL).
public struct SoundLevelReading: Sendable, Equatable {
    public var weighting: FrequencyWeighting
    /// Exponential time weighting, 125 ms.
    public var fast: Double
    /// Exponential time weighting, 1 s.
    public var slow: Double
    /// Equivalent continuous level since the last reset.
    public var leq: Double
    /// Equivalent level over the most recent `leqPeriodSeconds` (rolling).
    public var periodLeq: Double
    /// Highest Fast level since the last reset.
    public var maxFast: Double
    /// Highest absolute weighted sample since the last reset (a peak level, not RMS).
    public var peak: Double
    /// Seconds integrated into `leq`.
    public var duration: Double

    public static let silent = SoundLevelReading(weighting: .z, fast: floorDB, slow: floorDB, leq: floorDB,
                                                 periodLeq: floorDB, maxFast: floorDB, peak: floorDB, duration: 0)
}

/// Sound level meter for one channel: frequency weighting, Fast and Slow
/// exponential time weighting, Leq (since reset and over a rolling window),
/// maximum Fast level and peak. Not thread-safe.
public final class SoundLevelMeter {
    public let sampleRate: Double
    public var weighting: FrequencyWeighting {
        didSet { if weighting != oldValue { filter = WeightingFilter(weighting, sampleRate: sampleRate); reset() } }
    }
    /// Length of the rolling Leq period, in seconds (resolution 0.1 s, up to hours).
    public var leqPeriodSeconds = 60.0 {
        didSet { blocks.removeAll(); blocksTotal = 0 }
    }

    private var filter: WeightingFilter
    private let fastK, slowK: Double
    private var fast = 0.0, slow = 0.0
    private var sum = 0.0, count = 0
    private var maxFast = 0.0, peak = 0.0
    // Rolling Leq: mean squares of 100 ms blocks, and their running total.
    private var blocks = History<Double>(capacity: 1)
    private var blocksTotal = 0.0
    private var blockSum = 0.0, blockCount = 0

    public init(sampleRate: Double, weighting: FrequencyWeighting = .a) {
        self.sampleRate = sampleRate
        self.weighting = weighting
        filter = WeightingFilter(weighting, sampleRate: sampleRate)
        fastK = onePoleCoefficient(tau: 0.125, sampleRate: sampleRate)
        slowK = onePoleCoefficient(tau: 1, sampleRate: sampleRate)
    }

    public func reset() {
        filter.reset()
        fast = 0; slow = 0; sum = 0; count = 0; maxFast = 0; peak = 0
        blocks.removeAll(); blocksTotal = 0; blockSum = 0; blockCount = 0
    }

    public func process(_ samples: UnsafeBufferPointer<Float>) {
        let blockLength = max(1, Int(sampleRate / 10))
        let maxBlocks = max(1, Int((leqPeriodSeconds * 10).rounded()))
        if blocks.capacity != maxBlocks { blocks = History(capacity: maxBlocks); blocksTotal = 0 }
        // Skip the first 0.1 s of max/peak so the filters' start-up doesn't count.
        let settled = count > blockLength
        for x in samples {
            let y = filter.process(Double(x))
            let y2 = y * y
            fast += fastK * (y2 - fast)
            slow += slowK * (y2 - slow)
            sum += y2
            count += 1
            if settled {
                maxFast = max(maxFast, fast)
                peak = max(peak, abs(y))
            }
            blockSum += y2
            blockCount += 1
            if blockCount == blockLength {
                let ms = blockSum / Double(blockLength)
                if blocks.values.count == blocks.capacity { blocksTotal -= blocks.values[0] }
                blocks.append(ms)
                blocksTotal += ms
                blockSum = 0; blockCount = 0
            }
        }
    }

    public var reading: SoundLevelReading {
        let n = blocks.values.count
        let period = n == 0 ? fast : max(0, blocksTotal) / Double(n)
        return SoundLevelReading(weighting: weighting, fast: powerToDB(fast), slow: powerToDB(slow),
                                 leq: count > 0 ? powerToDB(sum / Double(count)) : floorDB,
                                 periodLeq: powerToDB(period), maxFast: powerToDB(maxFast),
                                 peak: amplitudeToDB(peak), duration: Double(count) / sampleRate)
    }
}

/// Calibrates a channel from a calibrator tone: integrates the Z-weighted
/// level for a few seconds, then gives the offset that makes it read the
/// calibrator's level. Not thread-safe.
public final class LevelCalibrator {
    public let sampleRate: Double
    public let referenceSPL: Double
    public let seconds: Double
    private var sum = 0.0, count = 0
    private var skip: Int

    /// - Parameters:
    ///   - referenceSPL: the calibrator's level, typically 94 or 114 dB SPL.
    ///   - seconds: how long to measure.
    public init(sampleRate: Double, referenceSPL: Double = 94, seconds: Double = 3) {
        self.sampleRate = sampleRate
        self.referenceSPL = referenceSPL
        self.seconds = seconds
        skip = Int(0.2 * sampleRate) // let the signal settle after pressing Calibrate
    }

    public var progress: Double { min(1, Double(count) / (seconds * sampleRate)) }
    public var isDone: Bool { progress >= 1 }

    public func process(_ samples: UnsafeBufferPointer<Float>) {
        for x in samples {
            if skip > 0 { skip -= 1; continue }
            guard !isDone else { return }
            sum += Double(x) * Double(x)
            count += 1
        }
    }

    /// Measured level in dB re digital RMS 1, once done.
    public var measuredDB: Double? { isDone ? powerToDB(sum / Double(count)) : nil }

    /// dB to add to readings (dB re digital RMS 1) to get dB SPL, once done.
    /// Nil if the input was too quiet to be a calibrator (below -60 dB).
    public var offset: Double? {
        guard let m = measuredDB, m > -60 else { return nil }
        return referenceSPL - m
    }
}

/// A- and C-weighted readings of one channel.
public struct ChannelSoundLevel: Sendable, Equatable {
    public var a: SoundLevelReading
    public var c: SoundLevelReading
    public init(a: SoundLevelReading, c: SoundLevelReading) {
        self.a = a
        self.c = c
    }
}

/// One point of SPL history (dB re digital RMS 1; add the calibration offset).
public struct SPLPoint: Sendable, Equatable {
    public var laSlow: Double
    public var lcSlow: Double
    public var laeq: Double
}

/// A calibration in progress (or finished, waiting to be applied).
public struct CalibrationStatus: Sendable, Equatable {
    public var channel: Int
    public var referenceSPL: Double
    public var progress: Double
    public var measuredDB: Double?
    /// The offset it would store; nil until done, or if the input was too quiet.
    public var offset: Double?
}
