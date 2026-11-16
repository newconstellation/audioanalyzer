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
    /// Shown in small capitals inside the plot's top-left corner.
    var title: String? = nil
    @ViewBuilder var content: (_ x: @escaping (Double, Double) -> Double, _ y: @escaping (Double, Double) -> Double) -> Content

    // Top and right gutters keep the end labels (0 dB, 20k) from clipping.
    private let leftGutter = 40.0, bottomGutter = 16.0, topGutter = 6.0, rightGutter = 12.0

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width - leftGutter - rightGutter, h = geo.size.height - bottomGutter - topGutter
            let xf: (Double, Double) -> Double = { f, width in scale.x(f, width: width) }
            let yf: (Double, Double) -> Double = { v, height in
                height * (yRange.upperBound - min(max(v, yRange.lowerBound), yRange.upperBound)) / (yRange.upperBound - yRange.lowerBound)
            }
            ZStack(alignment: .topLeading) {
                Canvas { ctx, size in
                    let frame = Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 6)
                    ctx.fill(frame, with: .color(Theme.panel))
                    var grid = Path(), major = Path()
                    for f in LogFrequencyScale.gridFrequencies where f <= scale.maxF {
                        let x = xf(f, size.width)
                        let isMajor = f == 100 || f == 1000 || f == 10000
                        if isMajor {
                            major.move(to: CGPoint(x: x, y: 0)); major.addLine(to: CGPoint(x: x, y: size.height))
                        } else {
                            grid.move(to: CGPoint(x: x, y: 0)); grid.addLine(to: CGPoint(x: x, y: size.height))
                        }
                    }
                    for t in yTicks {
                        let y = yf(t.value, size.height)
                        grid.move(to: CGPoint(x: 0, y: y)); grid.addLine(to: CGPoint(x: size.width, y: y))
                    }
                    ctx.stroke(grid, with: .color(Theme.grid.opacity(0.6)), lineWidth: 0.5)
                    ctx.stroke(major, with: .color(Theme.grid), lineWidth: 0.8)
                    ctx.stroke(frame, with: .color(Theme.hairline), lineWidth: 1)
                }
                .frame(width: w, height: h)
                .offset(x: leftGutter, y: topGutter)

                content(xf, yf)
                    .frame(width: w, height: h)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .offset(x: leftGutter, y: topGutter)

                if let title {
                    SectionLabel(title)
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 3).fill(Theme.panel.opacity(0.85)))
                        .padding(.leading, leftGutter + 4).padding(.top, topGutter + 5)
                        .allowsHitTesting(false)
                }

                ForEach(Array(yTicks.enumerated()), id: \.offset) { _, t in
                    Text(t.label)
                        .font(Theme.axis)
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: leftGutter - 4, alignment: .trailing)
                        .position(x: (leftGutter - 4) / 2, y: topGutter + yf(t.value, h))
                }
                ForEach(LogFrequencyScale.gridFrequencies.filter { $0 <= scale.maxF }, id: \.self) { f in
                    Text(LogFrequencyScale.label(f))
                        .font(Theme.axis)
                        .foregroundStyle(Theme.textSecondary)
                        .position(x: leftGutter + xf(f, w), y: topGutter + h + bottomGutter / 2 + 1)
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
    /// Each mic's own response when several are averaged (drawn faintly).
    var perMic: [TransferFunctionResult]
    var averaging: SpatialAverage
    var onFindDelay: () -> Void

    public init(result: TransferFunctionResult?, perMic: [TransferFunctionResult] = [],
                averaging: SpatialAverage = .coherenceWeighted, onFindDelay: @escaping () -> Void = {}) {
        self.result = result
        self.perMic = perMic
        self.averaging = averaging
        self.onFindDelay = onFindDelay
    }

    private static let magTicks: [(Double, String)] = stride(from: 24.0, through: -24, by: -6).map { ($0, String(format: "%+.0f", $0)) }
    private static let phaseTicks: [(Double, String)] = stride(from: 180.0, through: -180, by: -90).map { ($0, "\(Int($0))°") }

    public var body: some View {
        HStack(alignment: .top, spacing: 12) {
            plots
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel("Phase · polar")
                PolarPhaseView(result: result)
                    .aspectRatio(1, contentMode: .fit)
                Text("Angle: phase. Radius: 20 Hz (centre) to 20 kHz. Colour: frequency. Faint: low coherence.")
                    .font(.system(size: 9)).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .panel()
            .frame(width: 240)
        }
    }

    private var plots: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 14) {
                SectionLabel(perMic.count > 1 ? "Average of \(perMic.count) mics · \(averaging.rawValue)" : "Ref → mic")
                if let r = result {
                    if perMic.count > 1 {
                        LabeledReadout(label: "Delays", value: perMic.map { "\($0.delayCompensationSamples)" }.joined(separator: ", ") + " smp")
                    } else {
                        LabeledReadout(label: "Delay", value: String(format: "%d smp · %.2f ms", r.delayCompensationSamples,
                                                                   Double(r.delayCompensationSamples) / max(r.sampleRate, 1) * 1000))
                    }
                    LabeledReadout(label: "Avg", value: "\(r.averages)")
                }
                Spacer()
                PlainButton(title: "Find delay", action: onFindDelay)
            }

            FrequencyPlot(yTicks: Self.magTicks.map { (value: $0.0, label: $0.1) }, yRange: -24...24, title: "Magnitude dB") { x, y in
                Canvas { ctx, size in
                    guard let r = result, !r.frequencies.isEmpty else { return }
                    for m in perMic where !m.frequencies.isEmpty {
                        drawTrace(ctx, size: size, r: m, values: m.magnitudeDB, x: x, y: y, shading: .color(Theme.text.opacity(0.3)), circular: false)
                    }
                    fillUnder(ctx, size: size, r: r, values: r.magnitudeDB, y: y)
                    drawTrace(ctx, size: size, r: r, values: r.magnitudeDB, x: x, y: y, shading: Theme.frequencyShading(width: size.width), circular: false)
                }
            }
            FrequencyPlot(yTicks: Self.phaseTicks.map { (value: $0.0, label: $0.1) }, yRange: -180...180, title: "Phase") { x, y in
                Canvas { ctx, size in
                    guard let r = result, !r.frequencies.isEmpty else { return }
                    drawTrace(ctx, size: size, r: r, values: r.phaseDegrees, x: x, y: y, shading: Theme.frequencyShading(width: size.width), circular: true)
                }
            }
            FrequencyPlot(yTicks: [(1, "1.0"), (0.5, "0.5"), (0, "0")], yRange: 0...1, title: "Coherence") { x, y in
                Canvas { ctx, size in
                    guard let r = result, !r.frequencies.isEmpty else { return }
                    let scale = LogFrequencyScale()
                    var p = Path()
                    p.move(to: CGPoint(x: 0, y: size.height))
                    for c in columns(frequencies: r.frequencies, width: size.width, scale: scale) {
                        let v = c.indices.map { r.coherence[$0] }.reduce(0, +) / Double(c.indices.count)
                        p.addLine(to: CGPoint(x: c.x, y: y(v, size.height)))
                    }
                    let edge = p
                    p.addLine(to: CGPoint(x: size.width, y: size.height))
                    p.closeSubpath()
                    ctx.fill(p, with: Theme.frequencyShading(width: size.width, opacity: 0.22))
                    ctx.stroke(edge, with: Theme.frequencyShading(width: size.width, opacity: 0.9), lineWidth: 1)
                }
            }
            .frame(height: 64)
        }
    }

    /// One point per pixel column, averaged over the bins in it. Columns with
    /// low coherence are drawn faint, since their values are unreliable.
    private func drawTrace(_ ctx: GraphicsContext, size: CGSize, r: TransferFunctionResult, values: [Double],
                           x: (Double, Double) -> Double, y: (Double, Double) -> Double, shading: GraphicsContext.Shading, circular: Bool) {
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
        var faint = ctx
        faint.opacity = 0.25
        faint.stroke(weak, with: shading, lineWidth: 1)
        ctx.stroke(strong, with: shading, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
    }

    /// A soft fill from the trace down to the bottom of the plot.
    private func fillUnder(_ ctx: GraphicsContext, size: CGSize, r: TransferFunctionResult, values: [Double],
                           y: (Double, Double) -> Double) {
        var p = Path(), started = false
        for c in columns(frequencies: r.frequencies, width: size.width, scale: LogFrequencyScale()) {
            let v = c.indices.map { values[$0] }.reduce(0, +) / Double(c.indices.count)
            let pt = CGPoint(x: c.x, y: y(v, size.height))
            if started { p.addLine(to: pt) } else { p.move(to: CGPoint(x: pt.x, y: size.height)); p.addLine(to: pt); started = true }
        }
        guard started, let last = p.currentPoint else { return }
        p.addLine(to: CGPoint(x: last.x, y: size.height))
        p.closeSubpath()
        ctx.fill(p, with: Theme.frequencyShading(width: size.width, opacity: 0.16))
    }
}

/// A small capitals label followed by a monospaced value.
struct LabeledReadout: View {
    let label: String, value: String
    var body: some View {
        HStack(spacing: 6) {
            SectionLabel(label)
            Text(value).font(Theme.readout(11))
        }
        .lineLimit(1)
        .fixedSize()
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
                    FrequencyPlot(yTicks: Self.dbTicks, yRange: -160...0, title: "Spectrum dBFS") { x, y in
                        Canvas { ctx, size in
                            let freqs = r.spectrumDB.indices.map { Double($0) * r.binWidth }
                            var p = Path(); var started = false
                            for c in columns(frequencies: freqs, width: size.width, scale: LogFrequencyScale()) {
                                let v = c.indices.map { r.spectrumDB[$0] }.max() ?? floorDB
                                let pt = CGPoint(x: c.x, y: y(v, size.height))
                                if started { p.addLine(to: pt) } else { p.move(to: pt); started = true }
                            }
                            ctx.stroke(p, with: Theme.frequencyShading(width: size.width), lineWidth: 1)
                            // Mark the fundamental and harmonics.
                            for h in 1...(r.harmonicsDBc.count + 1) {
                                let f = r.fundamentalHz * Double(h)
                                let hx = x(f, size.width)
                                ctx.stroke(Path { $0.move(to: CGPoint(x: hx, y: 0)); $0.addLine(to: CGPoint(x: hx, y: size.height)) },
                                           with: .color((h == 1 ? Theme.signal : Theme.signal2).opacity(0.45)),
                                           style: StrokeStyle(lineWidth: 1, dash: h == 1 ? [] : [3, 3]))
                            }
                        }
                    }
                    HarmonicBars(harmonicsDBc: r.harmonicsDBc)
                        .frame(width: 220)
                }
                .frame(minHeight: 220)
            } else {
                Text("Feed a single tone into input 1 to measure distortion.")
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

struct Readout: View {
    let title: String, value: String, detail: String
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            SectionLabel(title)
            Text(value).font(Theme.readout(19, weight: .medium)).lineLimit(1).minimumScaleFactor(0.7)
            Text(detail).font(Theme.readout(10)).foregroundStyle(Theme.textSecondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
        .accessibilityElement(children: .combine)
    }
}

/// Harmonic levels in dBc, H2 upwards, 0 to -160 dBc.
struct HarmonicBars: View {
    let harmonicsDBc: [Double]
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionLabel("Harmonics dBc")
            Canvas { ctx, size in
                ctx.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 6), with: .color(Theme.panel))
                guard !harmonicsDBc.isEmpty else { return }
                let labelBand = 14.0
                let plotH = size.height - labelBand
                let slot = size.width / Double(harmonicsDBc.count)
                for (i, db) in harmonicsDBc.enumerated() {
                    let cx = Double(i) * slot + slot / 2
                    let h = plotH * max(0, min(1, (db + 160) / 160))
                    ctx.fill(Path(roundedRect: CGRect(x: cx - slot * 0.3, y: plotH - h, width: slot * 0.6, height: h), cornerRadius: 2),
                             with: Theme.frequencyShading(width: size.width))
                    ctx.draw(Text(String(format: "%.0f", db)).font(Theme.axis).foregroundStyle(Theme.text),
                             at: CGPoint(x: cx, y: max(6, plotH - h - 7)))
                    ctx.draw(Text("H\(i + 2)").font(Theme.label).foregroundStyle(Theme.textSecondary),
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
            Text(title).font(Theme.small.weight(.medium))
        }
        .buttonStyle(RaisedButtonStyle())
    }
}

/// The app's one button look: a raised navy key with a hairline edge,
/// brighter on hover, darker while pressed.
struct RaisedButtonStyle: ButtonStyle {
    var selected = false
    func makeBody(configuration: Configuration) -> some View {
        RaisedButtonBody(configuration: configuration, selected: selected)
    }
}

private struct RaisedButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let selected: Bool
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        configuration.label
            .foregroundStyle(selected ? Theme.text : Theme.text.opacity(0.85))
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: Theme.controlRadius)
                .fill(selected ? Theme.signal.opacity(configuration.isPressed ? 0.1 : 0.18)
                      : (configuration.isPressed ? Theme.panel : (hovering ? Theme.raisedEdge : Theme.raised))))
            .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius)
                .strokeBorder(selected ? Theme.signal.opacity(0.75) : Theme.raisedEdge, lineWidth: 1))
            .opacity(enabled ? 1 : 0.4)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}
