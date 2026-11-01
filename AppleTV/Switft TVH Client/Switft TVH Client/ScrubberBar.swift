// Sources/ScrubberBar.swift
import SwiftUI
import Combine

// Accumulates scrub presses into one running total ("-30s", "+1:10") that
// shows in a bubble above the dot and clears shortly after the last press.
final class ScrubFeedback: ObservableObject {
    @Published private(set) var delta: TimeInterval = 0
    @Published private(set) var visible = false
    private var work: DispatchWorkItem?
    private var lastPress = Date.distantPast
    private var lastDirection = 0

    /// A direction held down auto-repeats quickly; a repeat of the same
    /// direction within this window counts as "held" and scrubs by `held`
    /// seconds instead of `tap`.
    func step(direction: Int, tap: TimeInterval, held: TimeInterval) -> TimeInterval {
        let now = Date()
        let isHeld = direction == lastDirection && now.timeIntervalSince(lastPress) < 0.6
        lastDirection = direction
        lastPress = now
        return isHeld ? held : tap
    }

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
// guide's blue. tvOS has no touch input, so left/right skip by `step`.
struct ScrubberBar: View {
    let currentTime: TimeInterval
    let duration: TimeInterval
    let onSeek: (TimeInterval) -> Void
    var step: TimeInterval = 10
    var heldStep: TimeInterval = 30
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
        .onMoveCommand { direction in
            switch direction {
            case .left, .right:
                // If the reported length is unknown or stale (a recording still
                // being written), don't let it block forward scrubbing.
                let dir = direction == .left ? -1 : 1
                let amount = feedback.step(direction: dir, tap: step, held: heldStep)
                let limit = duration > currentTime ? duration : currentTime + amount
                let target = direction == .left ? max(currentTime - amount, 0) : min(currentTime + amount, limit)
                let moved = abs(target - currentTime)
                feedback.add(Double(dir) * min(amount, moved))
                onSeek(target)
            case .down: onDown()
            default: break
            }
        }
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
// Left/right moves the dot by `step` seconds.
struct LiveScrubberBar: View {
    let showStart: Date?
    let showStop: Date?
    let now: Date
    /// Scrubber space from the player: 0 = oldest buffered, duration = live edge.
    let currentTime: TimeInterval
    let duration: TimeInterval
    let isLive: Bool
    let onSeek: (TimeInterval) -> Void
    var step: TimeInterval = 10
    var heldStep: TimeInterval = 30
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
        .onMoveCommand { direction in
            let dir: Int
            switch direction {
            case .left: dir = -1
            case .right: dir = 1
            case .down: onDown(); return
            default: return
            }
            let amount = feedback.step(direction: dir, tap: step, held: heldStep)
            let target = currentWall.addingTimeInterval(Double(dir) * amount)
            let clamped = min(max(target, bufferStart), now)
            let moved = abs(clamped.timeIntervalSince(currentWall))
            feedback.add(Double(dir) * min(amount, moved))
            onSeek(clamped.timeIntervalSince(bufferStart))
        }
    }

    private static func clock(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }
}
