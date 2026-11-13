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
    private var animationStart = Date.distantPast
    private let animationSeconds = 0.45
    private var isAnimating: Bool { Date().timeIntervalSince(animationStart) < animationSeconds }

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
                // Fast ticks only while an alert is animating in; otherwise stay lazy.
                try? await Task.sleep(for: .milliseconds(self.isAnimating ? 50 : 300))
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

        // Only redraw when something on screen actually changed (saves CPU in the background,
        // where tvOS kills apps that work too hard).
        let snapshotKey = tracker.snapshot.map { s in
            s.matchups.map { "\($0.home.points)-\($0.away?.points ?? 0)" }.joined(separator: ",")
        } ?? "none"
        if tracker.currentEvent?.id != lastEventId {
            lastEventId = tracker.currentEvent?.id
            if lastEventId != nil { animationStart = Date() }
        }
        let progress = min(1, Date().timeIntervalSince(animationStart) / animationSeconds)

        let key = [snapshotKey, tracker.currentEvent?.id.uuidString ?? "idle",
                   tracker.recent.first ?? "", tracker.statusLine,
                   String(format: "%.2f", progress)].joined(separator: "|")
        guard key != lastRenderKey else { return }
        lastRenderKey = key

        let view = ScoreboardView(snapshot: tracker.snapshot,
                                  event: tracker.currentEvent,
                                  ticker: tracker.recent.first,
                                  status: tracker.statusLine,
                                  appear: progress)
        let renderer = ImageRenderer(content: view)
        renderer.proposedSize = ProposedViewSize(ScoreboardView.size)
        renderer.scale = 1
        if let image = renderer.cgImage {
            FrameStore.shared.set(image)
        }
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
        videoComposition.frameDuration = CMTime(value: 1, timescale: 20) // smooth enough for the slide-in; each frame just copies the cached image
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

/// Latest scoreboard image, shared between the main thread (writer) and the compositor (reader).
final class FrameStore: @unchecked Sendable {
    static let shared = FrameStore()
    private let lock = NSLock()
    private var image: CGImage?

    func set(_ newImage: CGImage) {
        lock.lock(); image = newImage; lock.unlock()
    }

    func draw(into pb: CVPixelBuffer) {
        lock.lock(); let img = image; lock.unlock()

        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                      | CGBitmapInfo.byteOrder32Little.rawValue) else { return }
        let rect = CGRect(x: 0, y: 0, width: w, height: h)
        ctx.setFillColor(UIColor.black.cgColor)
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
        FrameStore.shared.draw(into: out)
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
