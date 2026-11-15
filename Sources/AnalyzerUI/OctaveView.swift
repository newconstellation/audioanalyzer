import AnalysisCore
import SwiftUI

/// Real-time analyzer: fractional-octave band levels as bars, with the
/// peak hold as a line above each bar.
public struct OctaveView: View {
    public var bands: [OctaveBand]
    public var levelsDB: [Double]
    public var peaksDB: [Double]
    @Binding public var fraction: OctaveFraction

    public init(bands: [OctaveBand], levelsDB: [Double], peaksDB: [Double], fraction: Binding<OctaveFraction>) {
        self.bands = bands
        self.levelsDB = levelsDB
        self.peaksDB = peaksDB
        _fraction = fraction
    }

    private static let range = -100.0...0
    private static let ticks: [(value: Double, label: String)] = stride(from: 0.0, through: -100, by: -10).map { ($0, "\(Int($0))") }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                SectionLabel("Bands").padding(.trailing, 4)
                ForEach(OctaveFraction.allCases, id: \.self) { f in
                    Chip(title: f.label, selected: fraction == f) { fraction = f }
                }
                Spacer()
                SectionLabel("dBFS (sine = its level)")
            }
            FrequencyPlot(yTicks: Self.ticks, yRange: Self.range, title: fraction.label + " bands") { x, y in
                Canvas { ctx, size in
                    let n = min(bands.count, levelsDB.count)
                    guard n > 0 else { return }
                    var bars = Path(), holds = Path()
                    for i in 0..<n {
                        let b = bands[i]
                        let x0 = x(b.lower, size.width), x1 = x(b.upper, size.width)
                        let gap = max(0.5, (x1 - x0) * 0.12)
                        let top = y(levelsDB[i], size.height)
                        bars.addRect(CGRect(x: x0 + gap, y: top, width: max(0.5, x1 - x0 - 2 * gap), height: size.height - top))
                        if i < peaksDB.count {
                            let py = y(peaksDB[i], size.height)
                            holds.addRect(CGRect(x: x0 + gap, y: py - 1, width: max(0.5, x1 - x0 - 2 * gap), height: 2))
                        }
                    }
                    // Lit along the icon ramp by level: cyan low, violet high.
                    ctx.fill(bars, with: .linearGradient(Gradient(colors: [Theme.rampHigh, Theme.rampMid, Theme.rampLow.opacity(0.75)]),
                                                         startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
                    ctx.fill(holds, with: .color(Theme.text.opacity(0.9)))
                    // Band values under the bars when there's room.
                    if n <= 31 {
                        for i in 0..<n {
                            let b = bands[i]
                            let cx = (x(b.lower, size.width) + x(b.upper, size.width)) / 2
                            let top = y(levelsDB[i], size.height)
                            ctx.draw(Text(String(format: "%.0f", levelsDB[i])).font(Theme.axis),
                                     at: CGPoint(x: cx, y: max(6, top - 7)))
                        }
                    }
                }
            }
            if bands.count <= 31, !bands.isEmpty {
                // Nominal band labels, every band for octaves, every third band otherwise.
                GeometryReader { geo in
                    let w = geo.size.width - 40
                    let every = bands.count > 12 ? 3 : 1
                    ForEach(Array(bands.enumerated()).filter { $0.offset % every == 0 }, id: \.offset) { _, b in
                        Text(frequencyLabel(b.nominal))
                            .font(Theme.axis)
                            .foregroundStyle(Theme.textSecondary)
                            .position(x: 40 + LogFrequencyScale().x(b.center, width: w), y: 6)
                    }
                }
                .frame(height: 12)
            }
        }
    }
}
