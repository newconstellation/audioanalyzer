import AVFoundation
import AnalysisCore
import os

/// Owns the audio engine: captures the default input device and analyses it
/// on the tap thread, and plays the signal generator to the default output.
/// A snapshot of the results is published to the main thread for drawing.
///
/// The analysis source is one of:
/// - the input device (channels 1 and 2; mono input is mirrored to both);
/// - loopback: the generator feeds the analysis directly and the output is
///   muted, so everything can be tried with no audio hardware attached;
/// - a loaded audio file, played (looping) through the analysis in real time
///   at its own sample rate, paced by the input tap.
///
/// Whatever is analysed is also kept in a capture buffer (the last minute),
/// which can be saved as a WAV file.
final class AudioInput {
    var onSnapshot: ((AnalyzerSnapshot) -> Void)?
    var fftSize = 8192
    static let captureSeconds = 60.0

    private let audioEngine = AVAudioEngine()
    // Taps arrive on an AVAudioEngine worker thread, not the real-time I/O
    // thread, so a lock here is safe.
    private let lock = NSLock()
    private var engine: AnalysisEngine?
    private var inputRate = 0.0
    private var octaveFraction = OctaveFraction.third

    /// Shared with the real-time output thread, which only ever *tries* the
    /// lock and keeps its previous settings if it's busy.
    private let generatorState = OSAllocatedUnfairLock(initialState: (settings: GeneratorSettings(), loopback: false))
    private var loopbackGenerator: SignalGenerator?
    private var loopbackBuffer: [Float] = []

    private struct LoadedFile {
        var channels: [[Float]]
        var sampleRate: Double
        var position = 0
    }
    private var file: LoadedFile?
    private var fileScratch: [[Float]] = [[], []]

    private var capture = CaptureRing(channels: 2, capacity: 0)

    func setGenerator(_ settings: GeneratorSettings) {
        generatorState.withLock { $0.settings = settings }
    }

    func setLoopback(_ on: Bool) {
        generatorState.withLock { $0.loopback = on }
    }

    func setOctaveFraction(_ f: OctaveFraction) {
        lock.withLock {
            octaveFraction = f
            engine?.octaveFraction = f
        }
    }

    func start() throws {
        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            throw NSError(domain: "AudioInput", code: 1, userInfo: [NSLocalizedDescriptionKey: "No input device"])
        }
        inputRate = format.sampleRate
        lock.withLock { makeEngine(sampleRate: format.sampleRate) }
        loopbackGenerator = SignalGenerator(sampleRate: format.sampleRate)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.analyze(buffer)
        }
        attachGeneratorOutput()
        try audioEngine.start()
    }

    /// Call with the lock held.
    private func makeEngine(sampleRate: Double) {
        let e = AnalysisEngine(sampleRate: sampleRate, channelCount: 2, fftSize: fftSize)
        e.octaveFraction = octaveFraction
        engine = e
        capture = CaptureRing(channels: 2, capacity: Int(Self.captureSeconds * sampleRate))
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
        if var f = file {
            // Same wall-clock duration as the input block, at the file's rate.
            let m = max(1, Int((Double(n) * f.sampleRate / max(inputRate, 1)).rounded()))
            let length = f.channels[0].count
            for c in 0..<2 {
                if fileScratch[c].count < m { fileScratch[c] = [Float](repeating: 0, count: m) }
                let src = f.channels[min(c, f.channels.count - 1)]
                for i in 0..<m { fileScratch[c][i] = src[(f.position + i) % length] }
            }
            f.position = (f.position + m) % length
            file = f
            fileScratch[0].withUnsafeBufferPointer { l in
                fileScratch[1].withUnsafeBufferPointer { r in
                    feed([l.baseAddress!, r.baseAddress!], frameCount: m)
                }
            }
        } else if state.loopback, let gen = loopbackGenerator {
            gen.settings = state.settings
            if loopbackBuffer.count < n { loopbackBuffer = [Float](repeating: 0, count: n) }
            loopbackBuffer.withUnsafeMutableBufferPointer { p in
                gen.render(into: p.baseAddress!, frameCount: n)
                let ptr = UnsafePointer(p.baseAddress!)
                feed([ptr, ptr], frameCount: n)
            }
        } else {
            var channels = (0..<Int(buffer.format.channelCount)).map { UnsafePointer(data[$0]) }
            if channels.count == 1 { channels.append(channels[0]) } // mono input: mirror to ch 2
            feed(Array(channels.prefix(2)), frameCount: n)
        }
        let snap = engine?.snapshot
        lock.unlock()
        if let snap {
            DispatchQueue.main.async { [weak self] in self?.onSnapshot?(snap) }
        }
    }

    /// Call with the lock held.
    private func feed(_ channels: [UnsafePointer<Float>], frameCount n: Int) {
        engine?.process(channels: channels, frameCount: n)
        capture.append(channels, frameCount: n)
    }

    // MARK: - Files

    /// Loads an audio file and analyses it, looping, instead of the input.
    /// Returns its name.
    func loadFile(_ url: URL) throws -> String {
        let f = try AVAudioFile(forReading: url)
        let format = f.processingFormat
        let frames = AVAudioFrameCount(f.length)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            throw NSError(domain: "AudioInput", code: 2, userInfo: [NSLocalizedDescriptionKey: "The file is empty."])
        }
        try f.read(into: buffer)
        guard let data = buffer.floatChannelData else {
            throw NSError(domain: "AudioInput", code: 3, userInfo: [NSLocalizedDescriptionKey: "Unsupported sample format."])
        }
        let n = Int(buffer.frameLength)
        let channels = (0..<min(2, Int(format.channelCount))).map { Array(UnsafeBufferPointer(start: data[$0], count: n)) }
        lock.withLock {
            file = LoadedFile(channels: channels, sampleRate: format.sampleRate)
            makeEngine(sampleRate: format.sampleRate)
        }
        return url.lastPathComponent
    }

    /// Goes back to analysing the input device (or the loopback generator).
    func liveInput() {
        lock.withLock {
            file = nil
            if inputRate > 0 { makeEngine(sampleRate: inputRate) }
        }
    }

    /// Writes the last minute of analysed audio as a 32-bit float WAV file.
    func saveCapture(to url: URL) throws {
        let (channels, rate) = lock.withLock { (capture.ordered(), engine?.sampleRate ?? inputRate) }
        guard let n = channels.first?.count, n > 0,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                                         channels: AVAudioChannelCount(channels.count), interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n))
        else {
            throw NSError(domain: "AudioInput", code: 4, userInfo: [NSLocalizedDescriptionKey: "Nothing has been captured yet."])
        }
        buffer.frameLength = AVAudioFrameCount(n)
        for (c, samples) in channels.enumerated() {
            samples.withUnsafeBufferPointer { buffer.floatChannelData![c].update(from: $0.baseAddress!, count: n) }
        }
        var settings = format.settings
        settings[AVFormatIDKey] = kAudioFormatLinearPCM
        settings[AVLinearPCMIsFloatKey] = true
        settings[AVLinearPCMBitDepthKey] = 32
        settings[AVLinearPCMIsNonInterleaved] = false
        settings[AVLinearPCMIsBigEndianKey] = false
        let out = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try out.write(from: buffer)
    }

    func findDelay() {
        lock.withLock { _ = engine?.findAndApplyDelay() }
    }

    func resetPeaks() {
        lock.withLock { engine?.resetPeaks() }
    }
}

/// The most recent `capacity` frames of each channel.
private struct CaptureRing {
    private var buffers: [[Float]]
    private var write = 0
    private var filled = 0
    let capacity: Int

    init(channels: Int, capacity: Int) {
        self.capacity = capacity
        buffers = Array(repeating: [Float](repeating: 0, count: capacity), count: channels)
    }

    mutating func append(_ channels: [UnsafePointer<Float>], frameCount n: Int) {
        guard capacity > 0, !channels.isEmpty else { return }
        for c in buffers.indices {
            let src = channels[min(c, channels.count - 1)]
            var w = write
            for i in 0..<n {
                buffers[c][w] = src[i]
                w += 1
                if w == capacity { w = 0 }
            }
        }
        write = (write + n) % capacity
        filled = min(capacity, filled + n)
    }

    /// Oldest first.
    func ordered() -> [[Float]] {
        buffers.map { b in
            filled < capacity ? Array(b[0..<filled]) : Array(b[write...] + b[..<write])
        }
    }
}
