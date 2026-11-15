import AnalysisCore
import SwiftUI

/// The audio input devices to choose from, owned by the app.
public struct InputDeviceControls {
    public var names: [String]
    /// The chosen device's name, or nil for the system default.
    public var selected: Binding<String?>

    public init(names: [String], selected: Binding<String?>) {
        self.names = names
        self.selected = selected
    }
}

/// Input device and channel routing: which inputs feed the spectrum, which
/// is the transfer function's reference, which are measurement mics, and
/// how several mics are averaged.
public struct InputsView: View {
    public var snapshot: AnalyzerSnapshot
    @Binding public var routing: ChannelRouting
    public var devices: InputDeviceControls?

    public init(snapshot: AnalyzerSnapshot, routing: Binding<ChannelRouting>, devices: InputDeviceControls?) {
        self.snapshot = snapshot
        _routing = routing
        self.devices = devices
    }

    private var channelCount: Int { snapshot.levels.count }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let devices {
                HStack(spacing: 6) {
                    Text("Input device").foregroundStyle(.secondary)
                    ViewThatFits(in: .horizontal) {
                        deviceChips(devices)
                        ScrollView(.horizontal, showsIndicators: false) { deviceChips(devices) }
                    }
                }
            }

            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                GridRow {
                    Group {
                        Text("Input"); Text("Level"); Text("Spectrum"); Text("TF reference"); Text("TF mic"); Text("Calibration")
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(0..<channelCount, id: \.self) { c in
                    GridRow {
                        Text("\(c + 1)").monospacedDigit()
                        LevelStrip(db: snapshot.levels[c].peakDB).frame(width: 140, height: 8)
                        Chip(title: routing.spectrumChannels.contains(c) ? "On" : "Off",
                             selected: routing.spectrumChannels.contains(c)) { toggle(&routing.spectrumChannels, c) }
                        Chip(title: routing.reference == c ? "Reference" : "–", selected: routing.reference == c) {
                            routing.reference = c
                            routing.measurementChannels.removeAll { $0 == c }
                        }
                        Chip(title: routing.measurementChannels.contains(c) ? "Mic \((routing.measurementChannels.firstIndex(of: c) ?? 0) + 1)" : "–",
                             selected: routing.measurementChannels.contains(c)) {
                            guard c != routing.reference else { return }
                            toggle(&routing.measurementChannels, c)
                        }
                        Text(offsetText(c)).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            }
            .font(.system(size: 11))

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text("Spectrum: average of \(routing.spectrumChannels.count) input\(routing.spectrumChannels.count == 1 ? "" : "s")")
                        .frame(width: 230, alignment: .leading)
                    ForEach([SpatialAverage.power, .normalizedPower], id: \.self) { m in
                        Chip(title: m.rawValue, selected: routing.spectrumAverage == m) { routing.spectrumAverage = m }
                    }
                }
                HStack(spacing: 6) {
                    Text("Transfer function: average of \(routing.measurementChannels.count) mic\(routing.measurementChannels.count == 1 ? "" : "s")")
                        .frame(width: 230, alignment: .leading)
                    ForEach(SpatialAverage.allCases, id: \.self) { m in
                        Chip(title: m.rawValue, selected: routing.transferAverage == m) { routing.transferAverage = m }
                    }
                }
                Text("""
                Each mic has its own delay, set by Find delay on the transfer function page. Phase is always averaged \
                from the complex responses. Coherence-weighted dB lets points with low coherence (comb-filter nulls, \
                reverberant or noisy points) count for less. Normalised power lines mics up in level over a mid band \
                first (125 Hz–4 kHz for the spectrum, 225 Hz–8.8 kHz for transfer functions).
                """)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .font(.system(size: 11))
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.05)))
            Spacer()
        }
    }

    private func deviceChips(_ devices: InputDeviceControls) -> some View {
        HStack(spacing: 6) {
            Chip(title: "System default", selected: devices.selected.wrappedValue == nil) { devices.selected.wrappedValue = nil }
            ForEach(devices.names, id: \.self) { name in
                Chip(title: name, selected: devices.selected.wrappedValue == name) { devices.selected.wrappedValue = name }
            }
            Spacer(minLength: 0)
        }
    }

    private func toggle(_ list: inout [Int], _ c: Int) {
        if let i = list.firstIndex(of: c) { list.remove(at: i) } else { list.append(c); list.sort() }
    }

    private func offsetText(_ c: Int) -> String {
        guard c < snapshot.calibrationOffsets.count, let o = snapshot.calibrationOffsets[c] else { return "none" }
        return String(format: "%+.1f dB", o)
    }
}

/// A thin horizontal peak level bar, -60 to 0 dBFS.
private struct LevelStrip: View {
    let db: Double
    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white.opacity(0.1)))
            let f = min(max((db + 60) / 60, 0), 1)
            ctx.fill(Path(CGRect(x: 0, y: 0, width: size.width * f, height: size.height)),
                     with: .color(db > -3 ? .red : db > -12 ? .yellow : .green))
        }
    }
}
