import AnalysisCore
import SwiftUI

/// Settings and actions for the SPL page, owned by the app.
public struct SPLControls {
    public var channel: Binding<Int>
    public var leqPeriodSeconds: Binding<Double>
    /// The calibrator's level, dB SPL.
    public var calibratorLevel: Binding<Double>
    /// Per channel calibration offsets, editable by hand.
    public var offsets: Binding<[Double?]>
    public var reset: () -> Void
    public var startCalibration: () -> Void
    public var applyCalibration: () -> Void
    public var cancelCalibration: () -> Void

    public init(channel: Binding<Int>, leqPeriodSeconds: Binding<Double>, calibratorLevel: Binding<Double>,
                offsets: Binding<[Double?]>, reset: @escaping () -> Void, startCalibration: @escaping () -> Void,
                applyCalibration: @escaping () -> Void, cancelCalibration: @escaping () -> Void) {
        self.channel = channel
        self.leqPeriodSeconds = leqPeriodSeconds
        self.calibratorLevel = calibratorLevel
        self.offsets = offsets
        self.reset = reset
        self.startCalibration = startCalibration
        self.applyCalibration = applyCalibration
        self.cancelCalibration = cancelCalibration
    }

    /// Inert controls showing the given values (for previews and renders).
    public static func constant(channel: Int = 0, leqPeriodSeconds: Double = 60, calibratorLevel: Double = 94,
                                offsets: [Double?] = []) -> SPLControls {
        SPLControls(channel: .constant(channel), leqPeriodSeconds: .constant(leqPeriodSeconds),
                    calibratorLevel: .constant(calibratorLevel), offsets: .constant(offsets),
                    reset: {}, startCalibration: {}, applyCalibration: {}, cancelCalibration: {})
    }
}

/// Sound level meter page: A/C weighted Fast, Slow, Leq, peak and maximum
/// for one input, a level history, and per-input calibration.
public struct SPLView: View {
    public var snapshot: AnalyzerSnapshot
    public var controls: SPLControls

    public init(snapshot: AnalyzerSnapshot, controls: SPLControls) {
        self.snapshot = snapshot
        self.controls = controls
    }

    private var channel: Int { min(max(controls.channel.wrappedValue, 0), max(snapshot.soundLevels.count - 1, 0)) }
    private var offset: Double? { channel < snapshot.calibrationOffsets.count ? snapshot.calibrationOffsets[channel] : nil }
    private var unit: String { offset == nil ? "dB re FS" : "dB SPL" }

    private func level(_ db: Double) -> String {
        db <= floorDB + 1 ? "–" : String(format: "%.1f", db + (offset ?? 0))
    }

    private static let periods: [(Double, String)] = [(1, "1 s"), (60, "1 min"), (600, "10 min"), (900, "15 min")]

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("Input").foregroundStyle(Theme.textSecondary)
                ForEach(0..<max(snapshot.soundLevels.count, 1), id: \.self) { c in
                    Chip(title: "\(c + 1)", selected: c == channel) { controls.channel.wrappedValue = c }
                }
                Text("Leq period").foregroundStyle(Theme.textSecondary).padding(.leading, 12)
                ForEach(Self.periods.indices, id: \.self) { i in
                    let p = Self.periods[i]
                    Chip(title: p.1, selected: controls.leqPeriodSeconds.wrappedValue == p.0) {
                        controls.leqPeriodSeconds.wrappedValue = p.0
                    }
                }
                Spacer()
                if offset == nil {
                    Text("Uncalibrated").font(Theme.label).foregroundStyle(Theme.warning)
                }
                PlainButton(title: "Reset Leq & max", action: controls.reset)
            }
            .font(Theme.small)

            if channel < snapshot.soundLevels.count {
                readouts(snapshot.soundLevels[channel])
            }

            Text("History, last 10 minutes (\(unit)): LAS cyan, LCS violet, LAeq \(periodLabel) white")
                .font(Theme.small).foregroundStyle(Theme.textSecondary)
            SPLHistoryPlot(points: snapshot.splHistory, offset: offset ?? 0, calibrated: offset != nil,
                           step: snapshot.splHistoryStep)
                .frame(minHeight: 160, maxHeight: .infinity)

            calibrationPanel
        }
    }

    private var periodLabel: String {
        Self.periods.first { $0.0 == snapshot.leqPeriodSeconds }?.1 ?? String(format: "%.0f s", snapshot.leqPeriodSeconds)
    }

    private func readouts(_ r: ChannelSoundLevel) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                SectionLabel("LAeq \(periodLabel)")
                Text(level(r.a.periodLeq)).font(Theme.readout(40, weight: .medium)).foregroundStyle(Theme.signal)
                    .lineLimit(1).minimumScaleFactor(0.6)
                Text(unit).font(Theme.small).foregroundStyle(Theme.textSecondary)
            }
            .frame(width: 160, alignment: .leading)
            .panel()
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    Readout(title: "LAS (slow)", value: level(r.a.slow), detail: unit)
                    Readout(title: "LAF (fast)", value: level(r.a.fast), detail: unit)
                    Readout(title: "LAFmax", value: level(r.a.maxFast), detail: unit)
                    Readout(title: "LAeq total", value: level(r.a.leq), detail: String(format: "%.0f s", r.a.duration))
                }
                GridRow {
                    Readout(title: "LCS (slow)", value: level(r.c.slow), detail: unit)
                    Readout(title: "LCeq \(periodLabel)", value: level(r.c.periodLeq), detail: unit)
                    Readout(title: "LCpeak", value: level(r.c.peak), detail: "\(unit), peak")
                    Readout(title: "C − A (Leq)", value: r.a.periodLeq <= floorDB + 1 ? "–" : String(format: "%.1f", r.c.periodLeq - r.a.periodLeq),
                            detail: r.c.periodLeq - r.a.periodLeq > 20 ? "dB, low-frequency heavy" : "dB")
                }
            }
        }
    }

    @ViewBuilder
    private var calibrationPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Calibration, input \(channel + 1)").font(.system(size: 13, weight: .semibold))
                Text(offset.map { String(format: "offset %+.1f dB", $0) } ?? "no offset").monospacedDigit()
                    .foregroundStyle(offset == nil ? Theme.warning : Theme.textSecondary)
                ForEach([-1.0, -0.1, 0.1, 1], id: \.self) { d in
                    Chip(title: String(format: "%+g", d), selected: false) { nudgeOffset(d) }
                }
                if offset != nil {
                    Chip(title: "Clear", selected: false) { setOffset(nil) }
                }
                Spacer()
            }
            HStack(spacing: 6) {
                Text("Calibrator").foregroundStyle(Theme.textSecondary)
                ForEach([94.0, 110, 114], id: \.self) { l in
                    Chip(title: "\(Int(l)) dB", selected: controls.calibratorLevel.wrappedValue == l) {
                        controls.calibratorLevel.wrappedValue = l
                    }
                }
                if let cal = snapshot.calibration {
                    calibrationProgress(cal)
                } else {
                    PlainButton(title: "Calibrate", action: controls.startCalibration)
                    Text("Fit the calibrator to the mic on input \(channel + 1), switch it on, then press Calibrate.")
                        .font(Theme.small).foregroundStyle(Theme.textSecondary)
                }
                Spacer()
            }
        }
        .font(Theme.small)
        .panel()
    }

    @ViewBuilder
    private func calibrationProgress(_ cal: CalibrationStatus) -> some View {
        if cal.progress < 1 {
            ProgressBar(value: cal.progress).frame(width: 160, height: 8)
            Text("Measuring input \(cal.channel + 1)…").foregroundStyle(Theme.textSecondary)
            PlainButton(title: "Cancel", action: controls.cancelCalibration)
        } else if let o = cal.offset {
            Text(String(format: "Measured %.1f dB re FS; offset %+.1f dB makes it read %.1f dB SPL.",
                        cal.measuredDB ?? 0, o, cal.referenceSPL))
            PlainButton(title: "Apply", action: controls.applyCalibration)
            PlainButton(title: "Cancel", action: controls.cancelCalibration)
        } else {
            Text("Too quiet to be a calibrator. Is it on, and is the input gain up?").foregroundStyle(Theme.warning)
            PlainButton(title: "Cancel", action: controls.cancelCalibration)
        }
    }

    private func setOffset(_ v: Double?) {
        var o = controls.offsets.wrappedValue
        while o.count <= channel { o.append(nil) }
        o[channel] = v
        controls.offsets.wrappedValue = o
    }

    private func nudgeOffset(_ d: Double) {
        setOffset(((offset ?? 120) + d * 10).rounded() / 10)
    }
}

/// A small toggle-style button drawn in SwiftUI.
struct Chip: View {
    let title: String
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(Theme.small.weight(selected ? .semibold : .regular))
        }
        .buttonStyle(RaisedButtonStyle(selected: selected))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct ProgressBar: View {
    let value: Double
    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: size.height / 2),
                     with: .color(Theme.well))
            ctx.fill(Path(roundedRect: CGRect(x: 0, y: 0, width: size.width * min(max(value, 0), 1), height: size.height),
                          cornerRadius: size.height / 2),
                     with: .linearGradient(Theme.rampGradient, startPoint: .zero, endPoint: CGPoint(x: size.width, y: 0)))
        }
    }
}

/// LAS, LCS and period LAeq over time, newest at the right.
struct SPLHistoryPlot: View {
    let points: [SPLPoint]
    let offset: Double
    let calibrated: Bool
    let step: Double
    var capacity = 1200

    var body: some View {
        let range: ClosedRange<Double> = calibrated ? 30...130 : -100...0
        HistoryStrip(title: "", series: [
            .init(values: points.map { $0.lcSlow + offset }, color: Theme.signal2),
            .init(values: points.map { $0.laSlow + offset }, color: Theme.signal),
            .init(values: points.map { $0.laeq + offset }, color: Theme.text),
        ], range: range, ticks: stride(from: range.upperBound, through: range.lowerBound, by: -20).map { (value: $0, label: "\(Int($0))") },
           capacity: capacity,
           readout: points.isEmpty ? "" : String(format: "%.0f s", Double(points.count) * step))
    }
}
