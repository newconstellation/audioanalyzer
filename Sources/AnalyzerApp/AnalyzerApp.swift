import AppKit
import AVFoundation
import AnalysisCore
import AnalyzerUI
import Observation
import SwiftUI
import UniformTypeIdentifiers

@main
struct AnalyzerMainApp: App {
    @State private var model = AnalyzerModel()

    init() {
        // Lets the app take focus and show a window when launched with `swift run`.
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        WindowGroup("Analyzer") {
            AnalyzerView(snapshot: model.snapshot, error: model.error,
                         generator: $model.generator, loopback: $model.loopback,
                         octaveFraction: $model.octaveFraction, decaySettings: $model.decaySettings,
                         sourceName: model.sourceName,
                         splControls: SPLControls(channel: $model.splChannel, leqPeriodSeconds: $model.leqPeriodSeconds,
                                                  calibratorLevel: $model.calibratorLevel, offsets: $model.calibrationOffsets,
                                                  reset: { model.resetSoundLevels() },
                                                  startCalibration: { model.startCalibration() },
                                                  applyCalibration: { model.applyCalibration() },
                                                  cancelCalibration: { model.cancelCalibration() }),
                         fileActions: FileActions(open: { model.openFile() }, liveInput: { model.liveInput() },
                                                  saveCapture: { model.saveCapture() }),
                         onResetPeaks: model.resetPeaks, onFindDelay: model.findDelay)
                .frame(minWidth: 900, minHeight: 560)
                .task { await model.start() }
        }
    }
}

@Observable
final class AnalyzerModel {
    var snapshot = AnalyzerSnapshot()
    var error: String?
    var generator: GeneratorSettings = {
        var s = GeneratorSettings()
        // Nine tone slots; only the first starts enabled.
        s.tones = [ToneSettings()] + (1..<GeneratorSettings.maxTones).map { _ in ToneSettings(enabled: false) }
        return s
    }() {
        didSet { input.setGenerator(generator) }
    }
    var loopback = false {
        didSet { input.setLoopback(loopback) }
    }
    var octaveFraction = OctaveFraction.third {
        didSet { input.setOctaveFraction(octaveFraction) }
    }
    var decaySettings = DecaySettings() {
        didSet { input.setDecaySettings(decaySettings) }
    }
    var sourceName = "Input"
    var splChannel = 0 {
        didSet { input.setSPL(channel: splChannel, leqPeriodSeconds: leqPeriodSeconds) }
    }
    var leqPeriodSeconds = 60.0 {
        didSet { input.setSPL(channel: splChannel, leqPeriodSeconds: leqPeriodSeconds) }
    }
    var calibratorLevel = 94.0
    /// Per input channel, dB to add to get dB SPL. Saved between launches.
    var calibrationOffsets: [Double?] = AnalyzerModel.loadOffsets() {
        didSet {
            input.setCalibrationOffsets(calibrationOffsets)
            AnalyzerModel.saveOffsets(calibrationOffsets)
        }
    }

    private static let offsetsKey = "calibrationOffsets"
    private static func loadOffsets() -> [Double?] {
        guard let data = UserDefaults.standard.data(forKey: offsetsKey),
              let offsets = try? JSONDecoder().decode([Double?].self, from: data) else { return [] }
        return offsets
    }
    private static func saveOffsets(_ offsets: [Double?]) {
        if let data = try? JSONEncoder().encode(offsets) { UserDefaults.standard.set(data, forKey: offsetsKey) }
    }

    func startCalibration() { input.startCalibration(channel: splChannel, referenceSPL: calibratorLevel) }
    func applyCalibration() {
        if let offsets = input.applyCalibration() { calibrationOffsets = offsets }
    }
    func cancelCalibration() { input.cancelCalibration() }
    func resetSoundLevels() { input.resetSoundLevels() }
    private let input = AudioInput()

    @MainActor
    func start() async {
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        guard granted else {
            error = "Microphone access was denied. Allow it in System Settings > Privacy & Security > Microphone."
            return
        }
        input.onSnapshot = { [weak self] in self?.snapshot = $0 }
        input.setGenerator(generator)
        input.setCalibrationOffsets(calibrationOffsets)
        do { try input.start() } catch { self.error = error.localizedDescription }
    }

    @MainActor
    func openFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            sourceName = try input.loadFile(url)
            error = nil
        } catch {
            self.error = "Couldn't open \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    func liveInput() {
        input.liveInput()
        sourceName = "Input"
    }

    @MainActor
    func saveCapture() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.wav]
        panel.nameFieldStringValue = "Capture.wav"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try input.saveCapture(to: url) } catch { self.error = error.localizedDescription }
    }

    func resetPeaks() { input.resetPeaks() }
    func findDelay() { input.findDelay() }
}
