import AVFoundation

/// The lead-change fanfare, synthesized in code (no audio file). It plays mixed with whatever
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

    /// (frequency Hz, start s, length s, loudness)
    private typealias Note = (Double, Double, Double, Double)

    private func notes(for kind: Kind) -> [Note] {
        switch kind {
        case .leadChange:  // short fanfare
            return [(392.0, 0, 0.14, 0.5), (523.3, 0.12, 0.14, 0.5), (659.3, 0.24, 0.14, 0.5),
                    (784.0, 0.36, 0.75, 0.6), (987.8, 0.36, 0.75, 0.3), (1174.7, 0.36, 0.75, 0.2)]
        }
    }

    private func makeBuffer(_ kind: Kind) -> AVAudioPCMBuffer {
        let list = notes(for: kind)
        let total = (list.map { $0.1 + $0.2 }.max() ?? 0.5) + 0.05
        let frames = AVAudioFrameCount(total * sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let left = buffer.floatChannelData![0]
        let right = buffer.floatChannelData![1]

        for i in 0..<Int(frames) {
            let t = Double(i) / sampleRate
            var sample = 0.0
            for (freq, start, length, loud) in list where t >= start && t < start + length {
                let u = t - start
                // Quick attack, smooth exponential decay: a soft bell rather than a beep.
                let attack = min(1, u / 0.008)
                let decay = exp(-u * 4.5 / length)
                let tone = sin(2 * .pi * freq * u) + 0.3 * sin(4 * .pi * freq * u) + 0.1 * sin(6 * .pi * freq * u)
                sample += loud * attack * decay * tone
            }
            let value = Float(max(-1, min(1, sample * 0.45)))
            left[i] = value
            right[i] = value
        }
        return buffer
    }
}
