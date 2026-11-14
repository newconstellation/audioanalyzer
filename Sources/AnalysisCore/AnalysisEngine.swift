import Foundation

/// Everything the window draws, captured at one moment.
public struct AnalyzerSnapshot: Sendable {
    public var levels: [LevelReading] = []
    public var spectrumDB: [Double] = []
    public var spectrumPeakDB: [Double] = []
    public var binWidth: Double = 1
    public var correlation: Double = 0
    public var balance: Double = 0
    public var sampleRate: Double = 0

    public init() {}
}

/// Runs all the instruments over blocks of multichannel audio. Used by the live
/// app and by the offline renderer, so both show exactly the same analysis.
/// Not thread-safe: feed and read it from one thread at a time.
public final class AnalysisEngine {
    public let sampleRate: Double
    public let channelCount: Int

    private let meters: [LevelMeter]
    private let correlationMeter: CorrelationMeter?
    private let analyzer: SpectrumAnalyzer?
    private var averager = SpectrumAverager(mode: .exponential(seconds: 0.3))
    private var history: [Float] = []

    public init(sampleRate: Double, channelCount: Int, fftSize: Int = 8192) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        meters = (0..<channelCount).map { _ in LevelMeter(sampleRate: sampleRate) }
        correlationMeter = channelCount >= 2 ? CorrelationMeter(sampleRate: sampleRate) : nil
        analyzer = SpectrumAnalyzer(fftSize: fftSize, window: .hann, sampleRate: sampleRate)
    }

    /// `channels[c]` points at `frameCount` samples for channel `c`.
    public func process(channels: [UnsafePointer<Float>], frameCount n: Int) {
        guard n > 0 else { return }
        for (c, meter) in meters.enumerated() where c < channels.count {
            meter.process(UnsafeBufferPointer(start: channels[c], count: n))
        }
        if let corr = correlationMeter, channels.count >= 2 {
            corr.process(left: UnsafeBufferPointer(start: channels[0], count: n),
                         right: UnsafeBufferPointer(start: channels[1], count: n))
        }
        // Spectrum of channel 1 (channel routing comes later).
        if let analyzer, let first = channels.first {
            history.append(contentsOf: UnsafeBufferPointer(start: first, count: n))
            if history.count > analyzer.fftSize {
                history.removeFirst(history.count - analyzer.fftSize)
            }
            if history.count == analyzer.fftSize {
                let spectrum = history.withUnsafeBufferPointer { analyzer.spectrumDB($0) }
                averager.add(spectrum, updateInterval: Double(n) / sampleRate)
            }
        }
    }

    public var snapshot: AnalyzerSnapshot {
        var s = AnalyzerSnapshot()
        s.levels = meters.map(\.reading)
        s.spectrumDB = averager.averageDB
        s.spectrumPeakDB = averager.peakDB
        s.binWidth = analyzer?.binWidth ?? 1
        s.correlation = correlationMeter?.correlation ?? 0
        s.balance = correlationMeter?.balance ?? 0
        s.sampleRate = sampleRate
        return s
    }

    public func resetPeaks() {
        meters.forEach { $0.reset() }
        correlationMeter?.reset()
        averager.reset()
    }
}
