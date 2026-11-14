import Foundation

/// The lowest level any meter reports. Digital silence is shown as this, not -inf.
public let floorDB: Double = -200

@inlinable
public func amplitudeToDB(_ x: Double) -> Double {
    x > 0 ? max(20 * log10(x), floorDB) : floorDB
}

@inlinable
public func powerToDB(_ p: Double) -> Double {
    p > 0 ? max(10 * log10(p), floorDB) : floorDB
}

@inlinable
public func dbToAmplitude(_ db: Double) -> Double {
    pow(10, db / 20)
}

/// Coefficient for a one-pole smoother with time constant `tau` seconds.
@inlinable
public func onePoleCoefficient(tau: Double, sampleRate: Double) -> Double {
    tau > 0 ? 1 - exp(-1 / (tau * sampleRate)) : 1
}
