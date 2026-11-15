import Foundation

/// Everything the window draws, captured at one moment.
public struct AnalyzerSnapshot: Sendable {
    public var levels: [LevelReading] = []
    public var spectrumDB: [Double] = []
    public var spectrumPeakDB: [Double] = []
    public var binWidth: Double = 1
    /// Fractional-octave bands of the averaged spectrum (and its peak hold), in dBFS.
    public var octaveBands: [OctaveBand] = []
    public var octaveDB: [Double] = []
    public var octavePeakDB: [Double] = []
    public var correlation: Double = 0
    public var balance: Double = 0
    public var sampleRate: Double = 0
    public var transferFunction: TransferFunctionResult?
    public var distortion: DistortionResult?
    public var scope = ScopeTrace()
    public var scopeSettings = ScopeSettings()
    /// Recent channel 1 / channel 2 sample pairs for the vectorscope.
    public var vectorscope: (left: [Float], right: [Float]) = ([], [])
    /// Waterfall rows, oldest first; each is `waterfallColumns` log-spaced columns, 20 Hz to 20 kHz, in dBFS.
    public var waterfall: [[Float]] = []
    public var correlationHistory: [Double] = []
    public var balanceHistory: [Double] = []
    /// Per channel: peak and RMS per history step.
    public var powerHistory: [[PowerPoint]] = []
    /// Seconds between history points (and waterfall rows).
    public var historyStep: Double = 0

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

    // Time-domain instruments and histories.
    public var scopeSettings = ScopeSettings()
    /// Band width for the octave analysis.
    public var octaveFraction = OctaveFraction.third {
        didSet { bands = octaveBands(octaveFraction) }
    }
    private var bands = octaveBands(.third)
    public static let waterfallColumns = 400
    /// Seconds between history points.
    public let historyStep = 0.05
    private var scopeBuffers: [[Float]]
    private let scopeBufferLength: Int
    private var lastSpectrum: [Double] = []
    private var waterfall = History<[Float]>(capacity: 300)
    private var correlationHistory = History<Double>(capacity: 600)
    private var balanceHistory = History<Double>(capacity: 600)
    private var powerHistory: [History<PowerPoint>]
    private var stepPeak: [Float], stepSquares: [Double]
    private var stepSamples = 0

    public init(sampleRate: Double, channelCount: Int, fftSize: Int = 8192) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        meters = (0..<channelCount).map { _ in LevelMeter(sampleRate: sampleRate) }
        correlationMeter = channelCount >= 2 ? CorrelationMeter(sampleRate: sampleRate) : nil
        analyzer = SpectrumAnalyzer(fftSize: fftSize, window: .hann, sampleRate: sampleRate)
        transferFunction = channelCount >= 2 ? TransferFunctionAnalyzer(sampleRate: sampleRate) : nil
        distortionAnalyzer = DistortionAnalyzer(sampleRate: sampleRate)
        historyLength = max(fftSize, distortionAnalyzer?.fftSize ?? 0)
        let scopeChannels = min(2, max(1, channelCount))
        scopeBufferLength = Int(sampleRate / 2)
        scopeBuffers = Array(repeating: [], count: scopeChannels)
        powerHistory = Array(repeating: History(capacity: 600), count: scopeChannels)
        stepPeak = Array(repeating: 0, count: scopeChannels)
        stepSquares = Array(repeating: 0, count: scopeChannels)
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
            lastSpectrum = spectrum
        }
        samplesSinceDistortion += n
        if let distortionAnalyzer, history.count >= distortionAnalyzer.fftSize,
           Double(samplesSinceDistortion) >= distortionInterval * sampleRate {
            samplesSinceDistortion = 0
            latestDistortion = history.withUnsafeBufferPointer { distortionAnalyzer.analyze($0) }
        }
        updateTimeDomain(channels: channels, frameCount: n)
    }

    private func updateTimeDomain(channels: [UnsafePointer<Float>], frameCount n: Int) {
        for c in scopeBuffers.indices {
            let src = UnsafeBufferPointer(start: channels[min(c, channels.count - 1)], count: n)
            scopeBuffers[c].append(contentsOf: src)
            if scopeBuffers[c].count > scopeBufferLength {
                scopeBuffers[c].removeFirst(scopeBuffers[c].count - scopeBufferLength)
            }
            for v in src {
                stepPeak[c] = max(stepPeak[c], abs(v))
                stepSquares[c] += Double(v) * Double(v)
            }
        }
        stepSamples += n
        guard Double(stepSamples) >= historyStep * sampleRate else { return }
        for c in scopeBuffers.indices {
            powerHistory[c].append(PowerPoint(peakDB: amplitudeToDB(Double(stepPeak[c])),
                                              rmsDB: powerToDB(stepSquares[c] / Double(stepSamples))))
            stepPeak[c] = 0
            stepSquares[c] = 0
        }
        stepSamples = 0
        if let corr = correlationMeter {
            correlationHistory.append(corr.correlation)
            balanceHistory.append(corr.balance)
        }
        if let analyzer, !lastSpectrum.isEmpty {
            waterfall.append(logReduce(lastSpectrum, binWidth: analyzer.binWidth, columns: Self.waterfallColumns))
        }
    }

    public var snapshot: AnalyzerSnapshot {
        var s = AnalyzerSnapshot()
        s.levels = meters.map(\.reading)
        s.spectrumDB = averager.averageDB
        s.spectrumPeakDB = averager.peakDB
        s.binWidth = analyzer?.binWidth ?? 1
        if let analyzer {
            let enbw = analyzer.equivalentNoiseBandwidth
            s.octaveBands = bands
            s.octaveDB = bandLevels(spectrumDB: s.spectrumDB, binWidth: s.binWidth, enbwBins: enbw, bands: bands)
            s.octavePeakDB = bandLevels(spectrumDB: s.spectrumPeakDB, binWidth: s.binWidth, enbwBins: enbw, bands: bands)
        }
        s.correlation = correlationMeter?.correlation ?? 0
        s.balance = correlationMeter?.balance ?? 0
        s.sampleRate = sampleRate
        s.transferFunction = transferFunction?.result
        s.distortion = latestDistortion
        s.scope = captureScope(scopeBuffers, settings: scopeSettings, sampleRate: sampleRate)
        s.scopeSettings = scopeSettings
        let vs = min(2048, scopeBuffers[0].count)
        s.vectorscope = (Array(scopeBuffers[0].suffix(vs)), Array(scopeBuffers[scopeBuffers.count - 1].suffix(vs)))
        s.waterfall = waterfall.values
        s.correlationHistory = correlationHistory.values
        s.balanceHistory = balanceHistory.values
        s.powerHistory = powerHistory.map(\.values)
        s.historyStep = historyStep
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
        waterfall.removeAll()
        correlationHistory.removeAll()
        balanceHistory.removeAll()
        for i in powerHistory.indices { powerHistory[i].removeAll() }
    }
}
