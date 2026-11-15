import AnalysisCore
import SwiftUI

private let meterFloor = -60.0

private func meterFraction(_ db: Double) -> Double {
    max(0, min(1, (db - meterFloor) / -meterFloor))
}

private func levelColor(_ db: Double) -> Color {
    db > -3 ? .red : db > -12 ? .yellow : .green
}

/// Peak bar with RMS bar alongside, held-peak tick and numeric readouts.
struct LevelMetersView: View {
    let levels: [LevelReading]

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            ForEach(Array(levels.prefix(8).enumerated()), id: \.offset) { index, r in
                VStack(spacing: 4) {
                    Text(r.overs > 0 ? "OVER \(r.overs)" : " ")
                        .font(.system(size: 9, weight: .bold)).foregroundStyle(.red)
                    Canvas { ctx, size in
                        let h = size.height
                        ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.gray.opacity(0.15)))
                        let peakH = h * meterFraction(r.peakDB)
                        ctx.fill(Path(CGRect(x: 0, y: h - peakH, width: size.width * 0.55, height: peakH)),
                                 with: .color(levelColor(r.peakDB)))
                        let rmsH = h * meterFraction(r.rmsDB)
                        ctx.fill(Path(CGRect(x: size.width * 0.6, y: h - rmsH, width: size.width * 0.4, height: rmsH)),
                                 with: .color(.purple))
                        let holdY = h - h * meterFraction(r.heldPeakDB)
                        ctx.fill(Path(CGRect(x: 0, y: holdY - 1, width: size.width * 0.55, height: 2)), with: .color(.white))
                    }
                    Text(String(format: "%.1f", max(r.heldPeakDB, -99)))
                        .font(.system(size: 10).monospacedDigit())
                    Text(String(format: "%.1f", max(r.rmsDB, -99)))
                        .font(.system(size: 10).monospacedDigit()).foregroundStyle(.purple)
                    Text("\(index + 1)").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// Log-frequency spectrum: average trace and peak-hold trace. With a
/// calibration offset the scale is dB SPL (a sine reads its RMS SPL);
/// without, dBFS (a full-scale sine reads 0).
struct SpectrumView: View {
    let averageDB: [Double]
    let peakDB: [Double]
    let binWidth: Double
    let sampleRate: Double
    var offsetDB: Double? = nil

    private let minF = 20.0

    var body: some View {
        // Spectrum dB are sine-referenced (peak); SPL is RMS-referenced.
        let shift = offsetDB.map { $0 - 3.0103 } ?? 0
        let top = offsetDB == nil ? 0.0 : (shift / 10).rounded(.up) * 10
        let bottom = top - 120
        FrequencyPlot(yTicks: stride(from: top, through: bottom, by: -20).map { (value: $0, label: "\(Int($0))") },
                      yRange: bottom...top) { x, y in
            Canvas { ctx, size in
                let xs: (Double) -> Double = { x($0, size.width) }
                let ys: (Double) -> Double = { y($0 + shift, size.height) }
                ctx.stroke(trace(peakDB, x: xs, y: ys), with: .color(.yellow.opacity(0.6)), lineWidth: 1)
                ctx.stroke(trace(averageDB, x: xs, y: ys), with: .color(.cyan), lineWidth: 1.5)
            }
        }
        .overlay(alignment: .topTrailing) {
            Text(offsetDB == nil ? "dBFS" : "dB SPL").font(.caption).foregroundStyle(.secondary).padding(4)
        }
    }

    /// One point per horizontal pixel column: the maximum of the bins under it.
    private func trace(_ db: [Double], x: (Double) -> Double, y: (Double) -> Double) -> Path {
        var p = Path()
        guard db.count > 2, binWidth > 0 else { return p }
        var column = -1.0, colMax = -Double.infinity, started = false
        for k in 1..<db.count {
            let f = Double(k) * binWidth
            guard f >= minF, f <= 20000 else { continue }
            let cx = x(f).rounded()
            if cx != column, colMax > -.infinity {
                let pt = CGPoint(x: column, y: y(colMax))
                if started { p.addLine(to: pt) } else { p.move(to: pt); started = true }
                colMax = -.infinity
            }
            column = cx
            colMax = max(colMax, db[k])
        }
        return p
    }
}

/// Correlation, -1 to +1, centre is 0.
struct CorrelationBar: View {
    let value: Double

    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.gray.opacity(0.15)))
            let mid = size.width / 2
            let x = mid + mid * value
            ctx.fill(Path(CGRect(x: min(mid, x), y: 4, width: abs(x - mid), height: size.height - 8)),
                     with: .color(value >= 0 ? .green : .red))
            ctx.fill(Path(CGRect(x: mid - 0.5, y: 0, width: 1, height: size.height)), with: .color(.white.opacity(0.5)))
        }
        .overlay(alignment: .trailing) {
            Text(String(format: "%+.2f", value)).font(.caption.monospacedDigit()).padding(.trailing, 6)
        }
    }
}
