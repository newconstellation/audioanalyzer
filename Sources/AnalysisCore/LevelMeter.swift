import Accelerate
import Foundation

/// How RMS is referenced. Many meters show a sine's RMS equal to its peak
/// (AES17 "sine-referenced", +3.01 dB); others show true RMS.
public enum RMSReference: Sendable {
    case trueRMS
    case sineReferenced

    var offsetDB: Double { self == .trueRMS ? 0 : 10 * log10(2.0) }
}

/// Ballistics settings for `LevelMeter`. The defaults are standard values
/// (digital peak with crawlback, 300 ms RMS, IEC VU, EBU PPM), and will be
/// tuned against reference measurements.
public struct MeterBallistics: Sendable {
    /// Rate the displayed peak falls after the signal drops, in dB per second.
    public var peakReleaseDBPerSecond: Double = 20
    /// How long the held-peak marker stays before it falls. `nil` holds until reset.
    public var peakHoldSeconds: Double? = 2
    /// Time constant of the RMS integrator, in seconds.
    public var rmsTimeConstant: Double = 0.3
    public var rmsReference: RMSReference = .trueRMS
    /// VU: rises to 99% of a steady reading in this many seconds (IEC 60268-17: 0.3 s).
    public var vuRiseTime: Double = 0.3
    /// PPM: attack time constant, and fall rate (EBU/IEC Type IIa: 24 dB in 2.8 s).
    public var ppmAttackTimeConstant: Double = 0.0017
    public var ppmReleaseDBPerSecond: Double = 24 / 2.8
    /// Consecutive full-scale samples that count as one over.
    public var overSampleCount: Int = 3
    /// Sample magnitude treated as full scale.
    public var fullScaleThreshold: Float = 0.9999

    public init() {}
}

public struct LevelReading: Sendable, Equatable {
    public var peakDB: Double
    public var heldPeakDB: Double
    public var rmsDB: Double
    public var heldRMSDB: Double
    public var vuDB: Double
    public var ppmDB: Double
    public var overs: Int
}

/// Peak, RMS, VU and PPM metering for one channel, fed with blocks of samples.
/// Not thread-safe: feed it from one thread, then read `reading`.
public final class LevelMeter {
    public let sampleRate: Double
    public var ballistics: MeterBallistics { didSet { updateCoefficients() } }

    private var peakDB = floorDB
    private var heldPeakDB = floorDB
    private var heldPeakAge = 0.0
    private var meanSquare = 0.0
    private var heldRMSDB = floorDB
    private var vu1 = 0.0, vu2 = 0.0
    private var ppmLinear = 0.0
    private var overs = 0
    private var fullScaleRun = 0

    private var rmsCoeff = 0.0
    private var vuCoeff = 0.0
    private var ppmCoeff = 0.0

    public init(sampleRate: Double, ballistics: MeterBallistics = MeterBallistics()) {
        self.sampleRate = sampleRate
        self.ballistics = ballistics
        updateCoefficients()
    }

    private func updateCoefficients() {
        rmsCoeff = onePoleCoefficient(tau: ballistics.rmsTimeConstant, sampleRate: sampleRate)
        // Two cascaded one-poles (critically damped) reach 99% after ~6.64 tau.
        vuCoeff = onePoleCoefficient(tau: ballistics.vuRiseTime / 6.638, sampleRate: sampleRate)
        ppmCoeff = onePoleCoefficient(tau: ballistics.ppmAttackTimeConstant, sampleRate: sampleRate)
    }

    public func reset() {
        peakDB = floorDB; heldPeakDB = floorDB; heldPeakAge = 0
        meanSquare = 0; heldRMSDB = floorDB
        vu1 = 0; vu2 = 0; ppmLinear = 0
        overs = 0; fullScaleRun = 0
    }

    public func process(_ samples: UnsafeBufferPointer<Float>) {
        guard !samples.isEmpty else { return }
        let dt = Double(samples.count) / sampleRate

        // Sample peak with dB-linear crawlback.
        let blockPeakDB = amplitudeToDB(Double(vDSP.maximumMagnitude(samples)))
        peakDB = max(blockPeakDB, peakDB - ballistics.peakReleaseDBPerSecond * dt)
        if peakDB >= heldPeakDB {
            heldPeakDB = peakDB
            heldPeakAge = 0
        } else {
            heldPeakAge += dt
            if let hold = ballistics.peakHoldSeconds, heldPeakAge > hold {
                heldPeakDB = max(peakDB, heldPeakDB - ballistics.peakReleaseDBPerSecond * dt)
            }
        }

        // Per-sample integrators.
        let ppmRelease = pow(10, -ballistics.ppmReleaseDBPerSecond / 20 / sampleRate)
        var ms = meanSquare, a = vu1, b = vu2, ppm = ppmLinear, run = fullScaleRun
        for s in samples {
            let x = Double(s)
            let mag = abs(x)
            ms += rmsCoeff * (x * x - ms)
            a += vuCoeff * (mag - a)
            b += vuCoeff * (a - b)
            ppm = mag > ppm ? ppm + ppmCoeff * (mag - ppm) : ppm * ppmRelease
            if abs(s) >= ballistics.fullScaleThreshold {
                run += 1
                if run == ballistics.overSampleCount { overs += 1 }
            } else {
                run = 0
            }
        }
        meanSquare = ms; vu1 = a; vu2 = b; ppmLinear = ppm; fullScaleRun = run
        heldRMSDB = max(heldRMSDB, rmsDB)
    }

    private var rmsDB: Double { powerToDB(meanSquare) + (meanSquare > 0 ? ballistics.rmsReference.offsetDB : 0) }

    public var reading: LevelReading {
        let vuScale = Double.pi / (2 * 2.0.squareRoot()) // rectified mean of a sine -> its RMS
        let vuOffset = ballistics.rmsReference.offsetDB
        return LevelReading(
            peakDB: peakDB,
            heldPeakDB: heldPeakDB,
            rmsDB: rmsDB,
            heldRMSDB: heldRMSDB,
            vuDB: vu2 > 0 ? amplitudeToDB(vu2 * vuScale) + vuOffset : floorDB,
            ppmDB: amplitudeToDB(ppmLinear),
            overs: overs
        )
    }
}
