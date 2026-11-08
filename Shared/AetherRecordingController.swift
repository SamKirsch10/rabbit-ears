// Sources/AetherRecordingController.swift
//
// Playback of a finished tvheadend recording through AetherEngine. A recording is a plain MPEG-TS file
// served at /dvrfile/<uuid> with HTTP Range support, so the engine seeks by byte range; it takes the
// same software MPEG-2 path as live TV.
import AetherEngine
import Combine
import Foundation

final class AetherRecordingController: ObservableObject {
    /// nil only if the engine could not be created; `failure` then carries the reason.
    let engine: AetherEngine?

    @Published private(set) var isPlaying = false
    /// What the scrubber shows. While a scrub is held this is the requested position, because the
    /// player's clock is stale until the seek lands and held presses have to accumulate.
    @Published private(set) var currentTime: TimeInterval = 0
    /// What the player actually shows. The engine writes its clock at the seek's landing, and the
    /// software host lands on the keyframe at or before the target (`keyframeLanding`), so this is the
    /// position a settled scrub still has to describe — the requested position runs seconds ahead of it.
    @Published private(set) var engineTime: TimeInterval = 0
    /// Whether the scrub still should be on screen: presses are in flight, or a press just landed and
    /// the still is showing that landing. A banner that is merely visible is not a scrub — the still is
    /// a preview of a scrub, and while plain playback is up the video is the picture already.
    @Published private(set) var isScrubbing = false
    /// What the scrub still describes right now. While a seek is in flight the player has not landed,
    /// so the requested position is the only answer a held scrub has; once the landing publishes, the
    /// engine's clock takes over and the still matches the picture on screen. Keeping the still on
    /// `engineTime` alone made a fast scrub barely update, because the clock only moves at landings and
    /// a burst of presses supersedes most of them.
    @Published private(set) var stillTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var captionsOn = Captions.enabled
    /// The caption line to draw right now, if any.
    @Published private(set) var captionText: String?
    @Published private(set) var failure: String?
    /// Scrub stills for the banner. nil until the load succeeds: the engine only vends an extractor
    /// once something is loaded, and the strip has nothing to show before that.
    @Published private(set) var thumbnails: ClientSideThumbnailProvider?

    private var entry: DVR.Entry?
    /// Owned here, not by the provider: this is the only caller of `shutdown()`.
    private var extractor: FrameExtractor?
    /// The recording's source-axis origin: the PTS `FrameExtractor` decodes for position 0. A DVR
    /// MPEG-TS file carries absolute transport timestamps, so display 0 is the recording's own start
    /// PTS (~6239 s on the test server's) while the scrubber speaks seconds from 0, and a bucket
    /// asked for without this offset lands on a position before the stream begins -- the first frame,
    /// at every position. nil until the probe answers, which keeps the provider from guessing 0.
    private var stillSourceOffset: TimeInterval?
    /// Cancels the origin probe if the screen goes away before it answers.
    private var stillProbeCancellation: ProbeCancellation?
    private var started = false
    private var loadTask: Task<Void, Never>?
    private var pendingSeekWork: DispatchWorkItem?
    /// The clock the outstanding seek was issued against. A move past it is the landing: a scrub can
    /// land while the session stays `.paused`, so `engine.state` alone never reports it.
    private var seekClockBaseline = 0.0
    private var lastSeekAt = Date.distantPast
    /// The target of the seek the engine is on its way to landing, so the landing can be logged against
    /// what was asked for rather than guessed from what the screen looks like.
    private var lastSeekTarget: TimeInterval?

    /// A press is "hot" while a seek it issued is still outstanding. While one is, the presses still
    /// coming have no landing to describe yet, so the still — and the dot — describe the requested
    /// position, which is what a held scrub accumulates. It stops at the landing, not at a timer: a
    /// fixed window would drop to the stale pre-seek clock while the seek was still buffering, showing
    /// a frame from before the scrub.
    private var previewHot: Bool { pendingSeekWork != nil || lastSeekTarget != nil }
    /// How far the clock has to move before it counts as a landing. Below any keyframe step the source
    /// can be, so playback drift never reads as one.
    private static let landingClockMoveSeconds = 0.25

    /// A seek that never lands must not pin the still to its target forever.
    private static let stalledSeekTimeoutSeconds = 5.0

    /// A press is hot for this window while its seek has not been issued yet (the debounce gap).
    private static let previewWindow: TimeInterval = 0.6

    /// How long the still stays on screen after a landing has been shown. Short: the landed frame is
    /// the picture the video is already playing, so the preview has nothing left to add once it is up.
    private static let landedStillTail: TimeInterval = 0.8
    private var holdDisplayUntil = Date.distantPast
    private var captions: AetherCaptionPresenter?
    private var cancellables = Set<AnyCancellable>()

    init() {
        do {
            let created = try AetherEngine()
            engine = created
            bind(created)
        } catch {
            engine = nil
            failure = "Could not start AetherEngine: \(error)"
        }
    }

    deinit { loadTask?.cancel() }

    // MARK: control

    func connect(entry: DVR.Entry) {
        guard !started else { return }
        started = true
        self.entry = entry
        load(startPosition: nil)
    }

    func disconnect() {
        started = false
        loadTask?.cancel()
        pendingSeekWork?.cancel()
        engine?.stop()

        // The provider stops asking; the extractor is ours to tear down.
        if let provider = thumbnails {
            thumbnails = nil
            provider.stop()
        }
        if let ext = extractor {
            extractor = nil
            Task { await ext.shutdown() }
        }
        // The session is gone, so its origin is: a later load re-derives it.
        stillProbeCancellation?.cancel()
        stillProbeCancellation = nil
        stillSourceOffset = nil
        heldSessionZero = nil
        currentTime = 0
        engineTime = 0
        stillTime = 0
        isScrubbing = false
        duration = 0
        pendingSeekWork = nil
        lastSeekTarget = nil
        lastSeekAt = Date.distantPast
        lastSeekIssuedAt = Date.distantPast
        seekClockBaseline = 0
        holdDisplayUntil = Date.distantPast
    }

    func togglePlayPause() {
        guard let engine else { return }
        if engine.state == .ended {
            // The engine treats the end as terminal: only a fresh load plays again.
            load(startPosition: 0)
            return
        }
        // Assigned, not toggled: the engine's state sink has already updated isPlaying by now.
        if isPlaying {
            engine.pause()
            isPlaying = false
        } else {
            engine.play()
            isPlaying = true
        }
    }

    /// How often a scrub may restart the pipeline. A held direction calls `seek(to:)` several times a
    /// second, and a trailing debounce alone issues nothing until the press stops — the dot ran ahead
    /// of a picture that never moved. One seek per this window keeps the video moving through a burst,
    /// and the trailing item still lands the final position, which is the one that matters.
    private static let burstSeekCadence: TimeInterval = 0.5

    /// When the last seek was issued, so a burst knows when it may restart the pipeline again.
    private var lastSeekIssuedAt = Date.distantPast

    /// Scrub to a position: leading edge while a burst is still going (see `burstSeekCadence`),
    /// trailing debounce otherwise, so a single press lands too.
    func seek(to time: TimeInterval) {
        pendingSeekWork?.cancel()
        // Assigned only when the value moved. Every one of these is @Published, and the clock tick
        // calls `refreshScrubState` ~4 Hz, so writing a value that already equals the current one
        // re-renders `DVRPlayerView` for nothing.
        if currentTime != time { currentTime = time }
        // Nothing has landed yet, so the still follows the press rather than the stale clock.
        if stillTime != time { stillTime = time }
        if !isScrubbing { isScrubbing = true }
        // Visible while presses are hot; the landing extends it (see `landedStillTail`).
        holdDisplayUntil = Date().addingTimeInterval(Self.previewWindow)

        let gap = Date().timeIntervalSince(lastSeekIssuedAt)
        if gap >= Self.burstSeekCadence {
            lastSeekIssuedAt = Date()
            performSeek(to: time)
            return
        }
        let work = DispatchWorkItem { [weak self] in self?.performSeek(to: time) }
        pendingSeekWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (Self.burstSeekCadence - gap), execute: work)
    }

    /// Re-point the scrub still: the requested position while a press's seek is outstanding, the
    /// engine's clock once it lands. Called on every clock tick, on every state change, and at the
    /// landing, so the hand-off happens on the value the landing publishes. Visibility is a separate
    /// question: the still stays up while presses are hot and for a short tail after a landing.
    private func refreshScrubState() {
        let scrubbing = Date() < holdDisplayUntil || pendingSeekWork != nil
        if scrubbing != isScrubbing { isScrubbing = scrubbing }
        let described = previewHot ? currentTime : engineTime
        if described != stillTime { stillTime = described }
    }

    func toggleCaptions() {
        captionsOn.toggle()
        Captions.enabled = captionsOn
        captions?.setOn(captionsOn)
    }

    // MARK: loading

    private func load(startPosition: TimeInterval?) {
        guard let engine, let entry else { return }
        guard let request = PlaybackRequest(TVHClient.sharedInstance.recordingURL(for: entry)) else {
            failure = "Could not build a playback URL for this recording."
            return
        }
        failure = nil
        isPlaying = true
        // A fresh session has its own axes: the previous session's origin must not carry over.
        stillProbeCancellation?.cancel()
        stillProbeCancellation = nil
        stillSourceOffset = nil
        heldSessionZero = nil
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            do {
                try await engine.load(url: request.url, startPosition: startPosition,
                                      options: LoadOptions(httpHeaders: request.headers))
                await self?.prepareStills()
            } catch is CancellationError {
                // Leaving the screen cancels the load.
            } catch {
                self?.failure = String(describing: error)
            }
        }
    }

    @MainActor
    private func prepareStills() async {
        guard let engine, extractor == nil, let ext = engine.makeFrameExtractor() else { return }
        // Learn the axis before the context is opened, then prewarm. A recording that starts at its
        // own PTS would otherwise answer every bucket with its first frame.
        let cancellation = ProbeCancellation()
        stillProbeCancellation = cancellation
        var origin: TimeInterval?
        for attempt in 1...3 {
            origin = await Self.probeSourceOrigin(extractor: ext, cancellation: cancellation)
            if origin != nil { break }
            EngineLog.emit("[ScrubStill] source axis origin probe \(attempt) failed")
        }
        await ext.prewarm()
        extractor = ext
        stillSourceOffset = origin
        if let origin {
            EngineLog.emit("[ScrubStill] source axis origin \(Int(origin))s")
        }
        thumbnails = ClientSideThumbnailProvider(extractor: ext, maxWidth: ScrubStillCell.decodeWidth) {
            [weak self] position in self?.sourceSeconds(for: position)
        }
    }

    /// The session zero the clock last paired against the picture, held across the window where the
    /// pair goes degenerate.
    ///
    /// Measured on the simulator, 2026-11-07, scrubbing this recording: while a press's seek is in
    /// flight the pair reads 88515.9s, and at the landing it collapses to 0 (`fill center=138.5s
    /// source=138.5s`), because the two clock fields are momentarily on the same axis. A zero asks the
    /// extractor for a position before the stream begins, which answers with the recording's first
    /// frame at every position: fills at 48.5/78.5/108.5 published one identical hash. It recovers a
    /// few hundred ms later on its own.
    ///
    /// The session zero is a property of the stream's timestamps, not of the seek, so a value already
    /// learned this session stays valid. It is never lowered: a reading below the held one is the
    /// collapse, not a new origin.
    private var heldSessionZero: TimeInterval?

    /// Which source-axis frame the session shows at a display position.
    ///
    /// The clock answers this directly: `clock.sourceTime` is the raw synchronizer clock in the source
    /// axis, `clock.currentTime` is session-relative, and the pair is published together, so their
    /// difference is the session zero — 88515.993s on this DVR recording. An origin read from a decoded
    /// frame is wrong by the head-of-stream offset: this recording's first DECODED frame is at
    /// 88518.574s, 2.58 s past the anchor, and every still decoded from that origin sat that far ahead
    /// of the picture the session was showing.
    ///
    /// `sourceTimeFollowsPicture` (AE#616) gates it: while the clock cannot prove the source time
    /// describes the rendered frame, fall back to the measured origin rather than aim at a guess. A
    /// zero is refused for the same reason, and nil means blank plus retry rather than a decode at 0.
    private func sourceSeconds(for position: TimeInterval) -> TimeInterval? {
        guard let engine else { return nil }
        let measured = engine.sourceTime - engine.clock.currentTime
        if engine.sourceTimeFollowsPicture, measured.isFinite, measured > 0,
           measured >= (heldSessionZero ?? 0) {
            heldSessionZero = measured
            return measured + position
        }
        // Either the clock cannot pair the two axes, or the pair went degenerate at a landing. Ride
        // what this session already proved, then the probe, then nothing.
        if let held = heldSessionZero { return held + position }
        return stillSourceOffset.map { position + $0 }
    }

    /// The measured fallback for a session whose clock cannot pair source time against the picture.
    ///
    /// It is a floor, not the answer: the frame decoded for 0 carries the PTS it came from, which is
    /// the first DECODED frame, not the clock's anchor — 2.58 s apart on this recording, which is most
    /// of the "still ahead of playback" error.
    ///
    /// Must run on a cold context: `boundedSnapshot` refuses one that is already open, which is why it
    /// fails on some sessions — the engine's own still path opens the context first.
    /// nil = the source states no timestamp, or the probe was refused; the provider then waits
    /// instead of decoding at 0.
    static func probeSourceOrigin(extractor: FrameExtractor, cancellation: ProbeCancellation,
                                  limits: ProbeLimits = ProbeLimits()) async -> TimeInterval? {
        let still = await extractor.boundedSnapshot(at: 0,
                                                    maxSize: CGSize(width: 160, height: 160),
                                                    limits: limits,
                                                    cancellation: cancellation)
        guard let seconds = still?.actualSeconds, seconds.isFinite, seconds >= 0 else { return nil }
        return seconds
    }

    private func performSeek(to time: TimeInterval) {
        guard let engine else { return }
        // The debounce item has run: `previewHot` must stop reading it, or the still would stay on the
        // requested position forever after the first scrub.
        pendingSeekWork = nil
        lastSeekTarget = time
        lastSeekAt = Date()
        seekClockBaseline = engineTime
        if engine.state == .ended {
            load(startPosition: time)
        } else {
            Task { await engine.seek(to: time) }
        }
    }

    // MARK: engine -> published state

    private func bind(_ engine: AetherEngine) {
        engine.$state
            .sink { [weak self] in self?.engineStateChanged($0) }
            .store(in: &cancellables)

        // The engine's clock ticks ~10 Hz; the scrubber needs far less.
        Publishers.CombineLatest(engine.clock.$currentTime, engine.$duration)
            .throttle(for: .milliseconds(250), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] time, engineDuration in self?.refreshClock(time: time, engineDuration: engineDuration) }
            .store(in: &cancellables)

        captions = AetherCaptionPresenter(engine: engine, isOn: captionsOn) { [weak self] in self?.captionText = $0 }
    }

    private func engineStateChanged(_ engineState: PlaybackState) {
        switch engineState {
        case .playing:
            isPlaying = true
            logLandingGap()
        case .paused, .ended:
            isPlaying = false
            logLandingGap()
        case .error(let message):
            failure = message
            isPlaying = false
        default: break
        }
        refreshScrubState()
    }

    /// Log the gap between what a scrub asked for and where the player landed, once the seek is over.
    /// The software host lands on the keyframe at or before the target, so this is the size of the
    /// error a preview still can never be asked to describe; it is measured, not eyeballed.
    /// The landing is the ground truth: drop the held requested position the moment it arrives, so the
    /// dot, the still's placement, and the still's picture all describe the frame the video is showing.
    /// Holding the requested position for a fixed 2 s is what left the still sitting seconds ahead of the
    /// picture while a held press's dot read the target the seek never reached.
    private func logLandingGap() {
        guard let target = lastSeekTarget else { return }
        lastSeekTarget = nil
        // Read the clock directly, not the throttled copy: the landing publishes synchronously, and a
        // 250 ms throttle would let this compare against a pre-seek value for a quarter second.
        let landed = max(engine?.clock.currentTime ?? engineTime, 0)
        EngineLog.emit("[ScrubStill] landing target=\(String(format: "%.1f", target))s "
                       + "clock=\(String(format: "%.1f", landed))s "
                       + "gap=\(String(format: "%.1f", target - landed))s")
        if engineTime != landed { engineTime = landed }
        if currentTime != landed { currentTime = landed }
        holdDisplayUntil = Date().addingTimeInterval(Self.landedStillTail)
        refreshScrubState()
    }

    private func refreshClock(time: Double, engineDuration: Double) {
        // The engine reads the real length from the file, padding included. Until it has, the
        // scheduled length stands in (it runs short of the file when the recording has padding).
        let scheduled = entry.map { max($0.stop.timeIntervalSince($0.start), 1) } ?? 0
        let resolvedDuration = engineDuration > 0 ? engineDuration : scheduled
        if resolvedDuration != duration { duration = resolvedDuration }
        let clock = max(time, 0)
        if clock != engineTime { engineTime = clock }
        // A clock that moved off the value the seek was issued against is the landing. State changes
        // report it too, but a seek issued while paused lands without one.
        if lastSeekTarget != nil,
           abs(engineTime - seekClockBaseline) > Self.landingClockMoveSeconds
           || Date().timeIntervalSince(lastSeekAt) > Self.stalledSeekTimeoutSeconds {
            logLandingGap()
        }
        if Date() >= holdDisplayUntil, currentTime != clock {
            currentTime = clock
        }
        refreshScrubState()
    }
}
