import AVFoundation
import AnalysisCore

/// Captures the default input device and runs the analysis on the tap thread.
/// A snapshot of the results is published to the main thread for drawing.
final class AudioInput {
    var onSnapshot: ((AnalyzerSnapshot) -> Void)?
    var fftSize = 8192

    private let audioEngine = AVAudioEngine()
    // Taps arrive on an AVAudioEngine worker thread, not the real-time I/O
    // thread, so a lock here is safe.
    private let lock = NSLock()
    private var engine: AnalysisEngine?

    func start() throws {
        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            throw NSError(domain: "AudioInput", code: 1, userInfo: [NSLocalizedDescriptionKey: "No input device"])
        }
        engine = AnalysisEngine(sampleRate: format.sampleRate,
                                channelCount: Int(format.channelCount),
                                fftSize: fftSize)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.analyze(buffer)
        }
        try audioEngine.start()
    }

    func stop() {
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
    }

    private func analyze(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData else { return }
        let channels = (0..<Int(buffer.format.channelCount)).map { UnsafePointer(data[$0]) }
        lock.lock()
        engine?.process(channels: channels, frameCount: Int(buffer.frameLength))
        let snap = engine?.snapshot
        lock.unlock()
        if let snap {
            DispatchQueue.main.async { [weak self] in self?.onSnapshot?(snap) }
        }
    }

    func findDelay() {
        lock.lock()
        engine?.findAndApplyDelay()
        lock.unlock()
    }

    func resetPeaks() {
        lock.lock()
        engine?.resetPeaks()
        lock.unlock()
    }
}
