import AnalysisCore
import SwiftUI

/// Phase vs frequency on polar axes: angle is phase (0° up, +90° right),
/// radius is log frequency (20 Hz at the centre, 20 kHz at the rim). Colour
/// shows magnitude (blue -24 dB, green 0 dB, red +24 dB) and opacity shows
/// coherence, so unreliable parts fade out. A system with flat phase stays
/// on one spoke; delay winds the trace round the circle.
public struct PolarPhaseView: View {
    public var result: TransferFunctionResult?

    public init(result: TransferFunctionResult?) { self.result = result }

    public var body: some View {
        Canvas { ctx, size in
            let side = min(size.width, size.height)
            let radius = side / 2 - 14
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let scale = LogFrequencyScale()
            func point(_ f: Double, _ degrees: Double) -> CGPoint {
                let r = Double(radius) * scale.x(f, width: 1)
                let a = degrees * .pi / 180
                return CGPoint(x: Double(c.x) + r * sin(a), y: Double(c.y) - r * cos(a))
            }

            ctx.fill(Path(ellipseIn: CGRect(x: c.x - radius, y: c.y - radius, width: 2 * radius, height: 2 * radius)),
                     with: .color(.gray.opacity(0.1)))
            var grid = Path()
            for f in [100.0, 1000, 10000] {
                let r = Double(radius) * scale.x(f, width: 1)
                grid.addEllipse(in: CGRect(x: Double(c.x) - r, y: Double(c.y) - r, width: 2 * r, height: 2 * r))
                ctx.draw(Text(LogFrequencyScale.label(f)).font(.system(size: 8).monospacedDigit()).foregroundStyle(.secondary),
                         at: CGPoint(x: Double(c.x) + 2, y: Double(c.y) - r - 5), anchor: .leading)
            }
            for deg in stride(from: 0.0, to: 360, by: 45) {
                grid.move(to: c); grid.addLine(to: point(20000, deg))
            }
            ctx.stroke(grid, with: .color(.white.opacity(0.12)), lineWidth: 0.5)
            for (deg, label) in [(0.0, "0°"), (90, "+90°"), (180, "180°"), (-90, "−90°")] {
                let a = deg * .pi / 180, r = Double(radius) + 8
                ctx.draw(Text(label).font(.system(size: 9)).foregroundStyle(.secondary),
                         at: CGPoint(x: Double(c.x) + r * sin(a), y: Double(c.y) - r * cos(a)))
            }

            guard let r = result, !r.frequencies.isEmpty else { return }
            // One point per radial step, averaged over its bins (phase as a circular mean).
            var last: CGPoint?
            for col in columns(frequencies: r.frequencies, width: Double(radius), scale: scale) {
                let n = Double(col.indices.count)
                var s = 0.0, co = 0.0, mag = 0.0, coh = 0.0, f = 0.0
                for i in col.indices {
                    s += sin(r.phaseDegrees[i] * .pi / 180); co += cos(r.phaseDegrees[i] * .pi / 180)
                    mag += r.magnitudeDB[i]; coh += r.coherence[i]; f += r.frequencies[i]
                }
                let pt = point(f / n, atan2(s, co) * 180 / .pi)
                let hue = 0.66 * (1 - min(max((mag / n + 24) / 48, 0), 1))
                let color = Color(hue: hue, saturation: 0.9, brightness: 1).opacity(0.15 + 0.85 * min(max(coh / n, 0), 1))
                if let last {
                    var seg = Path()
                    seg.move(to: last); seg.addLine(to: pt)
                    ctx.stroke(seg, with: .color(color), lineWidth: 1.5)
                }
                ctx.fill(Path(ellipseIn: CGRect(x: pt.x - 1.5, y: pt.y - 1.5, width: 3, height: 3)), with: .color(color))
                last = pt
            }
        }
    }
}
