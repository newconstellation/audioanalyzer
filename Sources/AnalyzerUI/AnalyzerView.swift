import AnalysisCore
import SwiftUI

/// The main analyzer window content.
public struct AnalyzerView: View {
    public var snapshot: AnalyzerSnapshot
    public var error: String?
    public var onResetPeaks: () -> Void

    public init(snapshot: AnalyzerSnapshot, error: String? = nil, onResetPeaks: @escaping () -> Void = {}) {
        self.snapshot = snapshot
        self.error = error
        self.onResetPeaks = onResetPeaks
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let error {
                Text(error).foregroundStyle(.red)
            }
            HStack(alignment: .top, spacing: 16) {
                LevelMetersView(levels: snapshot.levels)
                    .frame(width: 140)
                VStack(spacing: 12) {
                    SpectrumView(averageDB: snapshot.spectrumDB,
                                 peakDB: snapshot.spectrumPeakDB,
                                 binWidth: snapshot.binWidth,
                                 sampleRate: snapshot.sampleRate)
                    CorrelationBar(value: snapshot.correlation)
                        .frame(height: 22)
                }
            }
            HStack {
                Text(snapshot.sampleRate > 0 ? "\(Int(snapshot.sampleRate)) Hz" : "No input")
                    .foregroundStyle(.secondary)
                Spacer()
                // Drawn in SwiftUI (not a native AppKit button) so offscreen
                // snapshots render it too.
                Button(action: onResetPeaks) {
                    Text("Reset peaks")
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.15)))
                }
                .buttonStyle(.plain)
                .keyboardShortcut("r")
            }
        }
        .padding(16)
        .foregroundStyle(.white)
        .background(Color.black)
        .environment(\.colorScheme, .dark)
    }
}
