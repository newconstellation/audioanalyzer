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
    public var transferFunction: TransferFunctionResult?
    public var distortion: DistortionResult?

    public init() {}
}

/// Runs all the instruments over blocks of multichannel audio. Used by the live
/// app and by the offline renderer, so both show exactly the same analysis.
/// Not thread-safe: feed and read it from one thread at a time.
///
/// Channel roles for now: channel 1 feeds the spectrum and the distortion
/// analyzer; the transfer function uses channel 1 as source and channel 2 as
/// response.
public final class AnalysisEngine {
    public let sampleRate: Double
    public let channelCount: Int

    private let meters: [LevelMeter]
    private let correlationMeter: CorrelationMeter?
    private let analyzer: SpectrumAnalyzer?
    private var averager = SpectrumAverager(mode: .exponential(seconds: 0.3))
    public let transferFunction: TransferFunctionAnalyzer?
    public let distortionAnalyzer: DistortionAnalyzer?
    private var latestDistortion: DistortionResult?
    private var history: [Float] = []
    private let historyLength: Int
    private var samplesSinceDistortion = 0
    /// How often the distortion analysis is refreshed, in seconds.
    public var distortionInterval = 0.1

    public init(sampleRate: Double, channelCount: Int, fftSize: Int = 8192) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        meters = (0..<channelCount).map { _ in LevelMeter(sampleRate: sampleRate) }
        correlationMeter = channelCount >= 2 ? CorrelationMeter(sampleRate: sampleRate) : nil
        analyzer = SpectrumAnalyzer(fftSize: fftSize, window: .hann, sampleRate: sampleRate)
        transferFunction = channelCount >= 2 ? TransferFunctionAnalyzer(sampleRate: sampleRate) : nil
        distortionAnalyzer = DistortionAnalyzer(sampleRate: sampleRate)
        historyLength = max(fftSize, distortionAnalyzer?.fftSize ?? 0)
    }

    /// `channels[c]` points at `frameCount` samples for channel `c`.
    public func process(channels: [UnsafePointer<Float>], frameCount n: Int) {
        guard n > 0 else { return }
        for (c, meter) in meters.enumerated() where c < channels.count {
            meter.process(UnsafeBufferPointer(start: channels[c], count: n))
        }
        if channels.count >= 2 {
            let left = UnsafeBufferPointer(start: channels[0], count: n)
            let right = UnsafeBufferPointer(start: channels[1], count: n)
            correlationMeter?.process(left: left, right: right)
            transferFunction?.process(source: left, response: right)
        }
        guard let first = channels.first else { return }
        history.append(contentsOf: UnsafeBufferPointer(start: first, count: n))
        if history.count > historyLength {
            history.removeFirst(history.count - historyLength)
        }
        if let analyzer, history.count >= analyzer.fftSize {
            let spectrum = history.withUnsafeBufferPointer { analyzer.spectrumDB($0) }
            averager.add(spectrum, updateInterval: Double(n) / sampleRate)
        }
        samplesSinceDistortion += n
        if let distortionAnalyzer, history.count >= distortionAnalyzer.fftSize,
           Double(samplesSinceDistortion) >= distortionInterval * sampleRate {
            samplesSinceDistortion = 0
            latestDistortion = history.withUnsafeBufferPointer { distortionAnalyzer.analyze($0) }
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
        s.transferFunction = transferFunction?.result
        s.distortion = latestDistortion
        return s
    }

    /// Finds the source-to-response delay, applies it, and restarts the
    /// transfer-function averages. Returns the new compensation in samples.
    @discardableResult
    public func findAndApplyDelay() -> Int? {
        guard let tf = transferFunction, let d = tf.findDelay() else { return nil }
        tf.delayCompensation += Int(d.rounded())
        tf.resetAverages()
        return tf.delayCompensation
    }

    public func resetPeaks() {
        meters.forEach { $0.reset() }
        correlationMeter?.reset()
        averager.reset()
        transferFunction?.resetAverages()
    }
}
