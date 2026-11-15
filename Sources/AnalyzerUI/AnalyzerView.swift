import AnalysisCore
import SwiftUI

/// The instrument pages of the main window.
public enum InstrumentPage: String, CaseIterable, Identifiable, Sendable {
    case meters = "Spectrum"
    case octave = "Octave"
    case spl = "SPL"
    case transferFunction = "Transfer Function"
    case decay = "Decay"
    case distortion = "THD"
    case scope = "Scope"
    case history = "History"
    case generator = "Generator"
    case inputs = "Inputs"
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
    var decaySettings: Binding<DecaySettings>
    /// What is being analysed, shown in the status bar ("Input", a file name...).
    public var sourceName: String
    public var fileActions: FileActions?
    var splControls: SPLControls?
    var routing: Binding<ChannelRouting>?
    var inputDevices: InputDeviceControls?
    @State private var page: InstrumentPage

    public init(snapshot: AnalyzerSnapshot, error: String? = nil, page: InstrumentPage = .meters,
                generator: Binding<GeneratorSettings> = .constant(GeneratorSettings()),
                loopback: Binding<Bool> = .constant(false),
                octaveFraction: Binding<OctaveFraction> = .constant(.third),
                decaySettings: Binding<DecaySettings> = .constant(DecaySettings()),
                sourceName: String = "Input", fileActions: FileActions? = nil, splControls: SPLControls? = nil,
                routing: Binding<ChannelRouting>? = nil, inputDevices: InputDeviceControls? = nil,
                onResetPeaks: @escaping () -> Void = {}, onFindDelay: @escaping () -> Void = {}) {
        self.snapshot = snapshot
        self.error = error
        self.generator = generator
        self.loopback = loopback
        self.octaveFraction = octaveFraction
        self.decaySettings = decaySettings
        self.sourceName = sourceName
        self.fileActions = fileActions
        self.splControls = splControls
        self.routing = routing
        self.inputDevices = inputDevices
        self.onResetPeaks = onResetPeaks
        self.onFindDelay = onFindDelay
        _page = State(initialValue: page)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Scrolls sideways only if the window is too narrow for every tab.
            ViewThatFits(in: .horizontal) {
                tabs
                ScrollView(.horizontal, showsIndicators: false) { tabs }
            }
            .fixedSize(horizontal: false, vertical: true)
            .layoutPriority(1)
            if let error {
                Text(error).foregroundStyle(.red)
            }
            HStack(alignment: .top, spacing: 16) {
                LevelMetersView(levels: snapshot.levels)
                    .frame(width: LevelMetersView.width(channels: snapshot.levels.count))
                FitOrScroll {
                    switch page {
                    case .meters:
                        VStack(spacing: 12) {
                            SpectrumView(averageDB: snapshot.spectrumDB,
                                         peakDB: snapshot.spectrumPeakDB,
                                         binWidth: snapshot.binWidth,
                                         sampleRate: snapshot.sampleRate,
                                         offsetDB: snapshot.calibrationOffsets.first ?? nil)
                            CorrelationBar(value: snapshot.correlation)
                                .frame(height: 22)
                        }
                    case .octave:
                        OctaveView(bands: snapshot.octaveBands, levelsDB: snapshot.octaveDB,
                                   peaksDB: snapshot.octavePeakDB, fraction: octaveFraction)
                    case .spl:
                        SPLView(snapshot: snapshot,
                                controls: splControls ?? .constant(channel: snapshot.splChannel,
                                                                   leqPeriodSeconds: snapshot.leqPeriodSeconds,
                                                                   offsets: snapshot.calibrationOffsets))
                    case .transferFunction:
                        TransferFunctionView(result: snapshot.transferFunction, perMic: snapshot.transferFunctionsPerMic,
                                             averaging: snapshot.routing.transferAverage, onFindDelay: onFindDelay)
                    case .decay:
                        DecayView(impulse: snapshot.impulse, decay: snapshot.decay, settings: decaySettings)
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
                    case .inputs:
                        InputsView(snapshot: snapshot, routing: routing ?? .constant(snapshot.routing), devices: inputDevices)
                    case .generator:
                        GeneratorView(settings: generator, loopback: loopback)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            // The page area can always shrink, so the tab bar and status bar
            // stay on screen however much a page holds.
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
            .clipped()
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
            .fixedSize(horizontal: false, vertical: true)
            .layoutPriority(1)
        }
        .padding(16)
        .foregroundStyle(.white)
        .background(Color.black)
        .environment(\.colorScheme, .dark)
    }
}

extension AnalyzerView {
    // Tabs drawn in SwiftUI (not native AppKit controls) so offscreen
    // snapshots render them too.
    private var tabs: some View {
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
            Spacer(minLength: 0)
        }
    }
}

/// Shows a page as it is when it fits the height it is given, and in a
/// vertical scroll view when it does not (many inputs, a short window).
struct FitOrScroll<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        ViewThatFits(in: .vertical) {
            content
            ScrollView(.vertical) {
                content.padding(.trailing, 10)
            }
        }
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
