import AnalysisCore
import SwiftUI

private let meterFloor = -60.0

private func meterFraction(_ db: Double) -> Double {
    max(0, min(1, (db - meterFloor) / -meterFloor))
}

/// Ladder meters: segmented peak bars lit along the icon ramp (red only at
/// the top), a thinner RMS ladder alongside, a held-peak tick and numeric
/// readouts.
struct LevelMetersView: View {
    let levels: [LevelReading]

    /// Up to four inputs show their peak and RMS readouts; more inputs get
    /// thin meters with just the input number, so every input fits.
    private var compact: Bool { levels.count > 4 }

    /// The width the meter column needs for `count` inputs.
    static func width(channels count: Int) -> CGFloat {
        count <= 4 ? 140 : min(max(140, CGFloat(count) * 14 + 16), 260)
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: compact ? 3 : 8) {
            ForEach(Array(levels.enumerated()), id: \.offset) { index, r in
                VStack(spacing: compact ? 2 : 3) {
                    Text(r.overs > 0 ? (compact ? "!" : "OVER \(r.overs)") : " ")
                        .font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.danger)
                        .lineLimit(1)
                    Canvas { ctx, size in
                        let segment = 6.0, gap = 2.0
                        let count = max(1, Int((size.height + gap) / segment))
                        let pitch = (size.height + gap) / Double(count)
                        let peakW = size.width * 0.62, rmsX = size.width * 0.72, rmsW = size.width - rmsX
                        for i in 0..<count {
                            let y = size.height - Double(i + 1) * pitch + gap
                            let db = meterFloor * (1 - Double(i + 1) / Double(count))
                            let lit = meterFraction(r.peakDB) >= Double(i) / Double(count) + 0.5 / Double(count)
                            ctx.fill(Path(roundedRect: CGRect(x: 0, y: y, width: peakW, height: pitch - gap), cornerRadius: 1),
                                     with: .color(lit ? Theme.level(db) : Theme.well))
                            let rmsLit = meterFraction(r.rmsDB) >= Double(i) / Double(count) + 0.5 / Double(count)
                            ctx.fill(Path(roundedRect: CGRect(x: rmsX, y: y, width: rmsW, height: pitch - gap), cornerRadius: 1),
                                     with: .color(rmsLit ? Theme.rms.opacity(0.75) : Theme.well))
                        }
                        let holdY = size.height - size.height * meterFraction(r.heldPeakDB)
                        ctx.fill(Path(CGRect(x: -1, y: holdY - 1, width: peakW + 2, height: 2)), with: .color(.white))
                    }
                    if !compact {
                        Text(String(format: "%.1f", max(r.heldPeakDB, -99)))
                            .font(Theme.readout(11, weight: .semibold))
                        Text(String(format: "%.1f", max(r.rmsDB, -99)))
                            .font(Theme.readout(10)).foregroundStyle(Theme.textSecondary)
                    }
                    Text(compact ? "\(index + 1)" : "IN \(index + 1)")
                        .font(.system(size: compact ? 8 : 9, weight: .semibold)).tracking(compact ? 0 : 1)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1).minimumScaleFactor(0.5)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Input \(index + 1)")
                .accessibilityValue(String(format: "peak %.1f dBFS, RMS %.1f dBFS", r.heldPeakDB, r.rmsDB))
            }
        }
        .panel(padding: 8)
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
                      yRange: bottom...top, title: "Spectrum · average and peak hold") { x, y in
            Canvas { ctx, size in
                let xs: (Double) -> Double = { x($0, size.width) }
                let ys: (Double) -> Double = { y($0 + shift, size.height) }
                ctx.stroke(trace(peakDB, x: xs, y: ys), with: .color(Theme.signal2.opacity(0.7)), lineWidth: 1)
                ctx.stroke(trace(averageDB, x: xs, y: ys), with: .color(Theme.signal), lineWidth: 1.5)
            }
        }
        .overlay(alignment: .topTrailing) {
            SectionLabel(offsetDB == nil ? "dBFS" : "dB SPL").padding(8)
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
            ctx.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: Theme.radius), with: .color(Theme.panel))
            let mid = size.width / 2
            let x = mid + mid * value
            let bar = Path(roundedRect: CGRect(x: min(mid, x), y: 6, width: abs(x - mid), height: size.height - 12), cornerRadius: 2)
            if value >= 0 {
                ctx.fill(bar, with: .linearGradient(Theme.rampGradient, startPoint: CGPoint(x: mid, y: 0), endPoint: CGPoint(x: size.width, y: 0)))
            } else {
                ctx.fill(bar, with: .color(Theme.danger))
            }
            ctx.fill(Path(CGRect(x: mid - 0.5, y: 3, width: 1, height: size.height - 6)), with: .color(Theme.textSecondary))
        }
        .overlay(alignment: .leading) { SectionLabel("Correlation").padding(.leading, 8) }
        .overlay(alignment: .trailing) {
            Text(String(format: "%+.2f", value)).font(Theme.readout(11)).padding(.trailing, 8)
        }
        .accessibilityElement()
        .accessibilityLabel("Correlation")
        .accessibilityValue(String(format: "%+.2f", value))
    }
}
