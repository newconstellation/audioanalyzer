import Foundation

/// FFT window functions (periodic / DFT-even form).
public enum WindowFunction: String, CaseIterable, Sendable {
    case rectangular
    case hann
    case blackmanHarris
    /// Flat top: widest main lobe, but sine amplitudes read within ~0.01 dB anywhere between bins.
    case flatTop
    /// 7-term Blackman-Harris: about -180 dB sidelobes, for distortion measurement.
    case blackmanHarris7

    private var cosineTerms: [Double] {
        switch self {
        case .rectangular: return [1]
        case .hann: return [0.5, 0.5]
        case .blackmanHarris: return [0.35875, 0.48829, 0.14128, 0.01168]
        case .flatTop: return [0.21557895, 0.41663158, 0.277263158, 0.083578947, 0.006947368]
        case .blackmanHarris7:
            return [0.27105140069342, 0.43329793923448, 0.21812299954311, 0.06592544638803,
                    0.01081174209837, 0.00077658482522, 0.00001388721735]
        }
    }

    public func coefficients(count n: Int) -> [Float] {
        let a = cosineTerms
        return (0..<n).map { i in
            let x = 2 * Double.pi * Double(i) / Double(n)
            var w = 0.0
            for (k, ak) in a.enumerated() {
                w += (k % 2 == 0 ? ak : -ak) * cos(Double(k) * x)
            }
            return Float(w)
        }
    }

    /// Equivalent noise bandwidth in bins: N * sum(w^2) / sum(w)^2.
    public func equivalentNoiseBandwidth(count n: Int) -> Double {
        let w = coefficients(count: n).map(Double.init)
        let sum = w.reduce(0, +)
        return Double(n) * w.reduce(0) { $0 + $1 * $1 } / (sum * sum)
    }
}
