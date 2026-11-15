import SwiftUI

/// The app's visual language ("Signal Path"): ink-navy neutrals, and the app
/// icon's cyan → blue → violet ramp as the one colour language for level and
/// data. Every view takes its colours, type and shapes from here.
///
/// Colour meanings, kept the same on every page:
/// - `signal` (cyan): the primary measurement trace.
/// - `signal2` (violet): the second trace (phase, RMS, peak hold).
/// - `ramp`: level and magnitude, low (cyan) to high (violet).
/// - `warning` (amber): uncalibrated, near clipping.
/// - `danger` (red): clipping and overs only.
public enum Theme {
    // MARK: Neutrals (navy-tinted)
    static let background = Color(hex: 0x0A0D16)
    static let panel = Color(hex: 0x0F1320)
    static let raised = Color(hex: 0x161C2E)
    static let hairline = Color(hex: 0x1F2638)
    static let raisedEdge = Color(hex: 0x2A3352)
    static let grid = Color(hex: 0x26304C)
    static let well = Color(hex: 0x1A2033)

    static let text = Color(hex: 0xE6EAF5)
    static let textSecondary = Color(hex: 0x8A93AD)
    static let textTertiary = Color(hex: 0x5F6883)

    // MARK: Data and state
    static let signal = Color(hex: 0x3FD8FF)
    static let signal2 = Color(hex: 0x9B7BFF)
    static let rampLow = Color(hex: 0x3FE0FF)
    static let rampMid = Color(hex: 0x4A7DFF)
    static let rampHigh = Color(hex: 0xA66BFF)
    static let warning = Color(hex: 0xFFB547)
    static let danger = Color(hex: 0xFF4D6A)
    static let good = Color(hex: 0x3DFF9A)
    static let rms = Color(hex: 0xC9D3F2)

    /// Extra trace colours for several channels or series, in order.
    static let series: [Color] = [signal, signal2, warning, good, Color(hex: 0xFF7AC6), Color(hex: 0x7AA2FF)]

    /// The icon ramp as a gradient (low → high).
    static let rampGradient = Gradient(colors: [rampLow, rampMid, rampHigh])

    /// The icon ramp at `t` (0...1).
    static func ramp(_ t: Double) -> Color {
        let t = min(max(t, 0), 1)
        let (a, b, k) = t < 0.5 ? (rampLowRGB, rampMidRGB, t * 2) : (rampMidRGB, rampHighRGB, (t - 0.5) * 2)
        return Color(red: a.0 + (b.0 - a.0) * k, green: a.1 + (b.1 - a.1) * k, blue: a.2 + (b.2 - a.2) * k)
    }
    private static let rampLowRGB = (0x3F / 255.0, 0xE0 / 255.0, 0xFF / 255.0)
    private static let rampMidRGB = (0x4A / 255.0, 0x7D / 255.0, 0xFF / 255.0)
    private static let rampHighRGB = (0xA6 / 255.0, 0x6B / 255.0, 0xFF / 255.0)

    /// Meter colour for a level in dBFS: the ramp, red above -3 dBFS.
    static func level(_ db: Double, floor: Double = -60) -> Color {
        db > -3 ? danger : ramp((db - floor) / -floor)
    }

    // MARK: Type (three sizes, one family; mono digits for readouts)
    static let body = Font.system(size: 12)
    static let small = Font.system(size: 11)
    static let label = Font.system(size: 9, weight: .semibold)
    static let axis = Font.system(size: 9, design: .monospaced)
    static func readout(_ size: CGFloat = 12, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    // MARK: Shape
    static let radius: CGFloat = 8
    static let controlRadius: CGFloat = 5
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: opacity)
    }
}

/// A small tracked-capitals title, used for plot and panel titles.
struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased())
            .font(Theme.label)
            .tracking(1.1)
            .foregroundStyle(Theme.textSecondary)
    }
}

extension View {
    /// A content panel: navy fill with a hairline edge.
    func panel(padding: CGFloat = 10) -> some View {
        self.padding(padding)
            .background(RoundedRectangle(cornerRadius: Theme.radius).fill(Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.hairline, lineWidth: 1))
    }
}
