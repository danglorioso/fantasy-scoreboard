import AVFoundation

/// The lead-change air horn, synthesized in code (no audio file). It plays mixed with whatever
/// you're watching, so the game's audio keeps going underneath. Only lead changes make a sound.
@MainActor
final class SoundEffects {
    static let shared = SoundEffects()

    enum Kind { case leadChange }

    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let sampleRate = 44_100.0
    private lazy var format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
    private var buffers: [Kind: AVAudioPCMBuffer] = [:]
    private var attached = false

    /// Plays `kind` at `volume` (0 = off, 1 = full).
    func play(_ kind: Kind, volume: Double) {
        guard volume > 0 else { return }
        if !attached {
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
            attached = true
        }
        if !engine.isRunning {
            do { try engine.start() } catch { return }
        }
        let buffer = buffers[kind] ?? makeBuffer(kind)
        buffers[kind] = buffer
        node.volume = Float(volume)
        node.scheduleBuffer(buffer, at: nil, options: .interrupts, completionHandler: nil)
        if !node.isPlaying { node.play() }
    }

    // MARK: Synthesis

    /// An air horn: "BWAAP — BWAAP — BWAAAAAAP". Several slightly detuned brassy tones,
    /// pushed into soft distortion, with a small pitch sag at the end of each blast.
    private func makeBuffer(_ kind: Kind) -> AVAudioPCMBuffer {
        // (start s, length s)
        let blasts: [(Double, Double)] = [(0, 0.2), (0.27, 0.2), (0.54, 0.95)]
        // (base frequency Hz, loudness) — a stacked chord gives the classic horn sound.
        let voices: [(Double, Double)] = [(233.1, 1.0), (235.2, 0.8), (349.2, 0.7), (466.2, 0.45)]
        let total = (blasts.map { $0.0 + $0.1 }.max() ?? 1) + 0.05
        let frames = AVAudioFrameCount(total * sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let left = buffer.floatChannelData![0]
        let right = buffer.floatChannelData![1]

        var phases = [Double](repeating: 0, count: voices.count)
        for i in 0..<Int(frames) {
            let t = Double(i) / sampleRate
            guard let (start, length) = blasts.first(where: { t >= $0.0 && t < $0.0 + $0.1 }) else {
                left[i] = 0; right[i] = 0
                continue
            }
            let u = t - start
            let attack = min(1, u / 0.012)
            let release = min(1, (length - u) / 0.05)
            let envelope = attack * release
            // A slight scoop up at the start and sag at the end, like a real horn.
            let bend = 1 - 0.03 * exp(-u / 0.03) - 0.04 * max(0, (u - (length - 0.12)) / 0.12)

            var sample = 0.0
            for (v, (freq, loud)) in voices.enumerated() {
                phases[v] += 2 * .pi * freq * bend / sampleRate
                // Band-limited sawtooth: the buzzy, brassy part.
                var saw = 0.0
                for h in 1...10 { saw += sin(Double(h) * phases[v]) / Double(h) }
                sample += loud * saw
            }
            // Soft distortion gives the blare; then scale to a safe level.
            let value = tanh(sample * 0.9) * 0.55 * envelope
            left[i] = Float(value)
            right[i] = Float(value)
        }
        return buffer
    }
}
