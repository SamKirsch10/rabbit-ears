// Sources/DVRPlayerView.swift
import AetherEngine
import SwiftUI

// Same remote/focus behaviour as the live banner: the banner appears on any
// press with the scrubber focused; left/right scrub; down goes to the play
// button; down again hides the banner; an invisible holder keeps the remote
// delivering presses while the banner is hidden.
struct DVRPlayerView: View {
    @Environment(\.dismiss) private var dismiss
    let entry: DVR.Entry
    @StateObject private var playback = AetherRecordingController()
    @State private var showBanner = true
    // Measured, so captions can sit above the banner while it's up.
    @State private var bannerHeight: CGFloat = 0
    @State private var hideTask: DispatchWorkItem?
    @State private var lastScrubberDown = Date.distantPast
    @State private var lastFocusChange = Date.distantPast
    @FocusState private var focus: BannerFocus?

    var body: some View {
        ZStack(alignment: .bottom) {
            if let engine = playback.engine {
                AetherPlayerSurface(engine: engine)
                    .ignoresSafeArea()
            }

            Color.clear
                .contentShape(Rectangle())
                .focusable(!showBanner)
                .focused($focus, equals: .screen)
                .onMoveCommand { _ in interact() }
                .onTapGesture { interact() }
                .ignoresSafeArea()

            CaptionOverlay(text: playback.captionText, bottomClearance: showBanner ? bannerHeight : 0)

            PlaybackFailureOverlay(message: playback.failure)

            banner
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { bannerHeight = $0 }
                .opacity(showBanner ? 1 : 0)
                .allowsHitTesting(showBanner)
                .animation(.easeInOut(duration: 0.25), value: showBanner)
        }
        .onPlayPauseCommand { interact(); playback.togglePlayPause() }
        // Keep something focused so Back always reaches our handler (see LiveTVPlayerView).
        .onChange(of: focus) { _, newValue in
            guard newValue == nil else { return }
            DispatchQueue.main.async {
                if focus == nil { focus = showBanner ? .play : .screen }
            }
        }
        // Back: first hide the banner, then leave the recording.
        .onExitCommand {
            if showBanner { hideBanner() } else { dismiss() }
        }
        .onAppear {
            interact()
            focus = .scrubber
            playback.connect(entry: entry)
        }
        .onDisappear { playback.disconnect() }
        .onChange(of: focus) { _, _ in lastFocusChange = Date() }
    }

    private var banner: some View {
        VStack(alignment: .leading, spacing: 16) {
            ScrubberBar(
                currentTime: playback.currentTime,
                duration: playback.duration,
                onSeek: { time in
                    interact()
                    playback.seek(to: time)
                },
                isFocused: focus == .scrubber,
                onDown: {
                    lastScrubberDown = Date()
                    focus = .play
                }
            )
            .focused($focus, equals: .scrubber)

            HStack(alignment: .center, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.title)
                        .font(.title3)
                        .bold()
                    Text(entry.start.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption.weight(.semibold))
                        .foregroundColor(guideAccent)
                    if !entry.description.isEmpty {
                        Text(entry.description)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(3)
                    }
                }

                Spacer()

                Button {
                    interact()
                    playback.togglePlayPause()
                } label: {
                    Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2)
                        .frame(width: 60, height: 60)
                }
                .buttonStyle(BannerButtonStyle())
                .focused($focus, equals: .play)

                Button {
                    interact()
                    playback.toggleCaptions()
                } label: {
                    Image(systemName: playback.captionsOn ? "captions.bubble.fill" : "captions.bubble")
                        .font(.title2)
                        .frame(width: 60, height: 60)
                }
                .buttonStyle(BannerButtonStyle(tint: playback.captionsOn ? guideAccent : nil))
                .focused($focus, equals: .captions)
            }
        }
        .padding(.horizontal, 48)
        .padding(.vertical, 28)
        .background(alignment: .bottom) {
            LinearGradient(
                colors: [Color(red: 0.06, green: 0.09, blue: 0.19).opacity(0.95),
                         Color(red: 0.02, green: 0.02, blue: 0.06).opacity(0.98)],
                startPoint: .top, endPoint: .bottom
            )
            .overlay(alignment: .top) {
                Rectangle().fill(Color.white.opacity(0.12)).frame(height: 1)
            }
            .ignoresSafeArea()
        }
        .onMoveCommand { direction in
            if direction == .up {
                focus = .scrubber
            } else if direction == .down, focus != .scrubber,
                      Date().timeIntervalSince(lastScrubberDown) > 0.4,
                      Date().timeIntervalSince(lastFocusChange) > 0.5 {
                hideBanner()
            }
        }
    }

    // Any remote interaction shows the banner and restarts the 5-second hide timer.
    private func interact() {
        hideTask?.cancel()
        if !showBanner {
            showBanner = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { focus = .scrubber }
        } else if focus == nil || focus == .screen {
            focus = .scrubber
        }
        let task = DispatchWorkItem { hideBanner() }
        hideTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: task)
    }

    private func hideBanner() {
        hideTask?.cancel()
        showBanner = false
        DispatchQueue.main.async { focus = .screen }
    }
}
