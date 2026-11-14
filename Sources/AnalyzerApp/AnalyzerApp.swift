import AppKit
import AVFoundation
import AnalysisCore
import AnalyzerUI
import Observation
import SwiftUI

@main
struct AnalyzerMainApp: App {
    @State private var model = AnalyzerModel()

    init() {
        // Lets the app take focus and show a window when launched with `swift run`.
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        WindowGroup("Analyzer") {
            AnalyzerView(snapshot: model.snapshot, error: model.error, onResetPeaks: model.resetPeaks)
                .frame(minWidth: 760, minHeight: 420)
                .task { await model.start() }
        }
    }
}

@Observable
final class AnalyzerModel {
    var snapshot = AnalyzerSnapshot()
    var error: String?
    private let input = AudioInput()

    @MainActor
    func start() async {
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        guard granted else {
            error = "Microphone access was denied. Allow it in System Settings > Privacy & Security > Microphone."
            return
        }
        input.onSnapshot = { [weak self] in self?.snapshot = $0 }
        do { try input.start() } catch { self.error = error.localizedDescription }
    }

    func resetPeaks() { input.resetPeaks() }
}
