import AnalysisCore
import SwiftUI

// MARK: - Shared plot helpers

/// Log frequency axis from `minF` to `maxF`, mapped to a width.
struct LogFrequencyScale {
    var minF = 20.0
    var maxF = 20000.0
    func x(_ f: Double, width: Double) -> Double {
        width * log(max(f, minF) / minF) / log(maxF / minF)
    }
    static let gridFrequencies: [Double] = [20, 50, 100, 200, 500, 1000, 2000, 5000, 10000, 20000]
    static func label(_ f: Double) -> String {
        f >= 1000 ? (f.truncatingRemainder(dividingBy: 1000) == 0 ? "\(Int(f / 1000))k" : String(format: "%.1fk", f / 1000)) : "\(Int(f))"
    }
}

/// A plot area with a log frequency grid, labelled underneath, and a labelled
/// vertical axis on the left.
struct FrequencyPlot<Content: View>: View {
    var scale = LogFrequencyScale()
    var yTicks: [(value: Double, label: String)]
    var yRange: ClosedRange<Double>
    @ViewBuilder var content: (_ x: @escaping (Double, Double) -> Double, _ y: @escaping (Double, Double) -> Double) -> Content

    private let leftGutter = 40.0, bottomGutter = 16.0

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width - leftGutter, h = geo.size.height - bottomGutter
            let xf: (Double, Double) -> Double = { f, width in scale.x(f, width: width) }
            let yf: (Double, Double) -> Double = { v, height in
                height * (yRange.upperBound - min(max(v, yRange.lowerBound), yRange.upperBound)) / (yRange.upperBound - yRange.lowerBound)
            }
            ZStack(alignment: .topLeading) {
                Canvas { ctx, size in
                    ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.gray.opacity(0.1)))
                    var grid = Path()
                    for f in LogFrequencyScale.gridFrequencies where f <= scale.maxF {
                        let x = xf(f, size.width)
                        grid.move(to: CGPoint(x: x, y: 0)); grid.addLine(to: CGPoint(x: x, y: size.height))
                    }
                    for t in yTicks {
                        let y = yf(t.value, size.height)
                        grid.move(to: CGPoint(x: 0, y: y)); grid.addLine(to: CGPoint(x: size.width, y: y))
                    }
                    ctx.stroke(grid, with: .color(.white.opacity(0.12)), lineWidth: 0.5)
                }
                .frame(width: w, height: h)
                .offset(x: leftGutter)

                content(xf, yf)
                    .frame(width: w, height: h)
                    .offset(x: leftGutter)

                ForEach(Array(yTicks.enumerated()), id: \.offset) { _, t in
                    Text(t.label)
                        .font(.system(size: 9).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: leftGutter - 4, alignment: .trailing)
                        .position(x: (leftGutter - 4) / 2, y: yf(t.value, h))
                }
                ForEach(LogFrequencyScale.gridFrequencies.filter { $0 <= scale.maxF }, id: \.self) { f in
                    Text(LogFrequencyScale.label(f))
                        .font(.system(size: 9).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .position(x: leftGutter + xf(f, w), y: h + bottomGutter / 2 + 1)
                }
            }
        }
    }
}

/// Groups bins by the pixel column they land in on a log axis, so traces
/// draw one point per column.
func columns(frequencies: [Double], width: Double, scale: LogFrequencyScale) -> [(x: Double, indices: Range<Int>)] {
    var out: [(Double, Range<Int>)] = []
    var start = -1, column = -1.0
    for (i, f) in frequencies.enumerated() where f >= scale.minF && f <= scale.maxF {
        let c = scale.x(f, width: width).rounded()
        if c != column {
            if start >= 0 { out.append((column, start..<i)) }
            start = i; column = c
        }
    }
    if start >= 0 { out.append((column, start..<frequencies.count)) }
    return out
}

// MARK: - Transfer function

public struct TransferFunctionView: View {
    let result: TransferFunctionResult?
    var onFindDelay: () -> Void

    public init(result: TransferFunctionResult?, onFindDelay: @escaping () -> Void = {}) {
        self.result = result
        self.onFindDelay = onFindDelay
    }

    private static let magTicks: [(Double, String)] = stride(from: 24.0, through: -24, by: -6).map { ($0, String(format: "%+.0f", $0)) }
    private static let phaseTicks: [(Double, String)] = stride(from: 180.0, through: -180, by: -90).map { ($0, "\(Int($0))°") }

    public var body: some View {
        HStack(alignment: .top, spacing: 12) {
            plots
            VStack(alignment: .leading, spacing: 4) {
                Text("Phase vs frequency (polar)").font(.caption).foregroundStyle(.secondary)
                PolarPhaseView(result: result)
                    .aspectRatio(1, contentMode: .fit)
                Text("Angle: phase. Radius: 20 Hz (centre) to 20 kHz. Colour: magnitude. Faint: low coherence.")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: 230)
        }
    }

    private var plots: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 16) {
                Text("Source: ch 1   Response: ch 2").foregroundStyle(.secondary)
                if let r = result {
                    Text(String(format: "Delay comp: %d smp (%.2f ms)", r.delayCompensationSamples,
                                Double(r.delayCompensationSamples) / max(r.sampleRate, 1) * 1000))
                    Text("Averages: \(r.averages)").foregroundStyle(.secondary)
                }
                Spacer()
                PlainButton(title: "Find delay", action: onFindDelay)
            }
            .font(.system(size: 11))

            Text("Magnitude (dB)").font(.caption).foregroundStyle(.secondary)
            FrequencyPlot(yTicks: Self.magTicks.map { (value: $0.0, label: $0.1) }, yRange: -24...24) { x, y in
                Canvas { ctx, size in
                    guard let r = result, !r.frequencies.isEmpty else { return }
                    drawTrace(ctx, size: size, r: r, values: r.magnitudeDB, x: x, y: y, color: .cyan, circular: false)
                }
            }
            Text("Phase").font(.caption).foregroundStyle(.secondary)
            FrequencyPlot(yTicks: Self.phaseTicks.map { (value: $0.0, label: $0.1) }, yRange: -180...180) { x, y in
                Canvas { ctx, size in
                    guard let r = result, !r.frequencies.isEmpty else { return }
                    drawTrace(ctx, size: size, r: r, values: r.phaseDegrees, x: x, y: y, color: .orange, circular: true)
                }
            }
            Text("Coherence").font(.caption).foregroundStyle(.secondary)
            FrequencyPlot(yTicks: [(1, "1.0"), (0.5, "0.5"), (0, "0")], yRange: 0...1) { x, y in
                Canvas { ctx, size in
                    guard let r = result, !r.frequencies.isEmpty else { return }
                    let scale = LogFrequencyScale()
                    var p = Path()
                    p.move(to: CGPoint(x: 0, y: size.height))
                    for c in columns(frequencies: r.frequencies, width: size.width, scale: scale) {
                        let v = c.indices.map { r.coherence[$0] }.reduce(0, +) / Double(c.indices.count)
                        p.addLine(to: CGPoint(x: c.x, y: y(v, size.height)))
                    }
                    p.addLine(to: CGPoint(x: size.width, y: size.height))
                    p.closeSubpath()
                    ctx.fill(p, with: .color(.green.opacity(0.5)))
                }
            }
            .frame(height: 60)
        }
    }

    /// One point per pixel column, averaged over the bins in it. Columns with
    /// low coherence are drawn faint, since their values are unreliable.
    private func drawTrace(_ ctx: GraphicsContext, size: CGSize, r: TransferFunctionResult, values: [Double],
                           x: (Double, Double) -> Double, y: (Double, Double) -> Double, color: Color, circular: Bool) {
        let scale = LogFrequencyScale()
        var strong = Path(), weak = Path()
        var last: (CGPoint, Bool)?
        for c in columns(frequencies: r.frequencies, width: size.width, scale: scale) {
            let n = Double(c.indices.count)
            let v: Double
            if circular {
                var s = 0.0, co = 0.0
                for i in c.indices { s += sin(values[i] * .pi / 180); co += cos(values[i] * .pi / 180) }
                v = atan2(s, co) * 180 / .pi
            } else {
                v = c.indices.map { values[$0] }.reduce(0, +) / n
            }
            let coh = c.indices.map { r.coherence[$0] }.reduce(0, +) / n
            let pt = CGPoint(x: c.x, y: y(v, size.height))
            let good = coh >= 0.5
            if let (prev, _) = last {
                // Don't join phase across a wrap.
                let jump = circular && abs(pt.y - prev.y) > size.height / 2
                if !jump {
                    if good {
                        strong.move(to: prev); strong.addLine(to: pt)
                    } else {
                        weak.move(to: prev); weak.addLine(to: pt)
                    }
                }
            }
            last = (pt, good)
        }
        ctx.stroke(weak, with: .color(color.opacity(0.25)), lineWidth: 1)
        ctx.stroke(strong, with: .color(color), lineWidth: 1.5)
    }
}

// MARK: - Distortion

public struct DistortionView: View {
    let result: DistortionResult?

    public init(result: DistortionResult?) { self.result = result }

    private static let dbTicks: [(value: Double, label: String)] = stride(from: 0.0, through: -160, by: -20).map { ($0, "\(Int($0))") }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let r = result {
                HStack(spacing: 12) {
                    Readout(title: "Fundamental", value: String(format: "%.2f Hz", r.fundamentalHz),
                            detail: String(format: "%.2f dBFS", r.fundamentalDBFS))
                    Readout(title: "THD", value: String(format: "%.4f %%", r.thdPercent),
                            detail: String(format: "%.1f dB", r.thdDB))
                    Readout(title: "THD+N", value: String(format: "%.4f %%", r.thdnPercent),
                            detail: String(format: "%.1f dB", r.thdnDB))
                    Readout(title: "SINAD", value: String(format: "%.1f dB", r.sinadDB), detail: "20 Hz – 20 kHz")
                }
                HStack(alignment: .top, spacing: 12) {
                    FrequencyPlot(yTicks: Self.dbTicks, yRange: -160...0) { x, y in
                        Canvas { ctx, size in
                            let freqs = r.spectrumDB.indices.map { Double($0) * r.binWidth }
                            var p = Path(); var started = false
                            for c in columns(frequencies: freqs, width: size.width, scale: LogFrequencyScale()) {
                                let v = c.indices.map { r.spectrumDB[$0] }.max() ?? floorDB
                                let pt = CGPoint(x: c.x, y: y(v, size.height))
                                if started { p.addLine(to: pt) } else { p.move(to: pt); started = true }
                            }
                            ctx.stroke(p, with: .color(.cyan), lineWidth: 1)
                            // Mark the fundamental and harmonics.
                            for h in 1...(r.harmonicsDBc.count + 1) {
                                let f = r.fundamentalHz * Double(h)
                                let hx = x(f, size.width)
                                ctx.stroke(Path { $0.move(to: CGPoint(x: hx, y: 0)); $0.addLine(to: CGPoint(x: hx, y: size.height)) },
                                           with: .color((h == 1 ? Color.green : Color.yellow).opacity(0.35)), lineWidth: 1)
                            }
                        }
                    }
                    HarmonicBars(harmonicsDBc: r.harmonicsDBc)
                        .frame(width: 220)
                }
            } else {
                Text("Feed a single tone into channel 1 to measure distortion.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

struct Readout: View {
    let title: String, value: String, detail: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 20, weight: .semibold).monospacedDigit())
            Text(detail).font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.06)))
    }
}

/// Harmonic levels in dBc, H2 upwards, 0 to -160 dBc.
struct HarmonicBars: View {
    let harmonicsDBc: [Double]
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Harmonics (dBc)").font(.caption).foregroundStyle(.secondary)
            Canvas { ctx, size in
                ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.gray.opacity(0.1)))
                guard !harmonicsDBc.isEmpty else { return }
                let labelBand = 14.0
                let plotH = size.height - labelBand
                let slot = size.width / Double(harmonicsDBc.count)
                for (i, db) in harmonicsDBc.enumerated() {
                    let cx = Double(i) * slot + slot / 2
                    let h = plotH * max(0, min(1, (db + 160) / 160))
                    ctx.fill(Path(CGRect(x: cx - slot * 0.3, y: plotH - h, width: slot * 0.6, height: h)),
                             with: .color(.yellow))
                    ctx.draw(Text(String(format: "%.0f", db)).font(.system(size: 8).monospacedDigit()),
                             at: CGPoint(x: cx, y: max(6, plotH - h - 7)))
                    ctx.draw(Text("H\(i + 2)").font(.system(size: 9)).foregroundStyle(.secondary),
                             at: CGPoint(x: cx, y: size.height - labelBand / 2))
                }
            }
        }
    }
}

/// A button drawn entirely in SwiftUI so it shows in offscreen renders.
struct PlainButton: View {
    let title: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.15)))
        }
        .buttonStyle(.plain)
    }
}
