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

    /// The banner's horizontal inset. The still overlay has to match it: `ScrubberBar` places its dot
    /// as a fraction of its own width, and the still aligns to that dot by taking the same width.
    private static let bannerInset: CGFloat = 48
    /// Gap between the banner's top edge and the still, which floats over the video instead of taking
    /// a row in the banner.
    private static let stillGap: CGFloat = 18
    /// What the still occupies above the banner. Captions clear it only while a scrub still is actually
    /// on screen: a banner with no still must not push caption lines up the screen.
    private var stillClearance: CGFloat {
        playback.thumbnails == nil || !playback.isScrubbing
            ? 0 : ScrubStillCell.size.height + Self.stillGap
    }

    var body: some View {
        // The still is a scrub preview, not banner chrome: it is up while a scrub is on screen, and
        // only while the banner itself is up.
        let showsStill = showBanner && playback.isScrubbing

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

            CaptionOverlay(text: playback.captionText,
                           bottomClearance: showBanner ? bannerHeight + stillClearance : 0)

            PlaybackFailureOverlay(message: playback.failure)

            banner
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { bannerHeight = $0 }
                .opacity(showBanner ? 1 : 0)
                .allowsHitTesting(showBanner)
                .animation(.easeInOut(duration: 0.25), value: showBanner)

            // The still floats over the video above the banner rather than taking a banner row: it is
            // a preview of where the playhead is, not a control, and laying it out would push the
            // controls up the screen every time it appears.
            if let provider = playback.thumbnails {
                ScrubStillView(provider: provider,
                               currentTime: playback.currentTime,
                               stillTime: playback.stillTime,
                               duration: playback.duration,
                               isActive: showsStill)
                    .padding(.horizontal, Self.bannerInset)
                    .padding(.bottom, bannerHeight + Self.stillGap)
                    .opacity(showsStill ? 1 : 0)
                    .allowsHitTesting(false)
                    .animation(.easeInOut(duration: 0.25), value: showsStill)
                    .animation(.easeInOut(duration: 0.25), value: showBanner)
            }
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
        .padding(.horizontal, Self.bannerInset)
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
