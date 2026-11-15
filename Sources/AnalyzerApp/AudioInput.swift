import AVFoundation
import AnalysisCore
import os

/// Owns the audio engine: captures the default input device and analyses it
/// on the tap thread, and plays the signal generator to the default output.
/// A snapshot of the results is published to the main thread for drawing.
///
/// In loopback mode the generator feeds the analysis directly (both channels)
/// instead of the input device, and the output is muted, so everything can be
/// tried with no audio hardware attached.
final class AudioInput {
    var onSnapshot: ((AnalyzerSnapshot) -> Void)?
    var fftSize = 8192

    private let audioEngine = AVAudioEngine()
    // Taps arrive on an AVAudioEngine worker thread, not the real-time I/O
    // thread, so a lock here is safe.
    private let lock = NSLock()
    private var engine: AnalysisEngine?

    /// Shared with the real-time output thread, which only ever *tries* the
    /// lock and keeps its previous settings if it's busy.
    private let generatorState = OSAllocatedUnfairLock(initialState: (settings: GeneratorSettings(), loopback: false))
    private var loopbackGenerator: SignalGenerator?
    private var loopbackBuffer: [Float] = []

    func setGenerator(_ settings: GeneratorSettings) {
        generatorState.withLock { $0.settings = settings }
    }

    func setLoopback(_ on: Bool) {
        generatorState.withLock { $0.loopback = on }
    }

    func start() throws {
        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            throw NSError(domain: "AudioInput", code: 1, userInfo: [NSLocalizedDescriptionKey: "No input device"])
        }
        engine = AnalysisEngine(sampleRate: format.sampleRate,
                                channelCount: max(2, Int(format.channelCount)),
                                fftSize: fftSize)
        loopbackGenerator = SignalGenerator(sampleRate: format.sampleRate)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.analyze(buffer)
        }
        attachGeneratorOutput()
        try audioEngine.start()
    }

    private func attachGeneratorOutput() {
        let outputRate = audioEngine.outputNode.outputFormat(forBus: 0).sampleRate
        guard outputRate > 0,
              let format = AVAudioFormat(standardFormatWithSampleRate: outputRate, channels: 2)
        else { return }
        let generator = SignalGenerator(sampleRate: outputRate)
        let state = generatorState
        let source = AVAudioSourceNode(format: format) { _, _, frameCount, bufferList -> OSStatus in
            // Real-time thread: no allocation, no blocking.
            var muted = false
            if let s = state.withLockIfAvailable({ $0 }) {
                generator.settings = s.settings
                muted = s.loopback
            }
            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            let n = Int(frameCount)
            guard let first = buffers.first?.mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            if muted {
                first.update(repeating: 0, count: n)
            } else {
                generator.render(into: first, frameCount: n)
            }
            for b in buffers.dropFirst() {
                b.mData?.assumingMemoryBound(to: Float.self).update(from: first, count: n)
            }
            return noErr
        }
        audioEngine.attach(source)
        audioEngine.connect(source, to: audioEngine.mainMixerNode, format: format)
    }

    func stop() {
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
    }

    private func analyze(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData else { return }
        let n = Int(buffer.frameLength)
        let state = generatorState.withLock { $0 }

        lock.lock()
        if state.loopback, let gen = loopbackGenerator {
            gen.settings = state.settings
            if loopbackBuffer.count < n { loopbackBuffer = [Float](repeating: 0, count: n) }
            loopbackBuffer.withUnsafeMutableBufferPointer { p in
                gen.render(into: p.baseAddress!, frameCount: n)
                let ptr = UnsafePointer(p.baseAddress!)
                engine?.process(channels: [ptr, ptr], frameCount: n)
            }
        } else {
            var channels = (0..<Int(buffer.format.channelCount)).map { UnsafePointer(data[$0]) }
            if channels.count == 1 { channels.append(channels[0]) } // mono input: mirror to ch 2
            engine?.process(channels: channels, frameCount: n)
        }
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
