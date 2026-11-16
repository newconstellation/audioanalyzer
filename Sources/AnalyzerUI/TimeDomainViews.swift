import AnalysisCore
import CoreGraphics
import SwiftUI

// MARK: - Oscilloscope

/// Triggered oscilloscope: channel 1 green, channel 2 orange, -1...1.
public struct OscilloscopeView: View {
    public var trace: ScopeTrace
    public var settings: ScopeSettings

    public init(trace: ScopeTrace, settings: ScopeSettings = ScopeSettings()) {
        self.trace = trace
        self.settings = settings
    }

    static let colors: [Color] = Theme.series

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                SectionLabel("Oscilloscope")
                Spacer()
                Text(caption).font(Theme.readout(10)).foregroundStyle(Theme.textSecondary)
            }
            Canvas { ctx, size in
                ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Theme.panel))
                var grid = Path()
                for i in 1..<10 {
                    let x = size.width * Double(i) / 10
                    grid.move(to: CGPoint(x: x, y: 0)); grid.addLine(to: CGPoint(x: x, y: size.height))
                }
                for i in 1..<8 {
                    let y = size.height * Double(i) / 8
                    grid.move(to: CGPoint(x: 0, y: y)); grid.addLine(to: CGPoint(x: size.width, y: y))
                }
                ctx.stroke(grid, with: .color(Theme.grid.opacity(0.8)), lineWidth: 0.5)
                let yOf = { (v: Double) -> Double in Double(size.height) / 2 * (1 - min(max(v, -1.05), 1.05)) }
                if let t = trace.triggerIndex, let len = trace.channels.first?.count, len > 1 {
                    let x = size.width * Double(t) / Double(len - 1)
                    var marker = Path()
                    marker.move(to: CGPoint(x: x, y: 0)); marker.addLine(to: CGPoint(x: x, y: size.height))
                    ctx.stroke(marker, with: .color(Theme.warning.opacity(0.45)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    var level = Path()
                    let y = yOf(settings.level)
                    level.move(to: CGPoint(x: 0, y: y)); level.addLine(to: CGPoint(x: size.width, y: y))
                    ctx.stroke(level, with: .color(Theme.warning.opacity(0.3)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
                for (c, samples) in trace.channels.enumerated().reversed() where samples.count > 1 {
                    ctx.stroke(polyline(samples, width: size.width, y: yOf),
                               with: .color(Self.colors[c % Self.colors.count]), lineWidth: 1)
                }
            }
        }
    }

    private var caption: String {
        let len = trace.channels.first?.count ?? 0
        let ms = trace.sampleRate > 0 ? Double(len) / trace.sampleRate * 1000 : 0
        let trig = trace.triggerIndex == nil ? (settings.mode == .free ? "free run" : "no trigger") : "\(settings.mode.rawValue) @ \(String(format: "%.2f", settings.level))"
        return String(format: "%.1f ms, ", ms) + trig
    }

    /// One vertex per pixel column at most: min/max of each column's samples.
    private func polyline(_ x: [Float], width: Double, y: (Double) -> Double) -> Path {
        var p = Path()
        let n = x.count
        let columns = max(1, Int(width.rounded()))
        if n <= columns * 2 {
            for (i, v) in x.enumerated() {
                let pt = CGPoint(x: width * Double(i) / Double(n - 1), y: y(Double(v)))
                if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
            }
            return p
        }
        for c in 0..<columns {
            let lo = c * n / columns, hi = max(lo + 1, (c + 1) * n / columns)
            var mn = Float.infinity, mx = -Float.infinity
            for v in x[lo..<hi] { mn = min(mn, v); mx = max(mx, v) }
            let px = width * Double(c) / Double(columns - 1)
            let a = CGPoint(x: px, y: y(Double(mx))), b = CGPoint(x: px, y: y(Double(mn)))
            if c == 0 { p.move(to: a) } else { p.addLine(to: a) }
            p.addLine(to: b)
        }
        return p
    }
}

// MARK: - Vectorscope

/// Lissajous / vectorscope: mid (L+R) up, side (L-R) across, so a mono
/// signal is a vertical line and out-of-phase is horizontal.
public struct VectorscopeView: View {
    public var left: [Float]
    public var right: [Float]
    public var correlation: Double

    public init(left: [Float], right: [Float], correlation: Double) {
        self.left = left
        self.right = right
        self.correlation = correlation
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionLabel("Vectorscope")
            Canvas { ctx, size in
                let side = min(size.width, size.height)
                let rect = CGRect(x: (size.width - side) / 2, y: (size.height - side) / 2, width: side, height: side)
                ctx.fill(Path(ellipseIn: rect), with: .color(Theme.panel))
                var axes = Path()
                axes.move(to: CGPoint(x: rect.midX, y: rect.minY)); axes.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
                axes.move(to: CGPoint(x: rect.minX, y: rect.midY)); axes.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
                // L and R axes, 45 degrees either side of mid.
                let r = side / 2
                let d = r / 2.0.squareRoot()
                axes.move(to: CGPoint(x: rect.midX - d, y: rect.midY - d)); axes.addLine(to: CGPoint(x: rect.midX + d, y: rect.midY + d))
                axes.move(to: CGPoint(x: rect.midX + d, y: rect.midY - d)); axes.addLine(to: CGPoint(x: rect.midX - d, y: rect.midY + d))
                ctx.stroke(axes, with: .color(Theme.grid.opacity(0.8)), lineWidth: 0.5)
                ctx.draw(Text("L").font(.system(size: 9)).foregroundStyle(Theme.textSecondary), at: CGPoint(x: rect.midX - d - 6, y: rect.midY - d - 6))
                ctx.draw(Text("R").font(.system(size: 9)).foregroundStyle(Theme.textSecondary), at: CGPoint(x: rect.midX + d + 6, y: rect.midY - d - 6))

                let n = min(left.count, right.count)
                guard n > 1 else { return }
                // Scale so full-scale L or R reaches the circle.
                let k = r / 2.0.squareRoot()
                var dots = Path()
                for i in 0..<n {
                    let l = Double(left[i]), rr = Double(right[i])
                    let x = rect.midX + k * (rr - l)   // side: R to the right
                    let y = rect.midY - k * (l + rr)   // mid: up
                    dots.addRect(CGRect(x: x - 0.6, y: y - 0.6, width: 1.2, height: 1.2))
                }
                ctx.fill(dots, with: .color(Theme.signal.opacity(0.75)))
            }
            .aspectRatio(1, contentMode: .fit)
            CorrelationBar(value: correlation).frame(height: 18)
        }
    }
}

// MARK: - Waterfall

/// Spectrum over time: newest row at the top, log frequency across.
public struct WaterfallView: View {
    public var rows: [[Float]]
    public var rowSeconds: Double
    public var capacity: Int
    public var range: ClosedRange<Double>

    public init(rows: [[Float]], rowSeconds: Double, capacity: Int = 300, range: ClosedRange<Double> = -120...0) {
        self.rows = rows
        self.rowSeconds = rowSeconds
        self.capacity = capacity
        self.range = range
    }

    public var body: some View {
        let span = max(rowSeconds * Double(capacity), 1)
        let step = span > 10 ? 5.0 : 1.0
        let ticks = stride(from: 0.0, through: span, by: step).map { (value: -$0, label: $0 == 0 ? "now" : String(format: "-%.0f s", $0)) }
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                SectionLabel("Waterfall (dBFS)")
                Spacer()
                ColorScaleBar(range: range).frame(width: 220, height: 12)
            }
            FrequencyPlot(yTicks: ticks, yRange: -span...0) { _, _ in
                GeometryReader { geo in
                    if let image = makeImage() {
                        let h = geo.size.height * Double(rows.count) / Double(capacity)
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .interpolation(.medium)
                            .frame(width: geo.size.width, height: h)
                    }
                }
            }
        }
    }

    /// One pixel per column and row, newest row first.
    private func makeImage() -> CGImage? {
        guard let w = rows.first?.count, w > 0 else { return nil }
        let h = rows.count
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        for (r, row) in rows.reversed().enumerated() {
            for c in 0..<min(w, row.count) {
                let (red, green, blue) = heatColor(Double(row[c]), range: range)
                let o = (r * w + c) * 4
                pixels[o] = red; pixels[o + 1] = green; pixels[o + 2] = blue; pixels[o + 3] = 255
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

/// Navy, deep violet, violet-blue, cyan, white from the bottom of the range to the top
/// (the app icon's ramp, rising in lightness).
func heatColor(_ db: Double, range: ClosedRange<Double>) -> (UInt8, UInt8, UInt8) {
    let stops: [(Double, Double, Double)] = [(0.04, 0.05, 0.09), (0.06, 0.06, 0.16), (0.2, 0.09, 0.42), (0.38, 0.3, 0.95), (0.25, 0.85, 1), (0.95, 0.99, 1)]
    let t = min(max((db - range.lowerBound) / (range.upperBound - range.lowerBound), 0), 1) * Double(stops.count - 1)
    let i = min(Int(t), stops.count - 2), f = t - Double(i)
    let a = stops[i], b = stops[i + 1]
    func mix(_ x: Double, _ y: Double) -> UInt8 { UInt8((x + (y - x) * f) * 255) }
    return (mix(a.0, b.0), mix(a.1, b.1), mix(a.2, b.2))
}

private struct ColorScaleBar: View {
    let range: ClosedRange<Double>
    var body: some View {
        HStack(spacing: 4) {
            Text(String(format: "%.0f", range.lowerBound)).font(Theme.axis).foregroundStyle(Theme.textSecondary)
            Canvas { ctx, size in
                let steps = 64
                for s in 0..<steps {
                    let db = range.lowerBound + (range.upperBound - range.lowerBound) * Double(s) / Double(steps - 1)
                    let (r, g, b) = heatColor(db, range: range)
                    ctx.fill(Path(CGRect(x: size.width * Double(s) / Double(steps), y: 0,
                                         width: size.width / Double(steps) + 0.5, height: size.height)),
                             with: .color(Color(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255)))
                }
            }
            Text(String(format: "%.0f", range.upperBound)).font(Theme.axis).foregroundStyle(Theme.textSecondary)
        }
    }
}

// MARK: - History strips

/// One or more series over time, newest at the right edge.
struct HistoryStrip: View {
    struct Series {
        var values: [Double]
        var color: Color
    }
    let title: String
    let series: [Series]
    let range: ClosedRange<Double>
    let ticks: [(value: Double, label: String)]
    let capacity: Int
    var readout: String = ""
    /// Draws the first series as a filled area from zero.
    var filled = false

    private let leftGutter = 40.0

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                SectionLabel(title)
                Spacer()
                Text(readout).font(Theme.readout(10))
            }
            GeometryReader { geo in
                let w = geo.size.width - leftGutter, h = geo.size.height
                let y = { (v: Double) in h * (range.upperBound - min(max(v, range.lowerBound), range.upperBound)) / (range.upperBound - range.lowerBound) }
                ZStack(alignment: .topLeading) {
                    Canvas { ctx, size in
                        ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Theme.panel))
                        var grid = Path()
                        for t in ticks {
                            grid.move(to: CGPoint(x: 0, y: y(t.value))); grid.addLine(to: CGPoint(x: size.width, y: y(t.value)))
                        }
                        ctx.stroke(grid, with: .color(Theme.grid.opacity(0.8)), lineWidth: 0.5)
                        let dx = size.width / Double(max(capacity - 1, 1))
                        for (s, line) in series.enumerated() where line.values.count > 1 {
                            let x0 = size.width - dx * Double(line.values.count - 1)
                            var p = Path()
                            for (i, v) in line.values.enumerated() {
                                let pt = CGPoint(x: x0 + dx * Double(i), y: y(v))
                                if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                            }
                            if filled && s == 0 {
                                var area = p
                                area.addLine(to: CGPoint(x: size.width, y: y(0)))
                                area.addLine(to: CGPoint(x: x0, y: y(0)))
                                area.closeSubpath()
                                ctx.fill(area, with: .color(line.color.opacity(0.3)))
                            }
                            ctx.stroke(p, with: .color(line.color), lineWidth: 1)
                        }
                    }
                    .frame(width: w, height: h)
                    .offset(x: leftGutter)
                    ForEach(Array(ticks.enumerated()), id: \.offset) { _, t in
                        Text(t.label)
                            .font(Theme.axis)
                            .foregroundStyle(Theme.textSecondary)
                            .frame(width: leftGutter - 4, alignment: .trailing)
                            .position(x: (leftGutter - 4) / 2, y: min(max(y(t.value), 5), h - 5))
                    }
                }
            }
        }
    }
}

/// Correlation, balance and peak/RMS power over the last 30 seconds.
public struct HistoriesView: View {
    public var snapshot: AnalyzerSnapshot
    public var capacity: Int

    public init(snapshot: AnalyzerSnapshot, capacity: Int = 600) {
        self.snapshot = snapshot
        self.capacity = capacity
    }

    public var body: some View {
        let power = snapshot.powerHistory
        VStack(spacing: 8) {
            HistoryStrip(title: "Correlation", series: [.init(values: snapshot.correlationHistory, color: Theme.signal)],
                         range: -1...1, ticks: [(1, "+1"), (0, "0"), (-1, "-1")], capacity: capacity,
                         readout: String(format: "%+.2f", snapshot.correlation), filled: true)
            HistoryStrip(title: "Balance (+ is left)", series: [.init(values: snapshot.balanceHistory, color: Theme.signal2)],
                         range: -1...1, ticks: [(1, "L"), (0, "0"), (-1, "R")], capacity: capacity,
                         readout: String(format: "%+.2f", snapshot.balance), filled: true)
            HistoryStrip(title: "Power, peak and RMS (dBFS)",
                         series: power.enumerated().flatMap { item -> [HistoryStrip.Series] in
                             let c = item.offset, points = item.element
                             let color = OscilloscopeView.colors[c % OscilloscopeView.colors.count]
                             return [.init(values: points.map(\.peakDB), color: color.opacity(0.5)),
                                     .init(values: points.map(\.rmsDB), color: color)]
                         },
                         range: -80...0, ticks: [(0, "0"), (-20, "-20"), (-40, "-40"), (-60, "-60"), (-80, "-80")],
                         capacity: capacity,
                         readout: power.first?.last.map { String(format: "ch1 %.1f / %.1f", $0.peakDB, $0.rmsDB) } ?? "")
                .frame(maxHeight: .infinity)
        }
    }
}
