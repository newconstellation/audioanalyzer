import AnalysisCore
import SwiftUI

/// The instrument pages of the main window.
public enum InstrumentPage: String, CaseIterable, Identifiable, Sendable {
    case meters = "Meters & Spectrum"
    case octave = "Octave"
    case transferFunction = "Transfer Function"
    case distortion = "THD"
    case scope = "Scope"
    case history = "Waterfall & History"
    case generator = "Generator"
    public var id: String { rawValue }
}

/// The main analyzer window content.
public struct AnalyzerView: View {
    public var snapshot: AnalyzerSnapshot
    public var error: String?
    public var onResetPeaks: () -> Void
    public var onFindDelay: () -> Void
    var generator: Binding<GeneratorSettings>
    var loopback: Binding<Bool>
    var octaveFraction: Binding<OctaveFraction>
    /// What is being analysed, shown in the status bar ("Input", a file name...).
    public var sourceName: String
    public var fileActions: FileActions?
    @State private var page: InstrumentPage

    public init(snapshot: AnalyzerSnapshot, error: String? = nil, page: InstrumentPage = .meters,
                generator: Binding<GeneratorSettings> = .constant(GeneratorSettings()),
                loopback: Binding<Bool> = .constant(false),
                octaveFraction: Binding<OctaveFraction> = .constant(.third),
                sourceName: String = "Input", fileActions: FileActions? = nil,
                onResetPeaks: @escaping () -> Void = {}, onFindDelay: @escaping () -> Void = {}) {
        self.snapshot = snapshot
        self.error = error
        self.generator = generator
        self.loopback = loopback
        self.octaveFraction = octaveFraction
        self.sourceName = sourceName
        self.fileActions = fileActions
        self.onResetPeaks = onResetPeaks
        self.onFindDelay = onFindDelay
        _page = State(initialValue: page)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Tabs drawn in SwiftUI (not native AppKit controls) so offscreen
            // snapshots render them too.
            HStack(spacing: 4) {
                ForEach(InstrumentPage.allCases) { p in
                    Button { page = p } label: {
                        Text(p.rawValue)
                            .padding(.horizontal, 12).padding(.vertical, 5)
                            .background(RoundedRectangle(cornerRadius: 5)
                                .fill(page == p ? Color.accentColor.opacity(0.8) : Color.white.opacity(0.08)))
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            if let error {
                Text(error).foregroundStyle(.red)
            }
            HStack(alignment: .top, spacing: 16) {
                LevelMetersView(levels: snapshot.levels)
                    .frame(width: 140)
                Group {
                    switch page {
                    case .meters:
                        VStack(spacing: 12) {
                            SpectrumView(averageDB: snapshot.spectrumDB,
                                         peakDB: snapshot.spectrumPeakDB,
                                         binWidth: snapshot.binWidth,
                                         sampleRate: snapshot.sampleRate)
                            CorrelationBar(value: snapshot.correlation)
                                .frame(height: 22)
                        }
                    case .octave:
                        OctaveView(bands: snapshot.octaveBands, levelsDB: snapshot.octaveDB,
                                   peaksDB: snapshot.octavePeakDB, fraction: octaveFraction)
                    case .transferFunction:
                        TransferFunctionView(result: snapshot.transferFunction, onFindDelay: onFindDelay)
                    case .distortion:
                        DistortionView(result: snapshot.distortion)
                    case .scope:
                        HStack(alignment: .top, spacing: 12) {
                            OscilloscopeView(trace: snapshot.scope, settings: snapshot.scopeSettings)
                            VectorscopeView(left: snapshot.vectorscope.left, right: snapshot.vectorscope.right,
                                            correlation: snapshot.correlation)
                                .frame(width: 260)
                        }
                    case .history:
                        VStack(spacing: 12) {
                            WaterfallView(rows: snapshot.waterfall, rowSeconds: snapshot.historyStep)
                            HistoriesView(snapshot: snapshot)
                                .frame(height: 230)
                        }
                    case .generator:
                        GeneratorView(settings: generator, loopback: loopback)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack {
                Text(snapshot.sampleRate > 0 ? "\(sourceName), \(Int(snapshot.sampleRate)) Hz" : "No input")
                    .foregroundStyle(.secondary)
                Spacer()
                if let fileActions {
                    PlainButton(title: "Open audio file…", action: fileActions.open)
                    if sourceName != "Input" {
                        PlainButton(title: "Back to input", action: fileActions.liveInput)
                    }
                    PlainButton(title: "Save capture…", action: fileActions.saveCapture)
                }
                PlainButton(title: "Reset peaks", action: onResetPeaks)
                    .keyboardShortcut("r")
            }
        }
        .padding(16)
        .foregroundStyle(.white)
        .background(Color.black)
        .environment(\.colorScheme, .dark)
    }
}

/// Status-bar actions for loading audio files and saving captures.
public struct FileActions {
    public var open: () -> Void
    public var liveInput: () -> Void
    public var saveCapture: () -> Void
    public init(open: @escaping () -> Void, liveInput: @escaping () -> Void, saveCapture: @escaping () -> Void) {
        self.open = open
        self.liveInput = liveInput
        self.saveCapture = saveCapture
    }
}
