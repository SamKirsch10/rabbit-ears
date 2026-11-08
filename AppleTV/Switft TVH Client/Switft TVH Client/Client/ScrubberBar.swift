// Sources/ScrubberBar.swift
import SwiftUI
import Combine

// Accumulates scrub presses into one running total ("-30s", "+1:10") that
// shows in a bubble above the dot and clears shortly after the last press.
final class ScrubFeedback: ObservableObject {
    @Published private(set) var delta: TimeInterval = 0
    @Published private(set) var visible = false
    private var work: DispatchWorkItem?

    /// Adds one press worth of movement. A press after the bubble has faded
    /// starts a fresh count.
    func add(_ seconds: TimeInterval) {
        guard abs(seconds) > 0.5 else { return }
        if !visible { delta = 0 }
        delta += seconds
        visible = true
        work?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.visible = false }
        work = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: w)
    }
}

/// What the remote attachment re-runs on: the values its closures read. A tuple cannot be a
/// `.task(id:)` payload — tuples do not conform to `Equatable` — so the inputs get a name.
private struct ScrubAttachment: Equatable {
    let focused: Bool
    let currentTime: TimeInterval
    let duration: TimeInterval
}

private struct LiveScrubAttachment: Equatable {
    let focused: Bool
    let currentTime: TimeInterval
    let duration: TimeInterval
    let now: Date
    let showStart: Date?
    let showStop: Date?
}

struct ScrubBubble: View {
    let delta: TimeInterval

    private var text: String {
        let total = Int(abs(delta).rounded())
        let sign = delta < 0 ? "-" : "+"
        if total < 60 { return "\(sign)\(total)s" }
        return String(format: "%@%d:%02d", sign, total / 60, total % 60)
    }

    var body: some View {
        Text(text)
            .font(.callout.weight(.bold))
            .monospacedDigit()
            .foregroundColor(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(Capsule().fill(guideAccent))
            .shadow(color: .black.opacity(0.5), radius: 4)
            .fixedSize()
            .frame(width: 110)
    }
}

// DVR scrubber: elapsed/total with a dot at the current position, in the
// guide's blue. A click skips 10 s, a held direction runs continuously, and a
// finger on the touch surface moves the dot as it travels, all through
// RemoteScrubRouter.
struct ScrubberBar: View {
    let currentTime: TimeInterval
    let duration: TimeInterval
    let onSeek: (TimeInterval) -> Void
    let isFocused: Bool
    let onDown: () -> Void
    @StateObject private var feedback = ScrubFeedback()

    private var progress: Double {
        guard duration > 0 else { return 0 }
        return min(max(currentTime / duration, 0), 1)
    }

    var body: some View {
        VStack(spacing: 10) {
            GeometryReader { geo in
                let w = geo.size.width
                let dot: CGFloat = isFocused ? 30 : 22
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.15))
                    Capsule().fill(guideAccent.opacity(0.7))
                        .frame(width: max(w * progress, 4))
                    Circle()
                        .fill(guideAccent)
                        .frame(width: dot, height: dot)
                        .shadow(color: .black.opacity(0.6), radius: 4)
                        .offset(x: min(max(w * progress - dot / 2, 0), w - dot))
                        .animation(.easeOut(duration: 0.2), value: isFocused)
                    ScrubBubble(delta: feedback.delta)
                        .opacity(feedback.visible ? 1 : 0)
                        .offset(x: min(max(w * progress - 55, 0), w - 110), y: -46)
                }
                .animation(.easeOut(duration: 0.25), value: feedback.visible)
                .frame(height: geo.size.height)
                .allowsHitTesting(false)
            }
            .frame(height: 30)

            HStack {
                Text(Self.formatted(currentTime))
                    .bold()
                Spacer()
                Text("-" + Self.formatted(max(duration - currentTime, 0)))
            }
            .font(.caption2)
            .foregroundColor(.secondary)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .stroke(guideAccent.opacity(isFocused ? 1 : 0), lineWidth: 3)
        )
        .focusable(true)
        // Only the focused bar holds the remote: a hidden banner's bar must not scrub, and a bar that
        // lost focus to the play button must not leave a run ticking behind it. Re-attach whenever the
        // values the closures read moves — the router keeps a closure between presses, and a struct's
        // closure captures the struct's *value*, so one attached at focus would scrub from the
        // position the bar had then and a run would never accumulate.
        .task(id: ScrubAttachment(focused: isFocused, currentTime: currentTime, duration: duration)) {
            if isFocused {
                RemoteScrubRouter.shared.attach(tick: { dir, amount in move(by: Double(dir) * amount) },
                                                drag: move(by:))
            } else {
                RemoteScrubRouter.shared.detach()
            }
        }
        .onDisappear { RemoteScrubRouter.shared.detach() }
        // Left and right scrub through RemoteScrubRouter, which sees them before SwiftUI does; only down
        // is acted on here.
        .onMoveCommand { direction in
            if direction == .down { onDown() }
        }
    }

    /// Move the dot by a signed amount and seek it. Forward keeps the stale-length guard: a recording
    /// still being written reports a short length, and that must not block scrubbing forward.
    private func move(by amount: TimeInterval) {
        let limit = duration > currentTime ? duration : currentTime + amount
        let target = amount >= 0 ? min(currentTime + amount, limit) : max(currentTime + amount, 0)
        feedback.add(amount)
        onSeek(target)
    }

    private static func formatted(_ time: TimeInterval) -> String {
        let total = max(Int(time), 0)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}

// Live-TV scrubber on the *show's* timeline: the track spans the program's
// start..stop in wall-clock time. The lighter segment is what the timeshift
// buffer holds (you can only scrub inside it), and the dot is where you are.
// Remote input works as on the DVR bar, through RemoteScrubRouter.
struct LiveScrubberBar: View {
    let showStart: Date?
    let showStop: Date?
    let now: Date
    /// Scrubber space from the player: 0 = oldest buffered, duration = live edge.
    let currentTime: TimeInterval
    let duration: TimeInterval
    let isLive: Bool
    let onSeek: (TimeInterval) -> Void
    let isFocused: Bool
    let onDown: () -> Void
    @StateObject private var feedback = ScrubFeedback()

    private var bufferStart: Date { now.addingTimeInterval(-duration) }
    private var currentWall: Date { bufferStart.addingTimeInterval(currentTime) }

    // Track range: the show, widened if the buffer reaches outside it
    // (e.g. rewound into the previous program) or the guide data is stale.
    private var rangeStart: Date { min(showStart ?? bufferStart, bufferStart) }
    private var rangeStop: Date { max(showStop ?? now, now) }

    private func fraction(_ date: Date) -> Double {
        let total = rangeStop.timeIntervalSince(rangeStart)
        guard total > 0 else { return 0 }
        return min(max(date.timeIntervalSince(rangeStart) / total, 0), 1)
    }

    var body: some View {
        VStack(spacing: 10) {
            GeometryReader { geo in
                let w = geo.size.width
                let bufX = w * fraction(bufferStart)
                let liveX = w * fraction(now)
                let dotX = w * fraction(currentWall)
                let dot: CGFloat = isFocused ? 30 : 22
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.15))
                    Capsule().fill(guideAccent.opacity(0.7))
                        .frame(width: max(liveX - bufX, 4))
                        .offset(x: bufX)
                    Circle()
                        .fill(guideAccent)
                        .frame(width: dot, height: dot)
                        .shadow(color: .black.opacity(0.6), radius: 4)
                        .offset(x: min(max(dotX - dot / 2, 0), w - dot))
                        .animation(.easeOut(duration: 0.2), value: isFocused)
                    ScrubBubble(delta: feedback.delta)
                        .opacity(feedback.visible ? 1 : 0)
                        .offset(x: min(max(dotX - 55, 0), w - 110), y: -46)
                }
                .animation(.easeOut(duration: 0.25), value: feedback.visible)
                .frame(height: geo.size.height)
                .allowsHitTesting(false)
            }
            .frame(height: 30)

            HStack {
                Text(Self.clock(rangeStart))
                Spacer()
                Text(isLive ? "" : Self.clock(currentWall))
                    .bold()
                Spacer()
                Text(Self.clock(rangeStop))
            }
            .font(.caption2)
            .foregroundColor(.secondary)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .stroke(guideAccent.opacity(isFocused ? 1 : 0), lineWidth: 3)
        )
        .focusable(true)
        // Same contract as `ScrubberBar`: only the focused bar holds the remote, and the closures are
        // re-attached whenever what they read moves. `now` ticks once a second, which also refreshes
        // the guide dates as they arrive.
        .task(id: LiveScrubAttachment(focused: isFocused, currentTime: currentTime,
                                      duration: duration, now: now,
                                      showStart: showStart, showStop: showStop)) {
            if isFocused {
                RemoteScrubRouter.shared.attach(tick: { dir, amount in move(by: Double(dir) * amount) },
                                                drag: move(by:))
            } else {
                RemoteScrubRouter.shared.detach()
            }
        }
        .onDisappear { RemoteScrubRouter.shared.detach() }
        // As on `ScrubberBar`: left and right scrub through RemoteScrubRouter.
        .onMoveCommand { direction in
            if direction == .down { onDown() }
        }
    }

    /// Move the dot by a signed amount and seek it. Only the buffered part is reachable, and the
    /// bubble reports what actually moved, not what was asked for.
    private func move(by amount: TimeInterval) {
        let target = currentWall.addingTimeInterval(amount)
        let clamped = min(max(target, bufferStart), now)
        let moved = min(abs(amount), abs(clamped.timeIntervalSince(currentWall)))
        feedback.add(amount < 0 ? -moved : moved)
        onSeek(clamped.timeIntervalSince(bufferStart))
    }

    private static func clock(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }
}
