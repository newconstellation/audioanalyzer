import Foundation

/// A frequency sweep for one tone: from the tone's frequency to `endFrequency`.
public struct Sweep: Sendable, Equatable, Codable {
    public enum Mode: String, Sendable, Codable, CaseIterable { case repeating, once }
    public var endFrequency: Double
    public var seconds: Double
    public var logarithmic: Bool
    public var mode: Mode

    public init(endFrequency: Double, seconds: Double, logarithmic: Bool = true, mode: Mode = .repeating) {
        self.endFrequency = endFrequency
        self.seconds = seconds
        self.logarithmic = logarithmic
        self.mode = mode
    }
}

public struct ToneSettings: Sendable, Equatable, Codable {
    public var enabled: Bool
    public var frequency: Double
    /// Peak level of the sine, in dBFS.
    public var levelDBFS: Double
    public var sweep: Sweep?

    public init(enabled: Bool = true, frequency: Double = 1000, levelDBFS: Double = -20, sweep: Sweep? = nil) {
        self.enabled = enabled
        self.frequency = frequency
        self.levelDBFS = levelDBFS
        self.sweep = sweep
    }
}

/// Gates the whole output on and off with raised-cosine edges.
public struct Burst: Sendable, Equatable, Codable {
    public var onSeconds: Double
    public var offSeconds: Double
    public var rampSeconds: Double

    public init(onSeconds: Double, offSeconds: Double, rampSeconds: Double = 0.002) {
        self.onSeconds = onSeconds
        self.offSeconds = offSeconds
        self.rampSeconds = rampSeconds
    }
}

public struct GeneratorSettings: Sendable, Equatable, Codable {
    public static let maxTones = 9

    /// Master switch; when off the generator outputs silence.
    public var enabled: Bool = false
    public var tones: [ToneSettings] = [ToneSettings()]
    /// RMS level of white noise in dBFS, or nil for none.
    public var whiteNoiseDBFS: Double?
    /// RMS level of pink noise in dBFS, or nil for none.
    public var pinkNoiseDBFS: Double?
    public var burst: Burst?
    /// Quantise the output to this many bits with TPDF dither, or nil to leave it as floating point.
    public var ditherBits: Int?
    /// Snap steady tones to the nearest bin centre of an FFT of this size, so
    /// they show no leakage in an analyzer using the same size.
    public var fftSyncSize: Int?

    public init() {}
}

/// Test-signal generator: up to nine sines (each optionally swept), white and
/// pink noise, burst gating, and optional dithered quantisation.
///
/// `render` doesn't allocate or lock, so it can run on the audio I/O thread.
/// Change `settings` from the same thread that renders (or hand it over with a
/// lock the render thread only tries); phases and sweeps carry on smoothly.
public final class SignalGenerator {
    public let sampleRate: Double
    public var settings: GeneratorSettings

    private var phases = [Double](repeating: 0, count: GeneratorSettings.maxTones)
    private var sweepTimes = [Double](repeating: 0, count: GeneratorSettings.maxTones)
    private var burstTime = 0.0
    private var rng = Xoshiro(seed: 0x5EED_1234_ABCD_0001)
    private var pink = PinkFilter()
    private let pinkScale: Double

    public init(sampleRate: Double, settings: GeneratorSettings = GeneratorSettings()) {
        self.sampleRate = sampleRate
        self.settings = settings
        // The pink filter's gain depends on the sample rate, so measure it once.
        var r = Xoshiro(seed: 42), f = PinkFilter(), sum = 0.0
        let n = 1 << 19
        for _ in 0..<n { let v = f.next(r.gaussian()); sum += v * v }
        pinkScale = 1 / (sum / Double(n)).squareRoot()
    }

    /// Restarts phases, sweeps and the burst cycle.
    public func reset() {
        for i in phases.indices { phases[i] = 0; sweepTimes[i] = 0 }
        burstTime = 0
    }

    /// The frequency a steady tone actually plays at, after FFT synchronisation.
    public func effectiveFrequency(_ f: Double) -> Double {
        guard let n = settings.fftSyncSize, n > 0 else { return f }
        let bin = (f * Double(n) / sampleRate).rounded()
        return bin * sampleRate / Double(n)
    }

    /// Writes `frameCount` mono samples.
    public func render(into out: UnsafeMutablePointer<Float>, frameCount: Int) {
        let s = settings
        guard s.enabled else {
            out.update(repeating: 0, count: frameCount)
            return
        }
        let dt = 1 / sampleRate
        let twoPi = 2 * Double.pi
        let white = s.whiteNoiseDBFS.map(dbToAmplitude) ?? 0
        let pinkAmp = s.pinkNoiseDBFS.map(dbToAmplitude).map { $0 * pinkScale } ?? 0
        let toneCount = min(s.tones.count, GeneratorSettings.maxTones)
        let lsb = s.ditherBits.map { 1 / pow(2, Double(max(2, min(24, $0)) - 1)) }

        for i in 0..<frameCount {
            var v = 0.0
            for t in 0..<toneCount {
                let tone = s.tones[t]
                guard tone.enabled else { continue }
                let a = dbToAmplitude(tone.levelDBFS)
                let f: Double
                if let sw = tone.sweep, sw.seconds > 0 {
                    var x = sweepTimes[t] / sw.seconds
                    if x >= 1 {
                        if sw.mode == .repeating { sweepTimes[t] = 0; x = 0 } else { x = 1 }
                    }
                    f = sw.logarithmic && tone.frequency > 0 && sw.endFrequency > 0
                        ? tone.frequency * pow(sw.endFrequency / tone.frequency, x)
                        : tone.frequency + (sw.endFrequency - tone.frequency) * x
                    sweepTimes[t] += dt
                } else {
                    f = effectiveFrequency(tone.frequency)
                }
                v += a * sin(phases[t])
                phases[t] += twoPi * f * dt
                if phases[t] >= twoPi { phases[t] -= twoPi }
            }
            if white > 0 { v += white * rng.gaussian() }
            if pinkAmp > 0 { v += pinkAmp * pink.next(rng.gaussian()) }

            if let b = s.burst, b.onSeconds > 0 {
                v *= burstGain(b)
                burstTime += dt
                if burstTime >= b.onSeconds + b.offSeconds { burstTime -= b.onSeconds + b.offSeconds }
            }

            if let lsb {
                // TPDF dither of +/- 1 LSB, then round to the LSB grid.
                let d = (rng.uniform() + rng.uniform() - 1) * lsb
                v = ((v + d) / lsb).rounded() * lsb
                v = min(max(v, -1), 1 - lsb)
            } else {
                v = min(max(v, -1), 1)
            }
            out[i] = Float(v)
        }
    }

    private func burstGain(_ b: Burst) -> Double {
        let t = burstTime
        guard t < b.onSeconds else { return 0 }
        let ramp = min(b.rampSeconds, b.onSeconds / 2)
        guard ramp > 0 else { return 1 }
        if t < ramp { return 0.5 - 0.5 * cos(.pi * t / ramp) }
        if t > b.onSeconds - ramp { return 0.5 - 0.5 * cos(.pi * (b.onSeconds - t) / ramp) }
        return 1
    }
}

/// Paul Kellet's refined pink filter (-3 dB/octave, within 0.05 dB above 9 Hz at 44.1 kHz).
struct PinkFilter {
    private var b0 = 0.0, b1 = 0.0, b2 = 0.0, b3 = 0.0, b4 = 0.0, b5 = 0.0, b6 = 0.0
    mutating func next(_ white: Double) -> Double {
        b0 = 0.99886 * b0 + white * 0.0555179
        b1 = 0.99332 * b1 + white * 0.0750759
        b2 = 0.96900 * b2 + white * 0.1538520
        b3 = 0.86650 * b3 + white * 0.3104856
        b4 = 0.55000 * b4 + white * 0.5329522
        b5 = -0.7616 * b5 - white * 0.0168980
        let out = b0 + b1 + b2 + b3 + b4 + b5 + b6 + white * 0.5362
        b6 = white * 0.115926
        return out
    }
}

/// xoshiro256** PRNG: fast, allocation-free, good statistical quality.
struct Xoshiro {
    private var s0, s1, s2, s3: UInt64
    private var spare: Double?

    init(seed: UInt64) {
        var z = seed
        func splitmix() -> UInt64 {
            z &+= 0x9E37_79B9_7F4A_7C15
            var x = z
            x = (x ^ (x >> 30)) &* 0xBF58_476D_1CE4_E5B9
            x = (x ^ (x >> 27)) &* 0x94D0_49BB_1331_11EB
            return x ^ (x >> 31)
        }
        s0 = splitmix(); s1 = splitmix(); s2 = splitmix(); s3 = splitmix()
    }

    private static func rotl(_ x: UInt64, _ k: UInt64) -> UInt64 { (x << k) | (x >> (64 - k)) }

    mutating func next() -> UInt64 {
        let result = Xoshiro.rotl(s1 &* 5, 7) &* 9
        let t = s1 << 17
        s2 ^= s0; s3 ^= s1; s1 ^= s2; s0 ^= s3
        s2 ^= t
        s3 = Xoshiro.rotl(s3, 45)
        return result
    }

    /// Uniform in [0, 1).
    mutating func uniform() -> Double { Double(next() >> 11) / Double(1 << 53) }

    /// Standard normal (Box-Muller, pairs cached).
    mutating func gaussian() -> Double {
        if let s = spare { spare = nil; return s }
        let u1 = max(uniform(), 1e-300), u2 = uniform()
        let r = (-2 * log(u1)).squareRoot()
        spare = r * sin(2 * .pi * u2)
        return r * cos(2 * .pi * u2)
    }
}
