import AVFoundation

/// The lead-change air horn: a bundled clip (LeadChangeAirHorn.m4a), with a synthesized horn
/// as a backup. It plays mixed with whatever
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

    /// The air horn clip bundled with the app (LeadChangeAirHorn.m4a).
    private lazy var clip: AVAudioPlayer? = {
        guard let url = Bundle.main.url(forResource: "LeadChangeAirHorn", withExtension: "m4a"),
              let player = try? AVAudioPlayer(contentsOf: url) else { return nil }
        player.prepareToPlay()
        return player
    }()

    /// Plays `kind` at `volume` (0 = off, 1 = full). Uses the bundled clip, or a synthesized
    /// horn if the clip can't be loaded.
    func play(_ kind: Kind, volume: Double) {
        guard volume > 0 else { return }
        if let clip {
            clip.volume = Float(volume)
            clip.currentTime = 0
            clip.play()
            return
        }
        playSynthesized(kind, volume: volume)
    }

    private func playSynthesized(_ kind: Kind, volume: Double) {
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

    // MARK: Synthesized backup

    /// The meme air horn: a rapid-fire burst of short blasts, then one long one
    /// ("BRAP-BRAP-BRAP-BRAP-BRAP-BRAAAAAP"). A high, slightly detuned chord pushed into
    /// distortion, with a small pitch sag at the end of each blast.
    private func makeBuffer(_ kind: Kind) -> AVAudioPCMBuffer {
        // (start s, length s): one opener, four quick stabs, then the long blast.
        var blasts: [(Double, Double)] = [(0, 0.16)]
        var t = 0.21
        for _ in 0..<4 {
            blasts.append((t, 0.085))
            t += 0.125
        }
        blasts.append((t + 0.03, 0.7))
        // (base frequency Hz, loudness): around B4 with a fifth and octave on top.
        let voices: [(Double, Double)] = [(466.2, 1.0), (470.0, 0.85), (698.5, 0.6), (932.3, 0.45), (936.5, 0.3)]
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
            let attack = min(1, u / 0.006)
            let release = min(1, (length - u) / 0.025)
            let envelope = attack * release
            // A slight scoop up at the start and sag at the end, like a real horn.
            let bend = 1 - 0.025 * exp(-u / 0.02) - 0.035 * max(0, (u - (length - 0.1)) / 0.1)

            var sample = 0.0
            for (v, (freq, loud)) in voices.enumerated() {
                phases[v] += 2 * .pi * freq * bend / sampleRate
                // Band-limited sawtooth: the buzzy, brassy part.
                var saw = 0.0
                for h in 1...7 { saw += sin(Double(h) * phases[v]) / Double(h) }
                sample += loud * saw
            }
            // Soft distortion gives the blare; then scale to a safe level.
            let value = tanh(sample * 1.3) * 0.55 * envelope
            left[i] = Float(value)
            right[i] = Float(value)
        }
        return buffer
    }
}
