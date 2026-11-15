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
        HStack(spacing: 0) {
            InstrumentRail(page: $page)
            Rectangle().fill(Theme.hairline).frame(width: 1)
            VStack(alignment: .leading, spacing: 12) {
                if let error {
                    Text(error).font(Theme.body).foregroundStyle(Theme.danger)
                }
                FitOrScroll { pageContent }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // The page area can always shrink, so the status bar stays on
                    // screen however much a page holds.
                    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
                    .clipped()
                statusBar
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)
            }
            .padding(14)
            Rectangle().fill(Theme.hairline).frame(width: 1)
            LevelMetersView(levels: snapshot.levels)
                .frame(width: LevelMetersView.width(channels: snapshot.levels.count))
                .padding(.vertical, 14).padding(.horizontal, 12)
                .frame(maxHeight: .infinity)
                .background(Theme.chrome)
        }
        .font(Theme.body)
        .foregroundStyle(Theme.text)
        .tint(Theme.rampMid)
        .background(Theme.background)
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private var pageContent: some View {
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

    private var statusBar: some View {
        HStack(spacing: 6) {
            Circle().fill(snapshot.sampleRate > 0 ? Theme.good : Theme.textTertiary).frame(width: 7, height: 7)
            Text(snapshot.sampleRate > 0 ? "\(sourceName == "Input" ? "Live input" : sourceName) · \(Int(snapshot.sampleRate)) Hz" : "No input")
                .font(Theme.small)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
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
}

/// Instrument navigation: a narrow rail of icons with short names, in the
/// order of the original's pages. Command-1 to Command-0 select them.
struct InstrumentRail: View {
    @Binding var page: InstrumentPage

    var body: some View {
        ViewThatFits(in: .vertical) {
            items
            ScrollView(.vertical, showsIndicators: false) { items }
        }
        .frame(width: 84)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.chrome)
    }

    private var items: some View {
        VStack(spacing: 4) {
            ForEach(Array(InstrumentPage.allCases.enumerated()), id: \.element) { index, p in
                let selected = page == p
                Button { page = p } label: {
                    VStack(spacing: 4) {
                        Image(systemName: p.symbol)
                            .font(.system(size: 16, weight: .regular))
                            .frame(height: 20)
                            .foregroundStyle(selected
                                             ? AnyShapeStyle(LinearGradient(gradient: Theme.rampGradient, startPoint: .topLeading, endPoint: .bottomTrailing))
                                             : AnyShapeStyle(Theme.textSecondary))
                        Text(p.shortTitle)
                            .font(.system(size: 10, weight: selected ? .semibold : .medium))
                            .foregroundStyle(selected ? Theme.text : Theme.textSecondary)
                            .lineLimit(1).minimumScaleFactor(0.8)
                    }
                    .frame(width: 70, height: 50)
                    .background {
                        if selected {
                            RoundedRectangle(cornerRadius: Theme.radius).fill(Theme.raised)
                                .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.raisedEdge, lineWidth: 1))
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(p.rawValue)
                .accessibilityLabel(p.rawValue)
                .accessibilityAddTraits(selected ? .isSelected : [])
                .keyboardShortcut(KeyEquivalent(Character(String((index + 1) % 10))), modifiers: .command)
            }
        }
        .padding(.vertical, 10)
    }
}

extension InstrumentPage {
    /// A short name that fits under the rail icon.
    var shortTitle: String {
        self == .transferFunction ? "Transfer" : rawValue
    }

    var symbol: String {
        switch self {
        case .meters: "chart.xyaxis.line"
        case .octave: "chart.bar.fill"
        case .spl: "gauge.with.dots.needle.67percent"
        case .transferFunction: "point.topleft.down.to.point.bottomright.curvepath"
        case .decay: "water.waves"
        case .distortion: "chart.bar.xaxis"
        case .scope: "waveform"
        case .history: "clock.arrow.circlepath"
        case .generator: "dot.radiowaves.right"
        case .inputs: "slider.vertical.3"
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
