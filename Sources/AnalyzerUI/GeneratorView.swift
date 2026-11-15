import AnalysisCore
import SwiftUI

/// Controls for the signal generator.
public struct GeneratorView: View {
    @Binding var settings: GeneratorSettings
    @Binding var loopback: Bool

    public init(settings: Binding<GeneratorSettings>, loopback: Binding<Bool>) {
        _settings = settings
        _loopback = loopback
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 24) {
                    Toggle("Generator on", isOn: $settings.enabled)
                        .toggleStyle(.switch)
                    Toggle("Internal loopback (analyse the generator, no hardware)", isOn: $loopback)
                }

                section("Tones") {
                    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                        GridRow {
                            Group {
                                Text("On"); Text("Frequency (Hz)"); Text("Level (dBFS)"); Text("")
                                Text("Sweep to (Hz)"); Text("Seconds"); Text("Log")
                            }
                            .font(Theme.small).foregroundStyle(Theme.textSecondary)
                        }
                        ForEach(settings.tones.indices, id: \.self) { i in
                            toneRow($settings.tones[i])
                        }
                    }
                }

                section("Noise") {
                    LevelToggle(title: "White noise (RMS)", value: $settings.whiteNoiseDBFS, defaultValue: -30)
                    LevelToggle(title: "Pink noise (RMS)", value: $settings.pinkNoiseDBFS, defaultValue: -30)
                }

                section("Output") {
                    HStack(spacing: 16) {
                        Toggle("Burst", isOn: Binding(
                            get: { settings.burst != nil },
                            set: { settings.burst = $0 ? Burst(onSeconds: 0.1, offSeconds: 0.4) : nil }))
                        if settings.burst != nil {
                            NumberField(title: "On (ms)", value: Binding(
                                get: { (settings.burst?.onSeconds ?? 0) * 1000 },
                                set: { settings.burst?.onSeconds = max(1, $0) / 1000 }))
                            NumberField(title: "Off (ms)", value: Binding(
                                get: { (settings.burst?.offSeconds ?? 0) * 1000 },
                                set: { settings.burst?.offSeconds = max(0, $0) / 1000 }))
                        }
                    }
                    HStack(spacing: 16) {
                        Picker("Dither / quantise", selection: $settings.ditherBits) {
                            Text("Off (32-bit float)").tag(Int?.none)
                            ForEach([16, 20, 24], id: \.self) { Text("\($0)-bit TPDF").tag(Int?.some($0)) }
                        }
                        .frame(width: 280)
                        Picker("FFT sync", selection: $settings.fftSyncSize) {
                            Text("Off").tag(Int?.none)
                            ForEach([4096, 8192, 16384, 32768, 65536], id: \.self) { Text("\($0)").tag(Int?.some($0)) }
                        }
                        .frame(width: 200)
                    }
                }
            }
            .padding(.trailing, 8)
        }
    }

    /// One row of the tones grid. Returned as a bare GridRow (no modifiers)
    /// so Grid lays its cells out in columns.
    @ViewBuilder
    private func toneRow(_ tone: Binding<ToneSettings>) -> some View {
        GridRow {
            Toggle("", isOn: tone.enabled).labelsHidden()
            TextField("Hz", value: tone.frequency, format: .number.precision(.fractionLength(0...3)))
                .frame(width: 100)
            Slider(value: tone.levelDBFS, in: -120...0)
                .frame(width: 160)
            Text(String(format: "%.1f", tone.wrappedValue.levelDBFS)).monospacedDigit().frame(width: 44, alignment: .trailing)
            HStack {
                Toggle("", isOn: Binding(
                    get: { tone.wrappedValue.sweep != nil },
                    set: { tone.wrappedValue.sweep = $0 ? Sweep(endFrequency: 20000, seconds: 10) : nil })).labelsHidden()
                TextField("Hz", value: Binding(
                    get: { tone.wrappedValue.sweep?.endFrequency ?? 20000 },
                    set: { tone.wrappedValue.sweep?.endFrequency = $0 }), format: .number)
                    .frame(width: 80)
                    .disabled(tone.wrappedValue.sweep == nil)
            }
            TextField("s", value: Binding(
                get: { tone.wrappedValue.sweep?.seconds ?? 10 },
                set: { tone.wrappedValue.sweep?.seconds = max(0.01, $0) }), format: .number)
                .frame(width: 60)
                .disabled(tone.wrappedValue.sweep == nil)
            Toggle("", isOn: Binding(
                get: { tone.wrappedValue.sweep?.logarithmic ?? true },
                set: { tone.wrappedValue.sweep?.logarithmic = $0 })).labelsHidden()
                .disabled(tone.wrappedValue.sweep == nil)
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 13, weight: .semibold))
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(padding: 12)
    }
}

/// An optional level: a checkbox to turn it on, and a slider for its value.
private struct LevelToggle: View {
    let title: String
    @Binding var value: Double?
    let defaultValue: Double

    var body: some View {
        HStack(spacing: 10) {
            Toggle(title, isOn: Binding(get: { value != nil }, set: { value = $0 ? defaultValue : nil }))
                .frame(width: 180, alignment: .leading)
            Slider(value: Binding(get: { value ?? defaultValue }, set: { value = $0 }), in: -120...0)
                .frame(width: 200)
                .disabled(value == nil)
            Text(value.map { String(format: "%.1f dBFS", $0) } ?? "off").monospacedDigit()
        }
    }
}

private struct NumberField: View {
    let title: String
    @Binding var value: Double
    var body: some View {
        HStack(spacing: 4) {
            Text(title).foregroundStyle(Theme.textSecondary)
            TextField(title, value: $value, format: .number).frame(width: 70)
        }
    }
}
