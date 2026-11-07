// Sources/AetherLiveController.swift
//
// Live TV playback through AetherEngine (github.com/superuser404notfound/AetherEngine). It demuxes
// the tvheadend MPEG-TS stream with FFmpeg, decodes MPEG-2 in software (VideoToolbox has no MPEG-2
// decoder), deinterlaces, and draws through AVSampleBufferDisplayLayer with an
// AVSampleBufferAudioRenderer on a render synchronizer.
//
// It plays the plain HTTP stream: the engine's FFmpeg has no network stack and reads through
// URLSession. Timeshift is the engine's own client-side DVR window, not tvheadend's, and the
// banner's scrubber space maps onto it:
//   time     = seconds since the oldest buffered position
//   duration = size of the window, so duration - time = seconds behind live
import AetherEngine
import Combine
import CoreGraphics
import Foundation

enum LiveConnectionState: Equatable {
    case connecting
    case live
    case failed(String)
}

final class AetherLiveController: ObservableObject {
    /// nil only if the engine could not be created; `state` then carries the reason.
    let engine: AetherEngine?

    @Published private(set) var state: LiveConnectionState = .connecting
    @Published private(set) var isPlaying = false
    @Published private(set) var videoSize: CGSize = .zero
    /// Scrubber space: 0 = oldest buffered, duration = live edge.
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var isLive = true
    /// Set while paused so the banner can show a ticking "behind live" counter.
    @Published private(set) var pausedAt: Date?
    @Published private(set) var captionsOn = Captions.enabled
    /// The caption line to draw right now, if any.
    @Published private(set) var captionText: String?
    /// Seconds from `connect` to the first picture, for the stats overlay.
    @Published private(set) var firstFrameSeconds: TimeInterval?
    @Published private(set) var retunes = 0
    /// The window length when the pause began. The engine may or may not keep growing the window
    /// while paused, so the banner takes the larger of that and the wall-clock estimate.
    private(set) var durationAtPause: TimeInterval = 0

    var failure: String? {
        if case .failed(let message) = state { return message }
        return nil
    }

    // The DVR window the engine spools. Bounds disk use, not memory.
    private let dvrWindowSeconds = 600.0
    private let maxRetunes = 3

    private var channel: Channel?
    private var started = false
    private var loadStarted = Date()
    private var loadTask: Task<Void, Never>?
    private var pendingSeekWork: DispatchWorkItem?
    // After a scrub press, show the requested position instead of the player's (stale until the
    // seek lands) so held presses accumulate.
    private var holdDisplayUntil = Date.distantPast
    private var captions: AetherCaptionPresenter?
    private var cancellables = Set<AnyCancellable>()

    init() {
        var created: AetherEngine?
        var failure: String?
        do {
            created = try AetherEngine()
        } catch {
            failure = "Could not start AetherEngine: \(error)"
        }
        engine = created
        if let created { bind(created) }
        if let failure { state = .failed(failure) }
    }

    deinit { loadTask?.cancel() }

    // MARK: control

    func connect(channel: Channel) {
        guard !started else { return }
        started = true
        self.channel = channel
        retunes = 0
        load()
    }

    func disconnect() {
        started = false
        loadTask?.cancel()
        pendingSeekWork?.cancel()
        lastSeekIssuedAt = Date.distantPast
        engine?.stop()
    }

    func togglePlayPause() {
        guard let engine else { return }
        // Assigned, not toggled: pause()/play() publish the engine state synchronously, and the
        // state sink has already updated isPlaying by the time they return.
        if isPlaying {
            engine.pause()
            durationAtPause = duration
            pausedAt = Date()
            isPlaying = false
        } else {
            engine.play()
            pausedAt = nil
            isPlaying = true
        }
    }

    /// How often a scrub may restart the pipeline: a held direction calls `seek(to:)` several times a
    /// second, and a trailing debounce alone issues nothing until the press stops. Same contract as
    /// `AetherRecordingController.burstSeekCadence`.
    private static let burstSeekCadence: TimeInterval = 0.5
    private var lastSeekIssuedAt = Date.distantPast

    /// `time` is in scrubber space. Leading edge while a burst is still going, trailing debounce
    /// otherwise, so a single press lands and a held one keeps the picture moving.
    func seek(to time: TimeInterval) {
        pendingSeekWork?.cancel()
        currentTime = time
        holdDisplayUntil = Date().addingTimeInterval(2)

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

    func goLive() {
        guard let engine else { return }
        pendingSeekWork?.cancel()
        lastSeekIssuedAt = Date.distantPast
        holdDisplayUntil = .distantPast
        let wasPaused = pausedAt != nil || !isPlaying
        pausedAt = nil
        isPlaying = true
        Task {
            await engine.seekToLiveEdge()
            if wasPaused { engine.play() }
        }
    }

    func toggleCaptions() {
        captionsOn.toggle()
        Captions.enabled = captionsOn
        captions?.setOn(captionsOn)
    }

    // MARK: loading

    private func load() {
        guard let engine, let channel else { return }
        guard let request = PlaybackRequest(TVHClient.sharedInstance.streamURL(for: channel)) else {
            state = .failed("Could not build a stream URL for this channel.")
            return
        }
        state = .connecting
        firstFrameSeconds = nil
        loadStarted = Date()
        isPlaying = true
        pausedAt = nil
        let window = dvrWindowSeconds
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            do {
                try await engine.load(
                    url: request.url,
                    options: LoadOptions(httpHeaders: request.headers, isLive: true, dvrWindowSeconds: window))
            } catch is CancellationError {
                // Leaving the screen cancels the load.
            } catch {
                self?.state = .failed(String(describing: error))
            }
        }
    }

    /// The engine parks a live session it cannot revive, and only a fresh load recovers it. Bounded,
    /// or a permanently dead channel would turn into a retune loop.
    private func retune() {
        guard started else { return }
        guard retunes < maxRetunes else {
            state = .failed("Stream lost; retried \(maxRetunes) times.")
            return
        }
        retunes += 1
        load()
    }

    private func performSeek(to time: TimeInterval) {
        guard let engine else { return }
        // A seek while paused must also resume, otherwise nothing plays at the new position.
        let wasPaused = pausedAt != nil || !isPlaying
        pausedAt = nil
        isPlaying = true
        currentTime = time
        let lower = engine.clock.seekableLiveRange?.lowerBound ?? 0
        let nearLive = duration - time < 3
        Task {
            if nearLive {
                await engine.seekToLiveEdge()
            } else {
                await engine.seek(to: lower + time)
            }
            if wasPaused { engine.play() }
        }
    }

    // MARK: engine -> published state

    private func bind(_ engine: AetherEngine) {
        engine.$state
            .sink { [weak self] in self?.engineStateChanged($0) }
            .store(in: &cancellables)

        // The engine's clock ticks ~10 Hz; the scrubber and counters need far less.
        let clock = engine.clock
        Publishers.CombineLatest4(clock.$currentTime, clock.$seekableLiveRange, clock.$isAtLiveEdge, clock.$behindLiveSeconds)
            .throttle(for: .milliseconds(250), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] time, range, atEdge, _ in self?.refreshClock(time: time, range: range, atEdge: atEdge) }
            .store(in: &cancellables)

        Publishers.CombineLatest(engine.$sourceVideoWidth, engine.$sourceVideoHeight)
            .map { CGSize(width: Int($0), height: Int($1)) }
            .removeDuplicates()
            .sink { [weak self] in self?.videoSize = $0 }
            .store(in: &cancellables)

        engine.$hasFirstFrameReadyForDisplay
            .removeDuplicates()
            .sink { [weak self] ready in
                guard let self, ready, firstFrameSeconds == nil else { return }
                firstFrameSeconds = Date().timeIntervalSince(loadStarted)
                state = .live
            }
            .store(in: &cancellables)

        captions = AetherCaptionPresenter(engine: engine, isOn: captionsOn) { [weak self] in self?.captionText = $0 }

        engine.liveSourceReset
            .sink { [weak self] in self?.retune() }
            .store(in: &cancellables)
    }

    private func engineStateChanged(_ engineState: PlaybackState) {
        switch engineState {
        case .playing: isPlaying = true
        case .paused: isPlaying = false
        case .error(let message):
            state = .failed(message)
            isPlaying = false
        default: break
        }
    }

    private func refreshClock(time: Double, range: ClosedRange<Double>?, atEdge: Bool) {
        let lower = range?.lowerBound ?? 0
        let upper = range?.upperBound ?? max(time, 0)
        duration = max(upper - lower, 0)
        if Date() >= holdDisplayUntil {
            currentTime = min(max(time - lower, 0), duration)
        }
        isLive = pausedAt == nil && atEdge
    }
}
