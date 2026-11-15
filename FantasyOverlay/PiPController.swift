import AVFoundation
import AVKit
import CoreMedia
import SwiftUI
import UIKit

/// Shows the scoreboard in a Picture-in-Picture window that floats over other apps.
///
/// tvOS only allows PiP for real AVPlayer video (custom sample-buffer PiP never becomes
/// "possible" on Apple TV). So we play a long, blank, silent video through AVPlayer and use
/// a custom video compositor to paint the latest scoreboard image onto every frame.
@MainActor
final class PiPController: NSObject, ObservableObject {
    let player = AVPlayer()
    let playerLayer = AVPlayerLayer()

    @Published private(set) var isActive = false
    @Published private(set) var isPossible = false
    @Published private(set) var lastError: String?
    @Published private(set) var debugStatus = "PiP: preparing video…"

    private var pip: AVPictureInPictureController?
    private var possibleObservation: NSKeyValueObservation?
    private var renderTask: Task<Void, Never>?
    private var endObserver: NSObjectProtocol?
    private var didSetUp = false
    private var lastRenderKey = ""
    private var lastEventId: UUID?
    /// How far ahead of the video's current time an alert is scheduled, so the player
    /// hasn't already composed those frames (that's what made it choppy before).
    private let scheduleLead = 0.6

    func setUp(tracker: ScoreTracker) {
        guard !didSetUp else { return }
        didSetUp = true
        configureAudioSession()

        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspect
        player.isMuted = true
        player.preventsDisplaySleepDuringVideoPlayback = false

        // Draw the scoreboard into the shared frame store ~2x/sec.
        renderTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.renderFrame(tracker)
                try? await Task.sleep(for: .milliseconds(250))
            }
        }

        Task {
            do {
                let item = try await Self.makeScoreboardItem()
                player.replaceCurrentItem(with: item)
                endObserver = NotificationCenter.default.addObserver(
                    forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
                ) { [player] _ in
                    Task { @MainActor in
                        await player.seek(to: .zero)
                        player.play()
                    }
                }
                player.play()
                createPiPController()
            } catch {
                lastError = "Couldn't build scoreboard video: \(error.localizedDescription)"
            }
        }
    }

    private func createPiPController() {
        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            lastError = "Picture in Picture isn't supported on this Apple TV."
            return
        }
        guard let controller = AVPictureInPictureController(playerLayer: playerLayer) else {
            lastError = "Couldn't create the PiP controller."
            return
        }
        controller.delegate = self
        controller.requiresLinearPlayback = true
        possibleObservation = controller.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] c, _ in
            let possible = c.isPictureInPicturePossible
            Task { @MainActor in self?.isPossible = possible }
        }
        pip = controller
    }

    func toggle() {
        guard let pip else {
            lastError = "PiP isn't ready yet (see status line)."
            return
        }
        if pip.isPictureInPictureActive {
            pip.stopPictureInPicture()
        } else {
            if player.rate == 0 { player.play() }
            if !pip.isPictureInPicturePossible {
                lastError = "tvOS says PiP isn't possible yet — trying anyway."
            }
            pip.startPictureInPicture()
        }
    }

    // MARK: Rendering

    private func renderFrame(_ tracker: ScoreTracker) {
        updateDebugStatus()

        // New alert: pre-render its whole animation and schedule it on the video's clock.
        if tracker.currentEvent?.id != lastEventId {
            lastEventId = tracker.currentEvent?.id
            if let event = tracker.currentEvent {
                let frames = buildAlertTimeline(event)
                // Back-to-back alerts: start this one exactly where the previous one would have
                // begun fading out, so the queue plays straight through with no idle gap.
                let earliest = player.currentTime().seconds + scheduleLead
                let start = max(earliest, FrameStore.shared.lastFadeStart ?? earliest)
                FrameStore.shared.addTimeline(start: start, frames: frames,
                                              fadeSeconds: Config.fadeOutSeconds)
            }
        }

        // Idle tile: only redraw when it actually changes (saves CPU in the background,
        // where tvOS kills apps that work too hard).
        let snapshotKey = tracker.snapshot.map { s in
            s.matchups.map {
                "\($0.home.label)\($0.home.points)-\($0.away?.points ?? 0)@\(Int((($0.homeWinProbability ?? -1) * 100).rounded()))"
            }.joined(separator: ",")
        } ?? "none"
        // Leagues with more than 4 matchups rotate through pages of columns.
        let pages = tracker.snapshot.map { ScoreboardView.pageCount($0.matchups) } ?? 1
        let idlePage = pages > 1 ? Int(Date().timeIntervalSince1970 / Config.idlePageSeconds) % pages : 0
        let key = [snapshotKey, tracker.recent.first ?? "", tracker.statusLine, "\(idlePage)"].joined(separator: "|")
        guard key != lastRenderKey else { return }
        lastRenderKey = key
        if let image = render(ScoreboardView(snapshot: tracker.snapshot, event: nil,
                                             ticker: tracker.recent.first,
                                             status: tracker.statusLine,
                                             idlePage: idlePage)) {
            FrameStore.shared.setIdle(image)
        }
    }

    /// Every frame of one alert. Each entry is (image, how long to show it).
    ///   burst:   grow in fast, then hold the big point change (a lead change holds longer
    ///            and pulses)
    ///   slide:   burst slides out left as the details slide in from the right
    ///   settle:  win % moves from its old value to the new one
    ///   details: hold (the longest part: most information to read)
    ///   exit:    fade out
    private func buildAlertTimeline(_ event: ScoreEvent) -> [(CGImage, Double)] {
        let dt = 1.0 / 30
        var frames: [(CGImage, Double)] = []
        func add(intro: Double = 1, morph: Double = 1, settle: Double = 1, exit: Double = 0,
                 pulse: Double = 0, _ duration: Double) {
            let view = AlertCard(event: event, intro: intro, morph: morph, settle: settle,
                                 exit: exit, pulse: pulse)
                .frame(width: ScoreboardView.size.width, height: ScoreboardView.size.height)
            if let img = render(view) { frames.append((img, duration)) }
        }
        func steps(_ n: Int) -> [Double] { (1...max(1, n)).map { Double($0) / Double(max(1, n)) } }

        // Stage 1: burst
        let introFrames = 7                                  // ~0.23 s grow-in
        let introSeconds = Double(introFrames) * dt
        for t in steps(introFrames) { add(intro: t, morph: 0, settle: 0, dt) }
        if event.isLeadChange {
            // Pulse ~1.6 times a second while it holds (drawn at 15 fps to keep this quick).
            let hold = max(0.3, Config.leadBurstSeconds - introSeconds)
            let step = 1.0 / 15
            let count = max(1, Int((hold / step).rounded()))
            for i in 0..<count {
                let t = Double(i) * step
                add(morph: 0, settle: 0, pulse: sin(t * 2 * .pi * 1.6), hold / Double(count))
            }
        } else {
            add(morph: 0, settle: 0, max(0.3, Config.burstSeconds - introSeconds))
        }

        // Slide to the details screen
        for t in steps(Int((Config.slideSeconds / dt).rounded())) { add(morph: t, settle: 0, dt) }

        // Stage 2: details (starting with a 0.6 s settle)
        let settleFrames = 18
        for t in steps(settleFrames) { add(settle: t, dt) }
        add(max(1.0, Config.detailSeconds - Double(settleFrames) * dt))

        // Fade out
        for t in steps(Int((Config.fadeOutSeconds / dt).rounded())) { add(exit: t, dt) }
        return frames
    }

    private func render<V: View>(_ view: V) -> CGImage? {
        let renderer = ImageRenderer(content: view)
        renderer.proposedSize = ProposedViewSize(ScoreboardView.size)
        renderer.scale = 1
        return renderer.cgImage
    }

    private func updateDebugStatus() {
        let itemStatus: String
        switch player.currentItem?.status {
        case .readyToPlay: itemStatus = "ready"
        case .failed: itemStatus = "failed"
        case .some: itemStatus = "loading"
        case .none: itemStatus = "none"
        }
        let newStatus = "PiP supported: \(AVPictureInPictureController.isPictureInPictureSupported() ? "yes" : "no")"
            + " · possible: \(pip?.isPictureInPicturePossible == true ? "yes" : "no")"
            + " · video: \(itemStatus) · playing: \(player.rate > 0 ? "yes" : "no")"
        if newStatus != debugStatus { debugStatus = newStatus }
        if let err = player.currentItem?.error {
            lastError = "Video error: \(err.localizedDescription)"
        }
    }

    private func configureAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .moviePlayback,
                                    options: Config.mixWithOtherAudio ? [.mixWithOthers] : [])
            try session.setActive(true)
        } catch {
            lastError = "Audio session: \(error.localizedDescription)"
        }
    }

    // MARK: Building the "video"

    /// A tiny blank clip stretched to 24 hours, with our compositor painting every frame.
    private static func makeScoreboardItem() async throws -> AVPlayerItem {
        let size = ScoreboardView.size
        let url = try await makeBlankClip(size: size)
        let asset = AVURLAsset(url: url)
        guard let sourceTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw NSError(domain: "FantasyOverlay", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Blank clip has no video track"])
        }
        let clipDuration = try await asset.load(.duration)

        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(withMediaType: .video,
                                                      preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw NSError(domain: "FantasyOverlay", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Couldn't add composition track"])
        }
        try track.insertTimeRange(CMTimeRange(start: .zero, duration: clipDuration), of: sourceTrack, at: .zero)
        let longDuration = CMTime(seconds: 24 * 3600, preferredTimescale: 600)
        track.scaleTimeRange(CMTimeRange(start: .zero, duration: clipDuration), toDuration: longDuration)

        // Custom instruction with containsTweening = true. Without it, AVFoundation sees the
        // source frame never changes and reuses the first composed frame forever
        // (which is why the PiP was stuck on "Connecting…").
        let instruction = ScoreboardInstruction(timeRange: CMTimeRange(start: .zero, duration: longDuration))

        let videoComposition = AVMutableVideoComposition()
        videoComposition.customVideoCompositorClass = ScoreboardCompositor.self
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30) // 30 fps; each frame just copies a pre-rendered image
        videoComposition.renderSize = size
        videoComposition.instructions = [instruction]

        let item = AVPlayerItem(asset: composition)
        item.videoComposition = videoComposition
        return item
    }

    /// Writes a 2-second black H.264 clip to a temp file.
    private static func makeBlankClip(size: CGSize) async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("scoreboard-blank.mov")
        try? FileManager.default.removeItem(at: url)

        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? NSError(domain: "FantasyOverlay", code: 3)
        }
        writer.startSession(atSourceTime: .zero)

        for second in 0..<2 {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(10))
            }
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault, Int(size.width), Int(size.height),
                                kCVPixelFormatType_32BGRA,
                                [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary, &pb)
            guard let pb else { throw NSError(domain: "FantasyOverlay", code: 4) }
            CVPixelBufferLockBaseAddress(pb, [])
            if let base = CVPixelBufferGetBaseAddress(pb) {
                memset(base, 0, CVPixelBufferGetDataSize(pb))
            }
            CVPixelBufferUnlockBaseAddress(pb, [])
            adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(second), timescale: 1))
        }

        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: 2, timescale: 1))
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw writer.error ?? NSError(domain: "FantasyOverlay", code: 5)
        }
        return url
    }
}

extension PiPController: AVPictureInPictureControllerDelegate {
    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ c: AVPictureInPictureController) {
        Task { @MainActor in
            self.isActive = true
            self.lastError = nil
        }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ c: AVPictureInPictureController) {
        Task { @MainActor in self.isActive = false }
    }

    nonisolated func pictureInPictureController(_ c: AVPictureInPictureController,
                                                failedToStartPictureInPictureWithError error: Error) {
        let msg = error.localizedDescription
        Task { @MainActor in self.lastError = "PiP failed: \(msg)" }
    }
}

// MARK: - Frame plumbing

/// Images for the video: an idle tile, plus a pre-rendered alert animation scheduled
/// at a point on the video's timeline. Written on the main thread, read by the compositor.
final class FrameStore: @unchecked Sendable {
    static let shared = FrameStore()
    private let lock = NSLock()
    private var idle: CGImage?
    private struct Timeline {
        let start: Double
        let frames: [(CGImage, Double)]
        let end: Double
        let fadeStart: Double
    }
    private var timelines: [Timeline] = []

    func setIdle(_ image: CGImage) {
        lock.lock(); idle = image; lock.unlock()
    }

    /// Schedules one alert's frames on the video timeline. The last `fadeSeconds` of frames
    /// are its fade-out, which a following alert scheduled at `fadeStart` replaces.
    func addTimeline(start: Double, frames: [(CGImage, Double)], fadeSeconds: Double) {
        let total = frames.reduce(0) { $0 + $1.1 }
        let tl = Timeline(start: start, frames: frames, end: start + total,
                          fadeStart: start + max(0, total - fadeSeconds))
        lock.lock()
        timelines.removeAll { $0.end < start - 10 }   // drop long-finished alerts
        timelines.append(tl)
        lock.unlock()
    }

    /// When the most recently scheduled alert starts fading out (nil if none yet). A time
    /// already in the past just means there's nothing to chain onto.
    var lastFadeStart: Double? {
        lock.lock(); defer { lock.unlock() }
        return timelines.last?.fadeStart
    }

    /// Which image belongs at video time `t` (seconds): the latest alert that has started,
    /// if it hasn't finished; otherwise the idle tile.
    private func image(at t: Double) -> CGImage? {
        lock.lock(); defer { lock.unlock() }
        var current: Timeline?
        for tl in timelines where tl.start <= t {
            if current == nil || tl.start >= current!.start { current = tl }
        }
        if let tl = current, t < tl.end {
            var end = tl.start
            for (img, duration) in tl.frames {
                end += duration
                if t < end { return img }
            }
        }
        return idle
    }

    func draw(into pb: CVPixelBuffer, at t: Double) {
        let img = image(at: t)

        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                      | CGBitmapInfo.byteOrder32Little.rawValue) else { return }
        let rect = CGRect(x: 0, y: 0, width: w, height: h)
        ctx.setFillColor(UIColor(red: 0.043, green: 0.051, blue: 0.071, alpha: 1).cgColor) // AlertCard.ground
        ctx.fill(rect)
        if let img { ctx.draw(img, in: rect) }
    }
}

/// Tells AVFoundation every frame must be re-rendered and that no source frames are needed.
final class ScoreboardInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]? = nil
    let passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid

    init(timeRange: CMTimeRange) {
        self.timeRange = timeRange
    }
}

/// Ignores the blank source video and paints the latest scoreboard image on each frame.
final class ScoreboardCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    var sourcePixelBufferAttributes: [String: any Sendable]? {
        [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    }

    var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] {
        [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    }

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        guard let out = request.renderContext.newPixelBuffer() else {
            request.finish(with: NSError(domain: "FantasyOverlay", code: 6))
            return
        }
        FrameStore.shared.draw(into: out, at: CMTimeGetSeconds(request.compositionTime))
        request.finish(withComposedVideoFrame: out)
    }
}

/// Hosts the player layer on screen (PiP requires the layer to be in the view hierarchy).
struct PiPLayerView: UIViewRepresentable {
    let layer: CALayer

    func makeUIView(context: Context) -> LayerHostView {
        let v = LayerHostView()
        v.hosted = layer
        v.layer.addSublayer(layer)
        return v
    }

    func updateUIView(_ uiView: LayerHostView, context: Context) {}

    final class LayerHostView: UIView {
        var hosted: CALayer?
        override func layoutSubviews() {
            super.layoutSubviews()
            hosted?.frame = bounds
        }
    }
}
