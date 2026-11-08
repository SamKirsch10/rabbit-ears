// AppleTV/Switft TVH Client/Switft TVH Client/Client/RemoteScrubRouter.swift
import AetherEngine
import SwiftUI
import UIKit

/// Remote and touch-surface input SwiftUI cannot see.
///
/// Both arrive at `RemoteScrubApplication.sendEvent`, ahead of the focus engine and SwiftUI. Measured on
/// the living-room Apple TV, 2026-11-07, while a SwiftUI view holds focus: `onMoveCommand` fires once per
/// press with no release, `onKeyPress` never fires for the remote, and `pressesBegan`-family overrides
/// see nothing. `sendEvent` sees a press's `.began` and `.ended`, and the pad's raw touches as a
/// continuous `.moved` stream. A window `UIPanGestureRecognizer` only ever reached `.began` on the same
/// pad, which made it look discrete; it isn't.
///
/// A held direction runs at a ramping rate until the release; a finger on the pad moves the playhead by
/// how far it travels.
///
/// One bar at a time. A bar attaches while it is focused and detaches otherwise, so a press on
/// another screen never scrubs anything.
@MainActor
final class RemoteScrubRouter {
    static let shared = RemoteScrubRouter()

    /// Where a held direction starts: 30 s per 0.6 s, what holding a press used to cost when every
    /// auto-repeat moved the dot a fixed step.
    private static let baseRate: TimeInterval = 30 / 0.6      // 50 s/s
    /// Doubling every `rampSeconds` until here. The ramp is what makes a hold fast without making a
    /// single click fast: crossing an hours-long recording takes tens of seconds of holding, not
    /// hundreds of presses.
    private static let maxRate: TimeInterval = 200
    private static let rampSeconds: TimeInterval = 0.8
    /// How often a run moves the position. Seeks are bounded separately, by the controller's cadence,
    /// so the dot can move faster than the pipeline restarts.
    private static let tickSeconds: TimeInterval = 0.2

    /// A click still has to move. This is what a single click cost before the run existed, so one press
    /// is unchanged.
    private static let tapFloor: TimeInterval = 10

    /// A press shorter than this is a click: the run moves nothing and `stopRun` tops it up to `tapFloor`.
    private static let clickGrace: TimeInterval = 0.35

    /// Seconds per point of finger travel. Measured on device, a full-pad swipe travels ~650-1200 pt, so
    /// one swipe moves ~1.5-3 min.
    private static let fingerSecondsPerPoint: TimeInterval = 0.15
    /// Travel before a finger is read as horizontal or vertical. A click or a resting thumb stays inside
    /// it, and a vertical swipe is focus navigation, so it must never scrub.
    private static let fingerDeadZone: CGFloat = 12
    /// How often tracked movement reaches the bar. The bar re-attaches on each position change, so
    /// flushing every touch would compute from a stale position and drop movement.
    private static let fingerFlushSeconds: TimeInterval = 0.08

    private var onTick: ((Int, TimeInterval) -> Void)?
    /// The bar's answer to a finger's travel: move the playhead by a signed number of seconds.
    private var onDrag: ((TimeInterval) -> Void)?

    /// Directions held right now. A second `.began` for a direction already held is ignored: the run is
    /// measured from elapsed time, so it does not move the dot twice as fast.
    private var held: Set<Int> = []
    private var runDirection = 0
    private var runStart: Date?
    private var lastTick = Date.distantPast
    private var runMoved: TimeInterval = 0
    private var pump: Task<Void, Never>?
    /// Every witness this router emits, read through the simulator's log stream.
    func log(_ line: String) {
        EngineLog.emit(line)
    }

    /// The bar claiming the remote. Both closures are the bar's own, because the bar owns its
    /// clamping: DVR clamps against the recording's length, live TV against the timeshift buffer.
    func attach(tick: @escaping (Int, TimeInterval) -> Void, drag: @escaping (TimeInterval) -> Void) {
        if onTick == nil { log("[RemoteScrub] attached") }
        onTick = tick
        onDrag = drag
    }

    /// Give up the remote. A bar that lost focus must not leave a run ticking behind it.
    func detach() {
        if onTick != nil { log("[RemoteScrub] detached") }
        stopRun()
        fingerPending = 0
        onTick = nil
        onDrag = nil
    }

    // MARK: held directions

    /// A direction went down. The bar does not move the dot on this call: the run below owns movement,
    /// so a press is never counted twice.
    func feed(_ direction: Int) {
        guard onTick != nil, !held.contains(direction) else { return }
        held.insert(direction)
        // The only witness on device: `simctl` cannot inject tvOS keys, so these lines are how a hold
        // is verified — that the press was seen, and how far the run moved.
        log("[RemoteScrub] hold dir=\(direction) began")
        // A hold in the opposite direction starts a fresh run rather than carrying momentum.
        if runDirection != direction {
            let now = Date()
            runDirection = direction
            runStart = now
            lastTick = now
            runMoved = 0
        }
        startPump()
    }

    /// The direction came up, or the press was cancelled.
    func release(_ direction: Int) {
        guard held.contains(direction) else { return }
        held.remove(direction)
        if held.isEmpty { stopRun() }
    }

    /// One pump per hold, ticking at `tickSeconds`. Task-based like the still pump, so the loop runs on
    /// the main actor. It ends on a release or on `detach`.
    private func startPump() {
        guard pump == nil else { return }
        pump = Task { [weak self] in
            while let self, !self.held.isEmpty {
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

    /// Ends a run, topping a short one up to a click's worth.
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

    // MARK: tracked finger

    private var fingerStart: CGPoint?
    private var fingerLast: CGPoint?
    private var fingerHorizontal: Bool?
    private var fingerSteps = 0
    private var fingerMoved: TimeInterval = 0
    private var fingerPending: TimeInterval = 0
    private var fingerFlush: Task<Void, Never>?

    /// One raw touch from the pad, so the playhead follows the finger. Deltas only: the first location
    /// is not where the finger landed on the pad. Ignored while a direction is held, so a thumb resting
    /// on the ring during a hold doesn't fight the run.
    func finger(_ phase: UITouch.Phase, at point: CGPoint) {
        switch phase {
        case .began:
            fingerStart = point
            fingerLast = point
            fingerHorizontal = nil
            fingerSteps = 0
            fingerMoved = 0
        case .moved:
            guard let start = fingerStart, let last = fingerLast else { return }
            fingerSteps += 1
            fingerLast = point
            guard let horizontal = fingerHorizontal else {
                let dx = abs(point.x - start.x), dy = abs(point.y - start.y)
                if max(dx, dy) > Self.fingerDeadZone { fingerHorizontal = dx >= dy }
                return
            }
            guard horizontal, held.isEmpty, onDrag != nil else { return }
            fingerPending += (point.x - last.x) * Self.fingerSecondsPerPoint
            scheduleFingerFlush()
        case .ended, .cancelled:
            flushFinger()
            if let start = fingerStart, let last = fingerLast, onDrag != nil {
                log("finger ended phase=\(phase.rawValue) steps=\(fingerSteps) dx=\(Int(last.x - start.x)) "
                    + "dy=\(Int(last.y - start.y)) moved=\(String(format: "%.0f", fingerMoved))s")
            }
            fingerStart = nil
            fingerLast = nil
        default:
            break
        }
    }

    private func scheduleFingerFlush() {
        guard fingerFlush == nil else { return }
        fingerFlush = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.fingerFlushSeconds))
            self?.flushFinger()
        }
    }

    private func flushFinger() {
        fingerFlush?.cancel()
        fingerFlush = nil
        let amount = fingerPending
        fingerPending = 0
        guard amount != 0, let onDrag else { return }
        fingerMoved += amount
        onDrag(amount)
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

/// Feeds the router from a raw press event.
@MainActor
private func routePresses(of event: UIEvent) {
    guard let event = event as? UIPressesEvent else { return }
    for press in event.allPresses {
        guard let direction = horizontalDirection(of: press) else { continue }
        switch press.phase {
        case .began: RemoteScrubRouter.shared.feed(direction)
        case .ended, .cancelled: RemoteScrubRouter.shared.release(direction)
        default: break
        }
    }
}

/// Hands the pad's raw touches to the router.
@MainActor
private func routeTouches(of event: UIEvent) {
    guard event.type == .touches,
          let touch = event.allTouches?.first(where: { $0.type == .indirect }) else { return }
    RemoteScrubRouter.shared.finger(touch.phase, at: touch.location(in: nil))
}

/// The app object, set as the principal class by `NSPrincipalClass` in Info.plist. `sendEvent` is where
/// presses and touches enter the app, ahead of the focus engine and SwiftUI (see `RemoteScrubRouter`).
/// Everything goes to `super`, so navigation and selection keep working.
final class RemoteScrubApplication: UIApplication {
    override func sendEvent(_ event: UIEvent) {
        routePresses(of: event)
        routeTouches(of: event)
        super.sendEvent(event)
    }
}
