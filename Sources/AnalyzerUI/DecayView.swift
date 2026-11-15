import AnalysisCore
import SwiftUI

/// Impulse response and cumulative spectral decay (waterfall) of the
/// transfer-function measurement, with slice and window controls.
public struct DecayView: View {
    public var impulse: ImpulseResponse?
    public var decay: DecayResult?
    @Binding public var settings: DecaySettings

    public init(impulse: ImpulseResponse?, decay: DecayResult?, settings: Binding<DecaySettings>) {
        self.impulse = impulse
        self.decay = decay
        _settings = settings
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 14) {
                ValueStepper(title: "Range", value: $settings.rangeMs, unit: "ms", steps: [5, 10, 20, 50, 100, 150, 200, 300])
                ValueStepper(title: "Slices", value: Binding(get: { Double(settings.slices) }, set: { settings.slices = Int($0) }),
                        unit: "", steps: [10, 20, 30, 40, 60])
                ValueStepper(title: "Window", value: $settings.windowMs, unit: "ms", steps: [5, 10, 20, 50, 100, 150, 200, 300])
                ValueStepper(title: "Rise", value: $settings.riseMs, unit: "ms", steps: [0.1, 0.2, 0.5, 1, 2, 5])
                ValueStepper(title: "Smoothing", value: Binding(get: { Double(settings.smoothing ?? 0) },
                                                           set: { settings.smoothing = $0 > 0 ? Int($0) : nil }),
                        unit: "", steps: [0, 48, 24, 12, 6, 3], label: { $0 == 0 ? "off" : "1/\(Int($0))" })
                Spacer()
            }
            .font(.system(size: 11))

            Text("Impulse response (source ch 1, response ch 2)").font(.caption).foregroundStyle(.secondary)
            ImpulsePlot(impulse: impulse, spanMs: settings.rangeMs + settings.windowMs)
                .frame(height: 110)
            HStack {
                Text("Cumulative spectral decay (dB)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let d = decay, let last = d.timesMs.last {
                    Text(String(format: "%d slices, 0 to %.0f ms", d.timesMs.count, last))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            DecayWaterfall(decay: decay)
        }
    }
}

/// A compact value picker drawn in SwiftUI: title, value, and - / + buttons
/// that step through `steps`.
private struct ValueStepper: View {
    let title: String
    @Binding var value: Double
    let unit: String
    let steps: [Double]
    var label: (Double) -> String = { v in v == v.rounded() ? "\(Int(v))" : String(format: "%g", v) }

    var body: some View {
        HStack(spacing: 3) {
            Text(title).foregroundStyle(.secondary)
            button("−") { step(-1) }
            Text(label(value) + (unit.isEmpty ? "" : " \(unit)"))
                .monospacedDigit()
                .frame(minWidth: 44)
            button("+") { step(1) }
        }
    }

    private func button(_ t: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(t).frame(width: 16, height: 16)
                .background(RoundedRectangle(cornerRadius: 3).fill(Color.white.opacity(0.12)))
        }
        .buttonStyle(.plain)
    }

    private func step(_ d: Int) {
        let i = steps.firstIndex { $0 == value } ?? steps.indices.min { abs(steps[$0] - value) < abs(steps[$1] - value) } ?? 0
        value = steps[max(0, min(steps.count - 1, i + d))]
    }
}

/// The impulse response, normalised to its peak, from 2 ms before the peak.
struct ImpulsePlot: View {
    let impulse: ImpulseResponse?
    let spanMs: Double

    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.gray.opacity(0.1)))
            var mid = Path()
            mid.move(to: CGPoint(x: 0, y: size.height / 2)); mid.addLine(to: CGPoint(x: size.width, y: size.height / 2))
            ctx.stroke(mid, with: .color(.white.opacity(0.15)), lineWidth: 0.5)
            guard let ir = impulse, ir.samples.count > 1, ir.sampleRate > 0 else {
                ctx.draw(Text("Measure a transfer function (ch 1 source, ch 2 response) to see its impulse response.")
                    .font(.caption).foregroundStyle(.secondary), at: CGPoint(x: size.width / 2, y: size.height / 2))
                return
            }
            let peak = ir.peakIndex
            let scale = Double(max(abs(ir.samples[peak]), 1e-12))
            let preMs = 2.0
            let totalMs = preMs + spanMs
            let start = peak - Int(preMs / 1000 * ir.sampleRate)
            let count = Int(totalMs / 1000 * ir.sampleRate)
            let columns = max(1, Int(size.width))
            var p = Path()
            for c in 0..<columns {
                let a = start + c * count / columns, b = max(a + 1, start + (c + 1) * count / columns)
                var mn = 0.0, mx = 0.0
                for i in a..<b where i >= 0 && i < ir.samples.count {
                    let v = Double(ir.samples[i]) / scale
                    mn = min(mn, v); mx = max(mx, v)
                }
                let x = Double(c)
                p.move(to: CGPoint(x: x, y: size.height / 2 * (1 - mx)))
                p.addLine(to: CGPoint(x: x, y: size.height / 2 * (1 - mn) + 0.5))
            }
            ctx.stroke(p, with: .color(.cyan), lineWidth: 1)
            // Time ticks every 10 or 50 ms from the peak.
            let tick = totalMs > 100 ? 50.0 : (totalMs > 20 ? 10.0 : 2.0)
            var t = 0.0
            while t <= spanMs {
                let x = size.width * (t + preMs) / totalMs
                ctx.draw(Text(String(format: "%.0f ms", t)).font(.system(size: 9).monospacedDigit()).foregroundStyle(.secondary),
                         at: CGPoint(x: x + 16, y: size.height - 7))
                var g = Path()
                g.move(to: CGPoint(x: x, y: 0)); g.addLine(to: CGPoint(x: x, y: size.height))
                ctx.stroke(g, with: .color(.white.opacity(0.1)), lineWidth: 0.5)
                t += tick
            }
        }
    }
}

/// Slices drawn back to front, each offset up and to the right, filled so
/// nearer slices hide farther ones. Colour runs from red (start) to blue (latest).
struct DecayWaterfall: View {
    let decay: DecayResult?
    var floorDB = -60.0

    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.gray.opacity(0.06)))
            guard let d = decay, let first = d.slicesDB.first, first.count > 1 else { return }
            let left = 36.0, bottom = 18.0
            let n = d.slicesDB.count
            let depthX = size.width * 0.18, depthY = size.height * 0.35
            let w = size.width - left - depthX, h = size.height - bottom - depthY
            let scale = LogFrequencyScale(minF: d.minFrequency, maxF: d.maxFrequency)
            func y(_ db: Double) -> Double { h * (-min(max(db, floorDB), 0) / -floorDB) }

            // Front-face grid and labels.
            var grid = Path()
            for db in stride(from: 0.0, through: floorDB, by: -10) {
                let yy = depthY + y(db)
                grid.move(to: CGPoint(x: left, y: yy)); grid.addLine(to: CGPoint(x: left + w, y: yy))
                ctx.draw(Text(String(format: "%.0f", db)).font(.system(size: 9).monospacedDigit()).foregroundStyle(.secondary),
                         at: CGPoint(x: left - 14, y: yy))
            }
            for f in LogFrequencyScale.gridFrequencies where f >= d.minFrequency && f <= d.maxFrequency {
                let xx = left + scale.x(f, width: w)
                grid.move(to: CGPoint(x: xx, y: depthY)); grid.addLine(to: CGPoint(x: xx, y: depthY + h))
                ctx.draw(Text(LogFrequencyScale.label(f)).font(.system(size: 9).monospacedDigit()).foregroundStyle(.secondary),
                         at: CGPoint(x: xx, y: size.height - bottom / 2))
            }
            ctx.stroke(grid, with: .color(.white.opacity(0.1)), lineWidth: 0.5)

            for k in stride(from: n - 1, through: 0, by: -1) {
                let frac = n > 1 ? Double(k) / Double(n - 1) : 0
                let ox = left + depthX * frac, oy = depthY * (1 - frac)
                let row = d.slicesDB[k]
                var p = Path()
                p.move(to: CGPoint(x: ox, y: oy + h))
                for (c, db) in row.enumerated() {
                    p.addLine(to: CGPoint(x: ox + w * Double(c) / Double(row.count - 1), y: oy + y(db)))
                }
                p.addLine(to: CGPoint(x: ox + w, y: oy + h))
                p.closeSubpath()
                let color = Color(hue: 0.66 * frac, saturation: 0.85, brightness: 0.95)
                ctx.fill(p, with: .color(Color(white: 0.06)))
                ctx.fill(p, with: .color(color.opacity(0.18)))
                ctx.stroke(p, with: .color(color), lineWidth: 1)
            }
            if let last = d.timesMs.last {
                ctx.draw(Text(String(format: "%.0f ms", last)).font(.system(size: 9).monospacedDigit()).foregroundStyle(.secondary),
                         at: CGPoint(x: left + depthX + w + 4, y: 8), anchor: .trailing)
            }
        }
    }
}
