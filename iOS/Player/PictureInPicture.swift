// iOS/Player/PictureInPicture.swift
//
// iOS Picture in Picture for AetherEngine's software path. Live TV and recordings both decode
// through AVSampleBufferDisplayLayer, so there is no AVPlayer to hand AVKit. The engine exposes a
// SoftwarePiPSource instead — its display layer plus the transport answers on the enqueued frames'
// axis — and AVKit wants a playback delegate around that layer. This is that bridge.
//
// Setting `engine.pictureInPictureActive` is the part that keeps the feed playing: the engine treats
// a backgrounded session with PiP active as still presenting, so it keeps demuxing, decoding and
// enqueueing frames instead of tearing the session down.
import AetherEngine
import AVFoundation
import AVKit
import Combine

/// One `AVPictureInPictureController` driven by one engine's `SoftwarePiPSource`.
final class PictureInPicture: NSObject, ObservableObject {
    /// AVKit's answer to whether a session can start right now.
    @Published private(set) var isPossible = false
    /// The engine has a PiP bridge, so the button is meaningful. AVKit's own `isPossible` lags
    /// behind the layer being ready, so this is what gates the button.
    @Published private(set) var hasSource = false
    /// Whether this device can do PiP at all. False on the iOS simulator, where AVKit reports no
    /// support and hands back a nil controller.
    @Published private(set) var isSupported = AVPictureInPictureController.isPictureInPictureSupported()
    /// A PiP session is running.
    @Published private(set) var isActive = false
    /// Why a start failed, if one did.
    @Published private(set) var failure: String?
    /// The size the PiP window is rendering at, for the debug stats overlay.
    @Published private(set) var windowSize: CGSize?

    /// Start PiP on its own when the app is backgrounded, so leaving the app keeps the feed playing
    /// rather than suspending it.
    var startsAutomaticallyFromInline = true

    private var controller: AVPictureInPictureController?
    private var possibleObservation: NSKeyValueObservation?
    private weak var engine: AetherEngine?
    private var source: SoftwarePiPSource?
    private var cancellables = Set<AnyCancellable>()

    // MARK: binding

    /// Follow the engine's PiP bridge. It appears when a session gets its display layer and goes nil
    /// with the session, so re-pointing the controller at a fresh layer after a retune is normal.
    @MainActor func bind(_ engine: AetherEngine) {
        unbind()
        self.engine = engine

        engine.$softwarePiPSource
            .receive(on: DispatchQueue.main)
            .sink { [weak self] source in self?.adopt(source) }
            .store(in: &cancellables)

        // AVKit caches the playback state until told otherwise. A pause, a resume, and a recording's
        // length landing late all need it to ask the delegate again. A state change also means the
        // layer has been on screen by now, so it is the retry for a controller that AVKit refused to
        // build while the layer was still unattached.
        let refresh = { [weak self] in
            self?.invalidatePlaybackState()
            self?.retryBuildController()
        }
        engine.$state
            .receive(on: DispatchQueue.main)
            .sink { _ in refresh() }
            .store(in: &cancellables)
        engine.$duration
            .receive(on: DispatchQueue.main)
            .sink { _ in refresh() }
            .store(in: &cancellables)
    }

    /// Drop the controller. Player views call this on their way out; a session teardown reaches
    /// `adopt(nil)`, which does the same to the controller but keeps the subscription alive.
    @MainActor func unbind() {
        cancellables.removeAll()
        engine?.pictureInPictureActive = false
        resetController()
        engine = nil
        failure = nil
        windowSize = nil
    }

    @MainActor func toggle() {
        if isActive {
            stop()
            return
        }
        retryBuildController()
        start()
    }

    @MainActor func start() {
        guard let controller else { return }
        failure = nil
        controller.startPictureInPicture()
    }

    @MainActor func stop() {
        controller?.stopPictureInPicture()
    }

    // MARK: content source

    @MainActor private func adopt(_ source: SoftwarePiPSource?) {
        self.source = source
        hasSource = source != nil
        guard let source else {
            // A PiP window around a layer the engine has released is worse than no PiP window.
            if isActive { controller?.stopPictureInPicture() }
            engine?.pictureInPictureActive = false
            resetController()
            return
        }

        if let controller {
            controller.contentSource = contentSource(for: source.layer)
        } else {
            buildController(layer: source.layer)
        }
        invalidatePlaybackState()
    }

    @MainActor private func contentSource(for layer: AVSampleBufferDisplayLayer) -> AVPictureInPictureController.ContentSource {
        AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: layer, playbackDelegate: self)
    }

    /// AVKit's ObjC initializer answers nil when there is no PiP to build, and Swift imports that as
    /// a non-optional object, so nothing here may message the candidate before it is checked.
    /// Messaging nil answers false, which makes `isKind(of:)` the nil test.
    @MainActor @discardableResult private func buildController(layer: AVSampleBufferDisplayLayer) -> Bool {
        guard isSupported else {
            hasSource = false
            failure = "Picture in picture isn't supported on this device."
            return false
        }
        let candidate = AVPictureInPictureController(contentSource: contentSource(for: layer))
        guard candidate.isKind(of: AVPictureInPictureController.self) else {
            failure = "Picture in picture isn't available for this stream yet."
            return false
        }
        failure = nil
        candidate.delegate = self
        candidate.canStartPictureInPictureAutomaticallyFromInline = startsAutomaticallyFromInline
        controller = candidate
        // AVKit decides when the layer is ready; KVO is the only signal for it.
        possibleObservation = candidate.observe(\.isPictureInPicturePossible, options: [.initial, .new]) {
            [weak self] controller, _ in
            let possible = controller.isPictureInPicturePossible
            DispatchQueue.main.async { self?.isPossible = possible }
        }
        return true
    }

    /// Build the controller if an earlier attempt came back empty and there is a source to build from.
    @MainActor private func retryBuildController() {
        guard controller == nil, let source, isSupported else { return }
        buildController(layer: source.layer)
    }

    @MainActor private func resetController() {
        possibleObservation?.invalidate()
        possibleObservation = nil
        controller?.delegate = nil
        controller?.contentSource = nil
        controller = nil
        source = nil
        hasSource = false
        isActive = false
        isPossible = false
        isSupported = AVPictureInPictureController.isPictureInPictureSupported()
    }

    @MainActor private func invalidatePlaybackState() {
        controller?.invalidatePlaybackState()
    }

    // MARK: timeline arithmetic

    /// The window's playable range, on the axis its frames are timestamped on — the source axis,
    /// where `sourceTime` is `currentTime` plus the session's zero point.
    ///
    /// AVKit reads an infinite duration as live content and gives the window a stop button, because
    /// it assumes live content cannot be paused; tapping that button ended the feed instead of
    /// pausing it. This app's live TV has the engine's client-side DVR window, which its own banner
    /// pauses and rewinds through, so the window is handed that span and gets a pause button. Nil
    /// means there is no DVR window to report, and the caller falls back to the engine's answer
    /// (live-only content, or a recording's finite range).
    ///
    /// AVKit also requires a finite range to contain the layer's current time, so the window is
    /// widened to the playhead rather than clipped by it.
    static func windowTimeRange(sourceTime: Double, currentTime: Double,
                                liveWindow: ClosedRange<Double>?) -> CMTimeRange? {
        guard let liveWindow else { return nil }
        let lower = min(liveWindow.lowerBound, currentTime)
        let upper = max(liveWindow.upperBound, currentTime)
        guard upper > lower else { return nil }
        let origin = sourceTime - currentTime
        return CMTimeRange(start: CMTime(seconds: origin + lower, preferredTimescale: 600),
                           duration: CMTime(seconds: upper - lower, preferredTimescale: 600))
    }

    /// Where a skip lands: clamped into the DVR window, with the live edge rejoined rather than a
    /// seek past it. The 3s margin is the banner's own near-live rule.
    static func skipTarget(currentTime: Double, by seconds: Double,
                           liveWindow: ClosedRange<Double>?) -> (time: Double, atLiveEdge: Bool) {
        guard let liveWindow else { return (max(0, currentTime + seconds), false) }
        let target = currentTime + seconds
        if target >= liveWindow.upperBound - 3 { return (liveWindow.upperBound, true) }
        return (max(target, liveWindow.lowerBound), false)
    }

    // AVKit calls the delegate on the main thread; `MainActor.assumeIsolated` says so to the
    // compiler instead of bouncing every answer through another queue.
    private func onMain<T>(_ body: () -> T) -> T {
        MainActor.assumeIsolated(body)
    }
}

// MARK: AVPictureInPictureControllerDelegate

extension PictureInPicture: AVPictureInPictureControllerDelegate {
    func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        failure = nil
        isActive = true
        // Armed before the background transition, which is what the engine's keepalive policy waits for.
        engine?.pictureInPictureActive = true
    }

    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        isActive = true
        engine?.pictureInPictureActive = true
        invalidatePlaybackState()
    }

    func pictureInPictureControllerWillStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        isActive = false
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        isActive = false
        windowSize = nil
        // Clearing this is what lets the engine tear down a session it can no longer show.
        engine?.pictureInPictureActive = false
        invalidatePlaybackState()
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    failedToStartPictureInPictureWithError error: Error) {
        isActive = false
        engine?.pictureInPictureActive = false
        failure = "Picture in picture failed: \(error.localizedDescription)"
    }
}

// MARK: AVPictureInPictureSampleBufferPlaybackDelegate

extension PictureInPicture: AVPictureInPictureSampleBufferPlaybackDelegate {
    /// The DVR window for live sessions (see `windowTimeRange`); the engine's own answer for
    /// everything else. No content at all is `.invalid`, so AVKit shows nothing rather than a stuck
    /// scrubber.
    func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        onMain {
            guard let source else { return CMTimeRange.invalid }
            guard let engine,
                  let range = Self.windowTimeRange(sourceTime: engine.sourceTime,
                                                   currentTime: engine.currentTime,
                                                   liveWindow: engine.seekableLiveRange)
            else { return source.timeRange() }
            return range
        }
    }

    func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool {
        onMain { source?.isPaused ?? true }
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {
        onMain {
            source?.setPlaying(playing)
            invalidatePlaybackState()
        }
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    didTransitionToRenderSize newRenderSize: CMVideoDimensions) {
        let size = CGSize(width: Int(newRenderSize.width), height: Int(newRenderSize.height))
        DispatchQueue.main.async { self.windowSize = size }
    }

    /// The window's skip buttons seek the engine. The completion handler has to run even when the
    /// seek has nowhere to go, or AVKit's scrubber stays stuck in the seeking state.
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    skipByInterval skipInterval: CMTime,
                                    completion: @escaping () -> Void) {
        onMain {
            guard let engine, engine.state == .playing || engine.state == .paused else {
                completion()
                return
            }
            // A seek while paused renders nothing until the session resumes, as on the banner.
            let wasPaused = engine.state == .paused
            let (target, atLiveEdge) = Self.skipTarget(currentTime: engine.currentTime,
                                                       by: CMTimeGetSeconds(skipInterval),
                                                       liveWindow: engine.seekableLiveRange)
            Task {
                if atLiveEdge { await engine.seekToLiveEdge() } else { await engine.seek(to: target) }
                if wasPaused { engine.play() }
                // The playhead moved and possibly resumed; AVKit caches both answers until asked.
                invalidatePlaybackState()
                completion()
            }
        }
    }

    /// The engine's iOS audio session is `.playback` with the default route-sharing policy, and the
    /// software host treats a backgrounded session with PiP active as still foreground, so audio keeps
    /// running. Promising it is what the PiP window does with that.
    func pictureInPictureControllerShouldProhibitBackgroundAudioPlayback(_ pictureInPictureController: AVPictureInPictureController) -> Bool {
        false
    }
}
