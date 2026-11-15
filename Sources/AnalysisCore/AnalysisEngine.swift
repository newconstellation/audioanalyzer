import Foundation

/// Everything the window draws, captured at one moment.
public struct AnalyzerSnapshot: Sendable {
    public var levels: [LevelReading] = []
    /// Per channel: A- and C-weighted sound levels, in dB re digital RMS 1.
    public var soundLevels: [ChannelSoundLevel] = []
    /// Per channel: dB to add to sound levels to get dB SPL, or nil if uncalibrated.
    public var calibrationOffsets: [Double?] = []
    public var calibration: CalibrationStatus?
    /// History of the SPL channel's levels, oldest first, every `splHistoryStep` seconds.
    public var splHistory: [SPLPoint] = []
    public var splHistoryStep: Double = 0.5
    public var splChannel = 0
    public var leqPeriodSeconds = 60.0
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
    /// The transfer function, averaged over the measurement mics.
    public var transferFunction: TransferFunctionResult?
    /// Each measurement mic's own transfer function, when there are several.
    public var transferFunctionsPerMic: [TransferFunctionResult] = []
    public var routing = ChannelRouting()
    public var distortion: DistortionResult?
    /// Impulse response from the transfer function, and its decay waterfall.
    public var impulse: ImpulseResponse?
    public var decay: DecayResult?
    public var decaySettings = DecaySettings()
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
/// Channel roles come from `routing`: by default channel 1 feeds the
/// spectrum and the distortion analyzer, and the transfer function uses
/// channel 1 as reference and channel 2 as the measurement mic.
public final class AnalysisEngine {
    public let sampleRate: Double
    public let channelCount: Int

    private let meters: [LevelMeter]
    private let soundMeters: [(a: SoundLevelMeter, c: SoundLevelMeter)]
    /// Per channel: dB to add to sound levels to get dB SPL (nil if uncalibrated).
    public var calibrationOffsets: [Double?]
    /// Channel shown on the SPL page and logged in its history.
    public var splChannel = 0
    public var leqPeriodSeconds = 60.0 {
        didSet { for m in soundMeters { m.a.leqPeriodSeconds = leqPeriodSeconds; m.c.leqPeriodSeconds = leqPeriodSeconds } }
    }
    private var calibrator: (channel: Int, cal: LevelCalibrator)?
    private var splHistory = History<SPLPoint>(capacity: 1200)
    private var splHistoryCounter = 0
    private let correlationMeter: CorrelationMeter?
    private let analyzer: SpectrumAnalyzer?
    private var averager = SpectrumAverager(mode: .exponential(seconds: 0.3))
    /// One transfer function per measurement mic, in `routing.measurementChannels` order.
    public private(set) var transferFunctions: [TransferFunctionAnalyzer] = []
    /// The first measurement mic's transfer function.
    public var transferFunction: TransferFunctionAnalyzer? { transferFunctions.first }
    /// Which inputs feed the spectrum and transfer function, and how mics are averaged.
    public var routing = ChannelRouting() {
        didSet {
            routing = routing.validated(channelCount: channelCount)
            if routing != oldValue { applyRouting(old: oldValue) }
        }
    }
    private var histories: [Int: [Float]] = [:]
    public let distortionAnalyzer: DistortionAnalyzer?
    private var latestDistortion: DistortionResult?
    private let historyLength: Int
    private var samplesSinceDistortion = 0
    /// How often the distortion analysis is refreshed, in seconds.
    public var distortionInterval = 0.1
    /// How often the impulse response and decay waterfall are refreshed, in seconds.
    public var decayInterval = 0.5
    public var decaySettings = DecaySettings() {
        didSet { if decaySettings != oldValue { updateDecay() } }
    }
    private var samplesSinceDecay = 0
    private var latestImpulse: ImpulseResponse?
    private var latestDecay: DecayResult?

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
        soundMeters = (0..<channelCount).map { _ in
            (SoundLevelMeter(sampleRate: sampleRate, weighting: .a), SoundLevelMeter(sampleRate: sampleRate, weighting: .c))
        }
        calibrationOffsets = Array(repeating: nil, count: channelCount)
        correlationMeter = channelCount >= 2 ? CorrelationMeter(sampleRate: sampleRate) : nil
        analyzer = SpectrumAnalyzer(fftSize: fftSize, window: .hann, sampleRate: sampleRate)
        distortionAnalyzer = DistortionAnalyzer(sampleRate: sampleRate)
        historyLength = max(fftSize, distortionAnalyzer?.fftSize ?? 0)
        let scopeChannels = min(2, max(1, channelCount))
        scopeBufferLength = Int(sampleRate / 2)
        scopeBuffers = Array(repeating: [], count: scopeChannels)
        powerHistory = Array(repeating: History(capacity: 600), count: scopeChannels)
        stepPeak = Array(repeating: 0, count: scopeChannels)
        stepSquares = Array(repeating: 0, count: scopeChannels)
        routing = ChannelRouting().validated(channelCount: channelCount)
        applyRouting(old: nil)
    }

    /// Rebuilds transfer functions for changed mics (keeping those that stay,
    /// with their averages and delays) and resets the spectrum average.
    private func applyRouting(old: ChannelRouting?) {
        let keep = old?.reference == routing.reference ? old?.measurementChannels ?? [] : []
        var byChannel: [Int: TransferFunctionAnalyzer] = [:]
        for (ch, tf) in zip(keep, transferFunctions) { byChannel[ch] = tf }
        transferFunctions = routing.measurementChannels.compactMap { ch in
            byChannel[ch] ?? TransferFunctionAnalyzer(sampleRate: sampleRate)
        }
        if old?.spectrumChannels != routing.spectrumChannels || old?.spectrumAverage != routing.spectrumAverage {
            averager.reset()
            lastSpectrum = []
            histories = histories.filter { routing.spectrumChannels.contains($0.key) }
        }
        latestImpulse = nil
        latestDecay = nil
    }

    /// `channels[c]` points at `frameCount` samples for channel `c`.
    public func process(channels: [UnsafePointer<Float>], frameCount n: Int) {
        guard n > 0 else { return }
        for (c, meter) in meters.enumerated() where c < channels.count {
            let buf = UnsafeBufferPointer(start: channels[c], count: n)
            meter.process(buf)
            soundMeters[c].a.process(buf)
            soundMeters[c].c.process(buf)
        }
        if let cal = calibrator, cal.channel < channels.count {
            cal.cal.process(UnsafeBufferPointer(start: channels[cal.channel], count: n))
        }
        if channels.count >= 2 {
            let left = UnsafeBufferPointer(start: channels[0], count: n)
            let right = UnsafeBufferPointer(start: channels[1], count: n)
            correlationMeter?.process(left: left, right: right)
        }
        if routing.reference < channels.count {
            let source = UnsafeBufferPointer(start: channels[routing.reference], count: n)
            for (ch, tf) in zip(routing.measurementChannels, transferFunctions) where ch < channels.count {
                tf.process(source: source, response: UnsafeBufferPointer(start: channels[ch], count: n))
            }
        }
        guard !channels.isEmpty else { return }
        for ch in routing.spectrumChannels where ch < channels.count {
            var h = histories[ch] ?? []
            histories[ch] = nil // avoid a copy while appending
            h.append(contentsOf: UnsafeBufferPointer(start: channels[ch], count: n))
            if h.count > historyLength { h.removeFirst(h.count - historyLength) }
            histories[ch] = h
        }
        if let analyzer {
            let spectra: [[Double]] = routing.spectrumChannels.compactMap { ch in
                guard let h = histories[ch], h.count >= analyzer.fftSize else { return nil }
                return h.withUnsafeBufferPointer { analyzer.spectrumDB($0) }
            }
            if !spectra.isEmpty {
                let spectrum = averageSpectra(spectra, binWidth: analyzer.binWidth, mode: routing.spectrumAverage)
                averager.add(spectrum, updateInterval: Double(n) / sampleRate)
                lastSpectrum = spectrum
            }
        }
        samplesSinceDistortion += n
        if let distortionAnalyzer, let h = histories[routing.spectrumChannels[0]], h.count >= distortionAnalyzer.fftSize,
           Double(samplesSinceDistortion) >= distortionInterval * sampleRate {
            samplesSinceDistortion = 0
            latestDistortion = h.withUnsafeBufferPointer { distortionAnalyzer.analyze($0) }
        }
        samplesSinceDecay += n
        if !transferFunctions.isEmpty, Double(samplesSinceDecay) >= decayInterval * sampleRate {
            samplesSinceDecay = 0
            updateDecay()
        }
        updateTimeDomain(channels: channels, frameCount: n)
    }

    private func updateDecay() {
        latestImpulse = transferFunction?.impulseResponse()
        latestDecay = latestImpulse.map { cumulativeSpectralDecay($0, settings: decaySettings) }
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
        splHistoryCounter += 1
        if splHistoryCounter >= 10, splChannel < soundMeters.count { // every 10 steps (0.5 s)
            splHistoryCounter = 0
            let a = soundMeters[splChannel].a.reading, c = soundMeters[splChannel].c.reading
            splHistory.append(SPLPoint(laSlow: a.slow, lcSlow: c.slow, laeq: a.periodLeq))
        }
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
        s.soundLevels = soundMeters.map { ChannelSoundLevel(a: $0.a.reading, c: $0.c.reading) }
        s.calibrationOffsets = calibrationOffsets
        if let c = calibrator {
            s.calibration = CalibrationStatus(channel: c.channel, referenceSPL: c.cal.referenceSPL, progress: c.cal.progress,
                                              measuredDB: c.cal.measuredDB, offset: c.cal.offset)
        }
        s.splHistory = splHistory.values
        s.splHistoryStep = historyStep * 10
        s.splChannel = splChannel
        s.leqPeriodSeconds = leqPeriodSeconds
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
        let tfs = transferFunctions.map(\.result)
        s.transferFunction = tfs.isEmpty ? nil : averageTransferFunctions(tfs, mode: routing.transferAverage)
        s.transferFunctionsPerMic = tfs.count > 1 ? tfs : []
        s.routing = routing
        s.distortion = latestDistortion
        s.impulse = latestImpulse
        s.decay = latestDecay
        s.decaySettings = decaySettings
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

    /// Finds each measurement mic's delay from the reference, applies it, and
    /// restarts the transfer-function averages. Returns the first mic's new
    /// compensation in samples.
    @discardableResult
    public func findAndApplyDelay() -> Int? {
        var first: Int?
        for tf in transferFunctions {
            guard let d = tf.findDelay() else { continue }
            tf.delayCompensation += Int(d.rounded())
            tf.resetAverages()
            if tf === transferFunctions.first { first = tf.delayCompensation }
        }
        latestImpulse = nil
        latestDecay = nil
        return first
    }

    /// Starts measuring a calibrator on `channel`. Watch `snapshot.calibration`
    /// for progress and the resulting offset, then `applyCalibration()`.
    public func startCalibration(channel: Int, referenceSPL: Double, seconds: Double = 3) {
        guard channel >= 0, channel < channelCount else { return }
        calibrator = (channel, LevelCalibrator(sampleRate: sampleRate, referenceSPL: referenceSPL, seconds: seconds))
    }

    /// Stores the finished calibration's offset for its channel and returns it.
    @discardableResult
    public func applyCalibration() -> (channel: Int, offset: Double)? {
        defer { calibrator = nil }
        guard let c = calibrator, let offset = c.cal.offset else { return nil }
        calibrationOffsets[c.channel] = offset
        return (c.channel, offset)
    }

    public func cancelCalibration() { calibrator = nil }

    /// Restarts Leq, maxima and peaks of the sound level meters.
    public func resetSoundLevels() {
        for m in soundMeters { m.a.reset(); m.c.reset() }
        splHistory.removeAll()
    }

    public func resetPeaks() {
        meters.forEach { $0.reset() }
        correlationMeter?.reset()
        averager.reset()
        transferFunctions.forEach { $0.resetAverages() }
        waterfall.removeAll()
        correlationHistory.removeAll()
        balanceHistory.removeAll()
        for i in powerHistory.indices { powerHistory[i].removeAll() }
    }
}
