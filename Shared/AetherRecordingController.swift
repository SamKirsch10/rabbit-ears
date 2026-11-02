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
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var captionsOn = Captions.enabled
    /// The caption line to draw right now, if any.
    @Published private(set) var captionText: String?
    @Published private(set) var failure: String?

    private var entry: DVR.Entry?
    private var started = false
    private var loadTask: Task<Void, Never>?
    private var pendingSeekWork: DispatchWorkItem?
    // After a scrub press, show the requested position instead of the player's (stale until the
    // seek lands) so held presses accumulate.
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

    /// Debounced so a held remote direction coalesces into one seek.
    func seek(to time: TimeInterval) {
        pendingSeekWork?.cancel()
        currentTime = time
        holdDisplayUntil = Date().addingTimeInterval(2)
        let work = DispatchWorkItem { [weak self] in self?.performSeek(to: time) }
        pendingSeekWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
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
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            do {
                try await engine.load(url: request.url, startPosition: startPosition,
                                      options: LoadOptions(httpHeaders: request.headers))
            } catch is CancellationError {
                // Leaving the screen cancels the load.
            } catch {
                self?.failure = String(describing: error)
            }
        }
    }

    private func performSeek(to time: TimeInterval) {
        guard let engine else { return }
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
        case .playing: isPlaying = true
        case .paused, .ended: isPlaying = false
        case .error(let message):
            failure = message
            isPlaying = false
        default: break
        }
    }

    private func refreshClock(time: Double, engineDuration: Double) {
        // The engine reads the real length from the file, padding included. Until it has, the
        // scheduled length stands in (it runs short of the file when the recording has padding).
        let scheduled = entry.map { max($0.stop.timeIntervalSince($0.start), 1) } ?? 0
        duration = engineDuration > 0 ? engineDuration : scheduled
        if Date() >= holdDisplayUntil {
            currentTime = max(time, 0)
        }
    }
}
