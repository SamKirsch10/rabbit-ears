// AppleTV/Switft TVH Client/Switft TVH Client/Client/RemoteScrubRouter.swift
import AetherEngine
import SwiftUI
import UIKit

/// Remote and touch-surface input SwiftUI cannot see directly.
///
/// A held right arrow used to move the dot one step and stop, and a swipe of the touch surface did
/// nothing at all. The two inputs are captured at different places because they arrive at different
/// places: presses at `sendEvent`, ahead of SwiftUI (`onMoveCommand` fires once per press with no
/// release, and `onKeyPress` never fires for the remote — both measured on device), and pad swipes at a
/// gesture recognizer on `RemoteScrubWindow` (no SwiftUI view on tvOS is touch-addressable).
///
/// The pad is discrete — see `swipe` for what that means on device — so a swipe moves the playhead by
/// its own displacement rather than aiming at a position on the bar.
///
/// One bar at a time. A bar attaches while it is focused and detaches otherwise, so a press on
/// another screen never scrubs anything.
@MainActor
final class RemoteScrubRouter {
    static let shared = RemoteScrubRouter()

    /// Where a held direction starts: `heldStep` per the held window (`ScrubFeedback.step`'s 0.6 s),
    /// which is what a repeated press already cost.
    private static let baseRate: TimeInterval = 30 / 0.6      // 50 s/s
    /// Doubling every `rampSeconds` until here. The ramp is what makes a hold fast without making a
    /// single click fast: crossing an hours-long recording takes tens of seconds of holding, not
    /// hundreds of presses.
    private static let maxRate: TimeInterval = 200
    private static let rampSeconds: TimeInterval = 0.8
    /// How often a run moves the position. Seeks are bounded separately, by the controller's cadence,
    /// so the dot can move faster than the pipeline restarts.
    private static let tickSeconds: TimeInterval = 0.2

    /// A hold shorter than one tick still has to move. This is what a single click cost before the
    /// run existed, so one press is unchanged.
    private static let tapFloor: TimeInterval = 10

    /// How long a run keeps going after the last event, for `onMoveCommand` only: it reports no release,
    /// so this gap stands in for one. A source that reports a release is never timed out.
    private static let holdIdle: TimeInterval = 0.6

    /// A press shorter than this is a click: the run moves nothing and `stopRun` tops it up to `tapFloor`.
    private static let clickGrace: TimeInterval = 0.35

    /// Seconds a swipe moves per point the finger travelled. Measured on the living-room box, 2026-11-07:
    /// swipes travel ~10-210 pt, median ~100. At 0.25 s/pt a typical swipe moved ~25 s (too small to
    /// cross anything); a fraction of the bar moved ~420 s on an hours-long recording (far too large).
    /// 0.4 lands a typical swipe near 40 s — surgical enough to land inside a minute of where you aimed,
    /// and a dozen swipes still crosses a two-hour recording.
    private static let swipeSecondsPerPoint: TimeInterval = 0.4
    /// A swipe with no reported displacement still moves this much — one click, never nothing.
    private static let swipeFloor: TimeInterval = 15
    /// A fast flick must not land at the far end of the recording in one gesture.
    private static let swipeCap: TimeInterval = 120

    private var onTick: ((Int, TimeInterval) -> Void)?
    private var onDrag: ((Double) -> Void)?
    /// The bar's answer to one discrete swipe: move the playhead by a signed number of seconds.
    private var onDragDelta: ((TimeInterval) -> Void)?
    /// The bar's rect in window coordinates, reported by `RemoteBarFrameProbe`. What turns a
    /// touch-surface position into a fraction of the bar; nil until a bar has reported one, which
    /// leaves drags ignored.
    private var barRect: CGRect?

    /// Directions held right now. A repeat of a direction already held is ignored: the run is
    /// measured from elapsed time, so a remote that auto-repeats does not move the dot twice as fast.
    private var held: Set<Int> = []
    private var runDirection = 0
    private var runStart: Date?
    private var lastTick = Date.distantPast
    private var runMoved: TimeInterval = 0
    private var pump: Task<Void, Never>?
    /// When the last press event arrived. The watchdog ends a run when this goes stale, for as long as
    /// `onMoveCommand` is the only source.
    private var lastEventAt = Date.distantPast

    /// Per-direction witnesses, so the trace says whether presses arrive at all, how far apart a held
    /// direction repeats, and where they were seen. Flooding a trace is what makes it unreadable, so a
    /// repeat inside `pressLogGap` is not logged; the run's own `moved` line carries the accumulation.
    private var lastPressLogged: [Int: Date] = [:]
    private var lastPressAt: [Int: Date] = [:]
    private static let pressLogGap: TimeInterval = 0.3

    /// Every witness this router and its window emit. The simulator is read through the log stream;
    /// a real Apple TV cannot be streamed from the Mac, so the same lines also go to `ScrubTrace` and
    /// are pulled out of the app's container afterwards.
    func log(_ line: String) {
        EngineLog.emit(line)
        ScrubTrace.record(line)
    }

    /// The bar claiming the remote. Both closures are the bar's own, because the bar owns its
    /// clamping: DVR clamps against the recording's length, live TV against the timeshift buffer.
    func attach(tick: @escaping (Int, TimeInterval) -> Void,
                drag: @escaping (Double) -> Void,
                dragDelta: @escaping (TimeInterval) -> Void) {
        if onTick == nil { log("[RemoteScrub] attached") }
        onTick = tick
        onDrag = drag
        onDragDelta = dragDelta
    }

    /// Give up the remote. A bar that lost focus must not leave a run ticking behind it.
    func detach() {
        if onTick != nil { log("[RemoteScrub] detached") }
        stopRun()
        onTick = nil
        onDrag = nil
        onDragDelta = nil
    }

    func reportRect(_ rect: CGRect) {
        if barRect != rect { log("[RemoteScrub] bar rect \(Int(rect.minX))..\(Int(rect.maxX)) w=\(Int(rect.width))") }
        barRect = rect
    }

    // MARK: held directions

    /// Whether `sendEvent` has delivered a press. It reports a real press and release, so once it has,
    /// `onMoveCommand` is a witness only — both driving the run would count one click twice — and the
    /// watchdog stands down. `sendEvent` runs first, so the first press is already covered.
    private var eventSeen = false

    /// One press of a direction, from whichever capture point saw it: `app` or `window` (`sendEvent`), or
    /// `move` (`onMoveCommand`). `app` and `window` see the same press, and the second is a no-op because
    /// the direction is already held.
    ///
    /// The bar does not move the dot on this call: the run below owns movement, so a press is never
    /// counted twice.
    func feed(_ direction: Int, from source: String) {
        pressSeen(direction, at: source)
        if source != "move" { eventSeen = true }
        guard source != "move" || !eventSeen else { return }
        guard onTick != nil else {
            if !held.contains(direction) {
                log("\(direction > 0 ? "right" : "left") press from \(source), no bar")
            }
            return
        }
        let now = Date()
        lastEventAt = now
        guard !held.contains(direction) else { return }
        held.insert(direction)
        // The only witness on device: `simctl` cannot inject tvOS keys, so these lines are how a hold
        // is verified — that the press was seen, and how far the run moved.
        log("[RemoteScrub] hold dir=\(direction) began from \(source)")
        // A hold in the opposite direction starts a fresh run rather than carrying momentum.
        if runDirection != direction {
            runDirection = direction
            runStart = now
            lastTick = now
            runMoved = 0
        }
        startPump()
    }

    /// The finger lifted, as `sendEvent` reports it. `onMoveCommand` never calls this; the watchdog
    /// covers it.
    func release(_ direction: Int, from source: String) {
        pressSeen(direction, at: "\(source) end")
        guard held.contains(direction) else { return }
        held.remove(direction)
        if held.isEmpty { stopRun() }
    }

    /// A directional press, logged whether or not a bar holds the remote — "no press lines" is the
    /// finding worth having, meaning the capture point is wrong rather than the tuning. Repeats inside
    /// `pressLogGap` are dropped so a hold doesn't flood the file; the gap between the lines that do
    /// land is what shows whether UIKit delivers repeats while a direction is held, and at which point.
    private func pressSeen(_ direction: Int, at source: String) {
        let now = Date()
        defer { lastPressAt[direction] = now }
        guard now.timeIntervalSince(lastPressLogged[direction] ?? .distantPast) > Self.pressLogGap else { return }
        lastPressLogged[direction] = now
        let gap = lastPressAt[direction].map { " gap=\(String(format: "%.2f", now.timeIntervalSince($0)))s" } ?? ""
        log("\(direction > 0 ? "right" : "left") press at \(source)\(gap)")
    }

    /// One pump per hold, ticking at `tickSeconds`. Task-based like the still pump, so the loop runs on
    /// the main actor. It ends on a release, on the watchdog when only `onMoveCommand` is reporting, or
    /// on `detach`.
    private func startPump() {
        guard pump == nil else { return }
        pump = Task { [weak self] in
            while let self, !self.held.isEmpty {
                if !self.eventSeen, Date().timeIntervalSince(self.lastEventAt) > Self.holdIdle {
                    self.stopRun()   // the finger lifted; no release event ever came
                    break
                }
                self.tick()
                try? await Task.sleep(for: .seconds(Self.tickSeconds))
            }
            self?.pump = nil
        }
    }

    private func tick() {
        guard !held.isEmpty, let start = runStart, let onTick else { return }
        let now = Date()
        // Below the grace this may still be a click. `lastTick` advances anyway, or the first real tick
        // would pay for the whole grace and a click would cost far more than `tapFloor`.
        guard now.timeIntervalSince(start) > Self.clickGrace else { lastTick = now; return }
        let delta = Self.rate(since: now.timeIntervalSince(start)) * now.timeIntervalSince(lastTick)
        lastTick = now
        runMoved += delta
        if delta > 0 { onTick(runDirection, delta) }
    }

    /// Ends a run, topping a short one up to a click's worth so a swipe still moves like a click.
    private func stopRun() {
        pump?.cancel()
        pump = nil
        if runDirection != 0 {
            let heldFor = runStart.map { Date().timeIntervalSince($0) } ?? 0
            log("[RemoteScrub] hold dir=\(runDirection) ended "
                           + "moved=\(String(format: "%.0f", runMoved))s "
                           + "rate=\(String(format: "%.0f", Self.rate(since: heldFor)))s/s")
            if let onTick {
                let shortfall = Self.tapFloor - runMoved
                if shortfall > 0 { onTick(runDirection, shortfall) }
            }
        }
        held.remove(runDirection)
        runDirection = 0
        runStart = nil
        runMoved = 0
        lastTick = Date.distantPast
    }

    /// How fast a hold is moving at `hold` seconds into it.
    private static func rate(since hold: TimeInterval) -> TimeInterval {
        min(baseRate * pow(2, hold / rampSeconds), maxRate)
    }

    // MARK: drags

    /// A finger dragged across the touch surface. Horizontal only: a vertical swipe is focus
    /// navigation, and reading it as a drag would move the playhead to wherever the finger drifted in
    /// x. The position is absolute — the fraction of the bar under the finger — which is what
    /// "swipe to the point I want" means.
    ///
    /// The point has to be near the bar, not anywhere on the screen: the touch surface maps to the
    /// whole screen, and a swipe over the video would otherwise clamp to an end and jump the playhead
    /// to 0 or the length.
    /// `ended` is the gesture's phase, for one log line per drag rather than one per finger update.
    func drag(at point: CGPoint, translation: CGPoint, ended: Bool) {
        guard let rect = barRect, let onDrag else { return }
        guard abs(translation.x) > abs(translation.y), abs(translation.x) > 12 else { return }
        guard rect.insetBy(dx: -40, dy: -60).contains(point) else { return }
        let fraction = min(max((point.x - rect.minX) / max(rect.width, 1), 0), 1)
        if ended {
            log("[RemoteScrub] drag fraction=\(String(format: "%.2f", fraction)) "
                           + "x=\(String(format: "%.0f", point.x)) bar=\(String(format: "%.0f", rect.minX))"
                           + "..\(String(format: "%.0f", rect.maxX))")
        }
        onDrag(fraction)
    }

    /// One swipe on the touch surface, moved as a signed number of seconds.
    ///
    /// The pad is discrete. Measured on the living-room Apple TV, 2026-11-07: `pan began` repeats about
    /// every 0.4 s and a `.changed` never arrives, because UIKit turns each swipe into a directional
    /// press rather than handing a finger path to the recognizer. So there is no position to map onto
    /// the bar — a swipe moves *by* its displacement, and repeated swipes accumulate.
    ///
    /// Seconds per point, not a fraction of the track: a fraction of a bar over an hours-long recording
    /// is a jump of hundreds of seconds, which is the opposite of surgical. Seconds scale with the
    /// gesture instead of the recording.
    ///
    /// Displacement is preferred, velocity is the fallback: some swipes are recognized before UIKit
    /// reports any translation, and a flick with none would otherwise be dropped.
    func swipe(dx: CGFloat, dy: CGFloat, vx: CGFloat, vy: CGFloat) {
        guard let onDragDelta else { return }
        let horizontal: CGFloat
        if abs(dx) >= abs(dy), abs(dx) > 8 {
            horizontal = dx
        } else if abs(vx) >= abs(vy), abs(vx) > 30 {
            horizontal = vx
        } else {
            return   // a vertical swipe is focus navigation, not a scrub
        }
        let seconds = max(abs(horizontal) * Self.swipeSecondsPerPoint, Self.swipeFloor)
        let moved = min(seconds, Self.swipeCap) * (horizontal < 0 ? -1 : 1)
        log("swipe dx=\(Int(dx)) dy=\(Int(dy)) vx=\(String(format: "%.0f", vx)) "
            + "moved=\(String(format: "%.0f", moved))s")
        onDragDelta(moved)
    }
}

/// The scrub lines, written to the app's own container.
///
/// A real Apple TV's log stream cannot be read from the Mac — there is no console path to a box on the
/// network — so the same lines that `os_log` gives the simulator are appended here and pulled back with:
///
///   xcrun devicectl device copy from --device <udid> --domain-type appDataContainer \
///     --domain-identifier site.kirsch.Switft-TVH-Client --source tmp/scrub-trace.log \
///     --destination /tmp/scrub-trace.log
///
/// `tmp` rather than `Documents`: the engine already writes its DVR segments there, so that directory is
/// proven writable and readable through devicectl on this box. Documents came back empty even for a
/// launch marker, so the first version of this never landed.
///
/// Append rather than rewrite per line: a hold emits ~10 lines a second and rewriting the file each time
/// is what a trace should not cost. The file is capped so weeks of use never grow it.
enum ScrubTrace {
    private static let name = "scrub-trace.log"
    private static let directories: [URL?] = [
        FileManager.default.temporaryDirectory,
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
    ]
    private static let cap = 128 * 1024
    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    /// The directory that accepted the first line; later lines go to the same place rather than
    /// re-testing every candidate ~10 times a second during a hold.
    private static var chosen: URL?

    static func record(_ line: String) {
        let data = Data("\(stamp.string(from: Date())) \(line)\n".utf8)
        if let url = chosen { append(data, to: url); return }
        for directory in directories {
            guard let directory else { continue }
            let url = directory.appendingPathComponent(name)
            if append(data, to: url) {
                chosen = url
                record("trace at \(url.path)")
                return
            }
        }
    }

    /// Appends, creating the file if it is not there yet. Returns whether the line landed — a false
    /// answer is what makes the next candidate directory worth trying.
    @discardableResult
    private static func append(_ data: Data, to url: URL) -> Bool {
        if let size = try? Data(contentsOf: url), size.count > cap {
            return (try? data.write(to: url)) != nil   // restart rather than grow it forever
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
            return true
        }
        return (try? data.write(to: url)) != nil       // first line creates the file
    }
}

/// The tvOS window. It exists to read the remote and the touch surface that SwiftUI does not expose:
/// presses while a direction is held, and a finger dragged across the touchpad. Everything goes to
/// `super`, so focus navigation and selection keep working untouched.
final class RemoteScrubWindow: UIWindow {
    /// The touch surface is a trackpad and no SwiftUI view is touch-addressable, so the recognizer
    /// belongs on the window. `cancelsTouchesInView = false` keeps the click pad selecting the
    /// focused control.
    private lazy var pan: UIPanGestureRecognizer = {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(dragged(_:)))
        pan.cancelsTouchesInView = false
        // The touch surface is `.indirect` touch, and a recognizer accepts `.direct` only by default.
        // That default is why a swipe across the pad was never seen. The simulator's mouse is
        // `.direct`, so both are allowed rather than guessing which surface the touch came from.
        pan.allowedTouchTypes = [
            NSNumber(value: UITouch.TouchType.indirect.rawValue),
            NSNumber(value: UITouch.TouchType.direct.rawValue),
        ]
        return pan
    }()

    // No `init(frame:)`: it is deprecated in tvOS 26, and this window is always built from a scene.
    override init(windowScene: UIWindowScene) {
        super.init(windowScene: windowScene)
        addGestureRecognizer(pan)
        ScrubTrace.record("window built, pan attached")
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        addGestureRecognizer(pan)
        ScrubTrace.record("window decoded, pan attached")
    }

    /// `.began` is where the pad's discrete swipe lands — see `RemoteScrubRouter.swipe` for why the
    /// absolute path below never runs on a real Apple TV. It stays for a touch source that does report
    /// a continuous finger, which is what iOS's drag gesture does.
    @objc private func dragged(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            let translation = gesture.translation(in: nil)
            let velocity = gesture.velocity(in: nil)
            RemoteScrubRouter.shared.swipe(dx: translation.x, dy: translation.y,
                                           vx: velocity.x, vy: velocity.y)
        case .changed, .ended:
            RemoteScrubRouter.shared.drag(at: gesture.location(in: nil),
                                          translation: gesture.translation(in: nil),
                                          ended: gesture.state == .ended)
        default:
            break
        }
    }

    override func sendEvent(_ event: UIEvent) {
        routePresses(of: event, at: "window")
        super.sendEvent(event)
    }
}

/// -1 / +1 for left and right, nil for everything else. Up and down stay focus navigation, and menu,
/// select and playPause keep going to SwiftUI.
private func horizontalDirection(of press: UIPress) -> Int? {
    switch press.type {
    case .leftArrow: return -1
    case .rightArrow: return 1
    default: return nil
    }
}

/// Feeds the router from a raw press event. Every phase is logged, unthrottled: a press is a few events,
/// and these lines are what shows which capture point sees the press and whether the release arrives.
@MainActor
private func routePresses(of event: UIEvent, at source: String) {
    guard let event = event as? UIPressesEvent else { return }
    for press in event.allPresses {
        guard let direction = horizontalDirection(of: press) else { continue }
        RemoteScrubRouter.shared.log("\(source) press dir=\(direction) phase=\(press.phase.rawValue)")
        switch press.phase {
        case .began: RemoteScrubRouter.shared.feed(direction, from: source)
        case .ended, .cancelled: RemoteScrubRouter.shared.release(direction, from: source)
        default: break
        }
    }
}

/// The app object, set as the principal class by `NSPrincipalClass` in Info.plist. `sendEvent` is where
/// a press enters the app, ahead of the focus engine and SwiftUI, which is why it can see a press and a
/// release that no `pressesBegan` override does while the scrubber holds focus. Everything goes to
/// `super`, so navigation and selection keep working.
final class RemoteScrubApplication: UIApplication {
    override init() {
        super.init()
        ScrubTrace.record("principal class installed")
    }

    override func sendEvent(_ event: UIEvent) {
        routePresses(of: event, at: "app")
        super.sendEvent(event)
    }
}

/// The bar's rect in window coordinates, which SwiftUI never hands a view. A drag needs it to turn a
/// touch-surface position into a fraction of the bar. The view is inert — no interaction, and the
/// SwiftUI side keeps hit testing off it — and it reports on layout, so a banner that moves or resizes
/// is never scrubbed against a stale rect.
struct RemoteBarFrameProbe: UIViewRepresentable {
    let onChange: (CGRect) -> Void

    func makeUIView(context: Context) -> BarFrameView { BarFrameView(onChange: onChange) }
    func updateUIView(_ uiView: BarFrameView, context: Context) { uiView.onChange = onChange }
}

final class BarFrameView: UIView {
    var onChange: (CGRect) -> Void

    init(onChange: @escaping (CGRect) -> Void) {
        self.onChange = onChange
        super.init(frame: .zero)
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let window, frame.width > 0 else { return }
        onChange(convert(bounds, to: window))
    }
}
