// iOS/Recordings/RecordingPlayerView.swift
import SwiftUI
import AetherEngine

// Recording playback with the live player's banner: tap the video to show or hide it. It hides
// after 5 seconds while playing, and stays up while paused or scrubbing.
struct RecordingPlayerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    let entry: DVR.Entry
    @StateObject private var playback = AetherRecordingController()
    @StateObject private var pip = PictureInPicture()
    @State private var showControls = true
    // Measured, so captions can sit above the banner while it's up.
    @State private var bannerHeight: CGFloat = 0
    @State private var isScrubbing = false
    @State private var hideTask: DispatchWorkItem?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let engine = playback.engine {
                AetherPlayerSurface(engine: engine)
                    .ignoresSafeArea()
            }

            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { toggleControls() }
                .ignoresSafeArea()

            CaptionOverlay(text: playback.captionText, bottomClearance: showControls ? bannerHeight : 0)

            PlaybackFailureOverlay(message: playback.failure)

            if showControls {
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    banner
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { bannerHeight = $0 }
                }
                .foregroundStyle(.white)
                .transition(.opacity)
            }
        }
        .overlay(alignment: .topTrailing) {
            if showControls {
                playerPiPCorner(pip) { interact(); pip.toggle() }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: showControls)
        .statusBarHidden(!showControls)
        .persistentSystemOverlays(showControls ? .automatic : .hidden)
        .onAppear {
            // Nothing else keeps the screen awake: the picture is a sample-buffer layer, not an AVPlayer.
            UIApplication.shared.isIdleTimerDisabled = true
            if let engine = playback.engine { pip.bind(engine) }
            playback.connect(entry: entry)
            scheduleHide()
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            hideTask?.cancel()
            pip.unbind()
            playback.disconnect()
        }
        .onChange(of: playback.isPlaying) { _, _ in scheduleHide() }
        .onChange(of: isScrubbing) { _, _ in scheduleHide() }
        .onChange(of: playback.failure) { _, failure in
            if failure != nil { interact() }
        }
    }

    // iPhone in landscape: little height to spare.
    private var isCompactHeight: Bool { verticalSizeClass == .compact }

    private var banner: some View {
        VStack(alignment: .leading, spacing: isCompactHeight ? 8 : 14) {
            RecordingScrubber(
                currentTime: playback.currentTime,
                duration: playback.duration,
                isScrubbing: $isScrubbing,
                onSeek: { time in interact(); playback.seek(to: time) }
            )

            if isCompactHeight {
                // The buttons share the info line so the banner covers less of the picture.
                HStack(alignment: .center, spacing: 12) {
                    info
                    Spacer(minLength: 8)
                    buttonRow
                        .fixedSize()
                }
            } else {
                info
                buttonRow
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, isCompactHeight ? 10 : 14)
        .padding(.bottom, 8)
        .playerBannerBackground()
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(entry.title)
                .font(.headline)
                .lineLimit(1)
            Text(entry.start.formatted(date: .abbreviated, time: .shortened))
                .font(.caption.weight(.semibold))
                .foregroundStyle(guideAccent)
            if !entry.description.isEmpty && !isCompactHeight {
                Text(entry.description)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(2)
            }
        }
    }

    private var buttonRow: some View {
        HStack(spacing: 8) {
            Button { interact(); playback.togglePlayPause() } label: {
                Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
            }
            .buttonStyle(PlayerIconButtonStyle())
            .accessibilityLabel(playback.isPlaying ? "Pause" : "Play")

            Button { interact(); skip(by: -10) } label: {
                Image(systemName: "gobackward.10")
            }
            .buttonStyle(PlayerIconButtonStyle())
            .accessibilityLabel("Back 10 seconds")

            Button { interact(); skip(by: 30) } label: {
                Image(systemName: "goforward.30")
            }
            .buttonStyle(PlayerIconButtonStyle())
            .accessibilityLabel("Forward 30 seconds")

            Button { interact(); playback.toggleCaptions() } label: {
                Image(systemName: playback.captionsOn ? "captions.bubble.fill" : "captions.bubble")
            }
            .buttonStyle(PlayerIconButtonStyle(tint: playback.captionsOn ? guideAccent : nil))
            .accessibilityLabel(playback.captionsOn ? "Turn off captions" : "Turn on captions")

            Spacer(minLength: 0)

            Button { dismiss() } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(PlayerIconButtonStyle())
            .accessibilityLabel("Close")
        }
    }

    private func skip(by seconds: TimeInterval) {
        // If the reported length is unknown or stale, don't let it block skipping forward.
        let limit = playback.duration > playback.currentTime ? playback.duration : playback.currentTime + seconds
        playback.seek(to: min(max(playback.currentTime + seconds, 0), limit))
    }

    // MARK: controls visibility

    private func toggleControls() {
        if showControls {
            hideTask?.cancel()
            showControls = false
        } else {
            interact()
        }
    }

    private func interact() {
        showControls = true
        scheduleHide()
    }

    private func scheduleHide() {
        hideTask?.cancel()
        // Stays up while paused, scrubbing, or showing a failure (Close must stay in reach).
        guard showControls, playback.isPlaying, !isScrubbing, playback.failure == nil else { return }
        let task = DispatchWorkItem { showControls = false }
        hideTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: task)
    }
}

// Elapsed/remaining scrubber, as on tvOS. Drag anywhere on the track; the seek happens on release.
private struct RecordingScrubber: View {
    let currentTime: TimeInterval
    let duration: TimeInterval
    @Binding var isScrubbing: Bool
    let onSeek: (TimeInterval) -> Void
    /// Position under the finger while dragging.
    @State private var dragTime: TimeInterval?

    private var shownTime: TimeInterval { dragTime ?? currentTime }

    private var progress: Double {
        guard duration > 0 else { return 0 }
        return min(max(shownTime / duration, 0), 1)
    }

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { geo in
                let w = geo.size.width
                let dot: CGFloat = dragTime == nil ? 14 : 22
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.2))
                        .frame(height: 4)
                    Capsule().fill(guideAccent.opacity(0.7))
                        .frame(width: max(w * progress, 4), height: 4)
                    Circle()
                        .fill(guideAccent)
                        .frame(width: dot, height: dot)
                        .shadow(color: .black.opacity(0.6), radius: 4)
                        .offset(x: min(max(w * progress - dot / 2, 0), w - dot))
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard duration > 0 else { return }
                            isScrubbing = true
                            dragTime = duration * min(max(value.location.x / max(w, 1), 0), 1)
                        }
                        .onEnded { _ in
                            if let dragTime { onSeek(dragTime) }
                            dragTime = nil
                            isScrubbing = false
                        }
                )
                .animation(.easeOut(duration: 0.15), value: dragTime == nil)
            }
            .frame(height: 28)

            HStack {
                Text(Self.formatted(shownTime))
                    .bold()
                    .foregroundStyle(.white)
                Spacer()
                Text("-" + Self.formatted(max(duration - shownTime, 0)))
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.white.opacity(0.6))
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
