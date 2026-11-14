import Foundation

/// Stereo phase correlation, -1 (out of polarity) to +1 (identical),
/// integrated with a one-pole time constant.
public final class CorrelationMeter {
    public let sampleRate: Double
    public var timeConstant: Double { didSet { coeff = onePoleCoefficient(tau: timeConstant, sampleRate: sampleRate) } }

    private var coeff: Double
    private var lr = 0.0, ll = 0.0, rr = 0.0

    public init(sampleRate: Double, timeConstant: Double = 0.3) {
        self.sampleRate = sampleRate
        self.timeConstant = timeConstant
        coeff = onePoleCoefficient(tau: timeConstant, sampleRate: sampleRate)
    }

    public func process(left: UnsafeBufferPointer<Float>, right: UnsafeBufferPointer<Float>) {
        precondition(left.count == right.count)
        var a = lr, b = ll, c = rr
        for i in 0..<left.count {
            let l = Double(left[i]), r = Double(right[i])
            a += coeff * (l * r - a)
            b += coeff * (l * l - b)
            c += coeff * (r * r - c)
        }
        lr = a; ll = b; rr = c
    }

    /// 0 when either channel is silent.
    public var correlation: Double {
        let d = (ll * rr).squareRoot()
        return d > 1e-20 ? max(-1, min(1, lr / d)) : 0
    }

    /// Left/right power balance: +1 all left, -1 all right, 0 equal.
    public var balance: Double {
        let total = ll + rr
        return total > 1e-20 ? (ll - rr) / total : 0
    }

    public func reset() { lr = 0; ll = 0; rr = 0 }
}
