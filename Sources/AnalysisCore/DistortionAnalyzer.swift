import Foundation

/// Harmonic distortion and noise of a single-tone signal.
public struct DistortionResult: Sendable {
    public var fundamentalHz: Double = 0
    public var fundamentalDBFS: Double = floorDB
    /// THD: total harmonic power (H2 and up, inside the bandwidth) relative to the fundamental.
    public var thdPercent: Double = 0
    public var thdDB: Double = floorDB
    /// THD+N: everything except the fundamental (inside the bandwidth) relative to the fundamental.
    public var thdnPercent: Double = 0
    public var thdnDB: Double = floorDB
    /// SINAD = -THD+N in dB.
    public var sinadDB: Double = 0
    /// Level of each harmonic relative to the fundamental (dBc), starting at H2.
    public var harmonicsDBc: [Double] = []
    /// The analysis spectrum in dBFS, for display, with its bin width.
    public var spectrumDB: [Double] = []
    public var binWidth: Double = 1

    public init() {}
}

/// Measures THD, THD+N and per-harmonic levels from one long FFT with a
/// 7-term Blackman-Harris window (sidelobes far below the Float noise floor),
/// so harmonics down to roughly -130 dBc can be resolved.
///
/// Powers are summed over each component's main lobe and normalised by the
/// window's noise bandwidth, so off-bin tones measure correctly.
public final class DistortionAnalyzer {
    public let fftSize: Int
    public let sampleRate: Double
    /// Highest harmonic included in THD (default H10).
    public var maxHarmonic: Int
    /// Measurement bandwidth for THD and THD+N, in Hz (AES17 uses 20 Hz to 20 kHz).
    public var bandwidth: ClosedRange<Double>
    /// Lowest frequency searched for the fundamental.
    public var minimumFundamental: Double = 10

    private let fft: SpectrumAnalyzer
    /// Half-width, in bins, of the window's main lobe (7-term BH: +/- 7 bins).
    private let lobe = 8

    public init?(fftSize: Int = 32768, sampleRate: Double, maxHarmonic: Int = 10,
                 bandwidth: ClosedRange<Double> = 20...20000) {
        guard let fft = SpectrumAnalyzer(fftSize: fftSize, window: .blackmanHarris7, sampleRate: sampleRate)
        else { return nil }
        self.fftSize = fftSize
        self.sampleRate = sampleRate
        self.maxHarmonic = maxHarmonic
        self.bandwidth = bandwidth
        self.fft = fft
    }

    public var binWidth: Double { fft.binWidth }

    /// Analyses the last `fftSize` samples. Nil if there's no tone to measure.
    public func analyze(_ samples: UnsafeBufferPointer<Float>) -> DistortionResult? {
        let mags = fft.magnitudes(samples)
        let enbw = fft.equivalentNoiseBandwidth
        // Power per bin, scaled so that summing a sine's main lobe gives A^2 / 2.
        let power = mags.map { Double($0) * Double($0) / (2 * enbw) }
        let bw = fft.binWidth
        let nyquistBin = power.count - 1
        let lowBin = max(lobe + 1, Int((bandwidth.lowerBound / bw).rounded(.up)))
        let highBin = min(nyquistBin - lobe - 1, Int((bandwidth.upperBound / bw).rounded(.down)))
        let searchLow = max(lobe + 1, Int((minimumFundamental / bw).rounded(.up)))
        guard highBin > lowBin, highBin > searchLow else { return nil }

        // Fundamental: the strongest bin, refined by the power centroid of its lobe.
        guard let peak = (searchLow...highBin).max(by: { power[$0] < power[$1] }), power[peak] > 0 else { return nil }
        func lobePower(_ centre: Int) -> Double {
            let a = max(1, centre - lobe), b = min(nyquistBin, centre + lobe)
            return power[a...b].reduce(0, +)
        }
        var weighted = 0.0
        for k in (peak - lobe)...(peak + lobe) { weighted += Double(k) * power[k] }
        let fundamentalPower = lobePower(peak)
        guard fundamentalPower > 1e-20 else { return nil }
        let f0Bins = weighted / fundamentalPower

        var result = DistortionResult()
        result.fundamentalHz = f0Bins * bw
        result.fundamentalDBFS = powerToDB(2 * fundamentalPower) // peak level of the sine
        result.binWidth = bw
        result.spectrumDB = mags.map { amplitudeToDB(Double($0)) }

        // Harmonics inside the bandwidth.
        var harmonicPower = 0.0
        if maxHarmonic >= 2 {
            for h in 2...maxHarmonic {
                let centre = Int((Double(h) * f0Bins).rounded())
                guard centre + lobe <= highBin else { break }
                let p = lobePower(centre)
                harmonicPower += p
                result.harmonicsDBc.append(powerToDB(p / fundamentalPower))
            }
        }

        // Everything in the band except the fundamental's lobe.
        var total = 0.0
        for k in lowBin...highBin where abs(k - peak) > lobe { total += power[k] }

        let thd = harmonicPower / fundamentalPower
        let thdn = total / fundamentalPower
        result.thdPercent = thd.squareRoot() * 100
        result.thdDB = powerToDB(thd)
        result.thdnPercent = thdn.squareRoot() * 100
        result.thdnDB = powerToDB(thdn)
        result.sinadDB = -result.thdnDB
        return result
    }
}
