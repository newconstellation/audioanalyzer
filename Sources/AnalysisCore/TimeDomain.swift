import Foundation

// MARK: - Oscilloscope

public enum TriggerMode: String, Sendable, CaseIterable, Codable {
    /// Always shows the latest samples.
    case free
    /// Starts the trace where the signal crosses the level going up.
    case rising
    /// Starts the trace where the signal crosses the level going down.
    case falling
}

public struct ScopeSettings: Sendable, Equatable, Codable {
    public var mode: TriggerMode = .rising
    /// Trigger level, as a linear sample value (-1...1).
    public var level: Double = 0
    /// Samples shown per trace.
    public var length: Int = 960
    /// Fraction of the trace shown before the trigger point.
    public var preTrigger: Double = 0.1
    public init() {}
}

public struct ScopeTrace: Sendable {
    public var channels: [[Float]] = []
    /// Index of the trigger point within each trace, or nil if it free-ran.
    public var triggerIndex: Int?
    public var sampleRate: Double = 0
    public init() {}
}

/// Finds a trigger point in `trigger` and returns `length` samples of every
/// channel around it. Looks for the most recent crossing that still has a
/// full trace after it; with no crossing (or in free mode) returns the latest
/// samples. All channels must be the same length.
public func captureScope(_ channels: [[Float]], triggerChannel: Int = 0, settings: ScopeSettings,
                         sampleRate: Double) -> ScopeTrace {
    var trace = ScopeTrace()
    trace.sampleRate = sampleRate
    guard let first = channels.first, settings.length > 0, first.count >= settings.length else { return trace }
    let n = first.count, len = settings.length
    let pre = Int(Double(len) * min(max(settings.preTrigger, 0), 0.9))
    var start = n - len

    if settings.mode != .free, triggerChannel < channels.count {
        let x = channels[triggerChannel], level = Float(settings.level)
        // Newest crossing at index i such that i - pre >= 0 and i - pre + len <= n.
        var i = n - len + pre
        while i >= max(pre, 1) {
            let crossed = settings.mode == .rising ? (x[i - 1] < level && x[i] >= level)
                                                   : (x[i - 1] > level && x[i] <= level)
            if crossed {
                start = i - pre
                trace.triggerIndex = pre
                break
            }
            i -= 1
        }
    }
    trace.channels = channels.map { Array($0[start..<(start + len)]) }
    return trace
}

// MARK: - Rolling histories

/// A fixed-capacity history of values, oldest first.
public struct History<Element: Sendable>: Sendable {
    public let capacity: Int
    public private(set) var values: [Element] = []

    public init(capacity: Int) {
        self.capacity = max(1, capacity)
        values.reserveCapacity(self.capacity)
    }

    public mutating func append(_ v: Element) {
        if values.count == capacity { values.removeFirst() }
        values.append(v)
    }

    public mutating func removeAll() { values.removeAll(keepingCapacity: true) }
}

/// Peak and RMS level over one history step, in dBFS.
public struct PowerPoint: Sendable, Equatable {
    public var peakDB: Double
    public var rmsDB: Double
}

/// Reduces a spectrum (dB per bin) to `columns` log-spaced columns from
/// `minFrequency` to `maxFrequency`, taking the maximum in each column, for
/// compact waterfall rows.
public func logReduce(_ spectrumDB: [Double], binWidth: Double, columns: Int,
                      minFrequency: Double = 20, maxFrequency: Double = 20000) -> [Float] {
    guard spectrumDB.count > 1, columns > 0, binWidth > 0 else { return [] }
    var out = [Float](repeating: Float(floorDB), count: columns)
    let ratio = log(maxFrequency / minFrequency)
    for c in 0..<columns {
        let f0 = minFrequency * exp(ratio * Double(c) / Double(columns))
        let f1 = minFrequency * exp(ratio * Double(c + 1) / Double(columns))
        var lo = Int((f0 / binWidth).rounded(.down)), hi = Int((f1 / binWidth).rounded(.up))
        lo = max(1, min(lo, spectrumDB.count - 1))
        hi = max(lo, min(hi, spectrumDB.count - 1))
        var m = -Double.infinity
        for k in lo...hi { m = max(m, spectrumDB[k]) }
        out[c] = Float(m)
    }
    return out
}
