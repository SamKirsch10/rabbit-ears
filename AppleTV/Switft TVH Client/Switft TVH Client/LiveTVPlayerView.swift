// Sources/LiveTVPlayerView.swift
import SwiftUI
import Combine
import AetherEngine

enum BannerFocus: Hashable { case screen, scrubber, play, live, captions, record }

struct LiveTVPlayerView: View {
    @Environment(\.dismiss) private var dismiss

    let channel: Channel
    @StateObject private var live = AetherLiveController()
    @State private var nowPlaying: EPGEvent?
    @State private var isRecording = false
    @State private var confirmStop = false
    @State private var recordError: String?
    @State private var showBanner = true
    // Measured, so captions can sit above the banner while it's up.
    @State private var bannerHeight: CGFloat = 0
    @State private var hideTask: DispatchWorkItem?
    @State private var now = Date()
    #if DEBUG
    @State private var showStats = false
    #endif
    @FocusState private var bannerFocus: BannerFocus?

    // 1s, not 30s: needs to tick visibly for the paused-timeshift counter in
    // the banner; also benefits the EPG progress bar with smoother updates.
    private let clock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack(alignment: .bottom) {
            if let engine = live.engine {
                AetherPlayerSurface(engine: engine)
                    .ignoresSafeArea()
            }

            // Invisible focus holder: keeps the remote delivering presses while
            // the banner is hidden, so any press can bring it back.
            Color.clear
                .contentShape(Rectangle())
                .focusable(!showBanner)
                .focused($bannerFocus, equals: .screen)
                .onMoveCommand { _ in interact() }
                .onTapGesture { interact() }
                #if DEBUG
                .onLongPressGesture { showStats.toggle() }
                #endif
                .ignoresSafeArea()

            CaptionOverlay(text: live.captionText, bottomClearance: showBanner ? bannerHeight : 0)

            PlaybackFailureOverlay(message: live.failure)

            #if DEBUG
            if showStats, let engine = live.engine {
                AetherStatsOverlay(engine: engine, clock: engine.clock, diagnostics: engine.diagnostics,
                                   channelName: channel.name, failure: live.failure,
                                   firstFrameSeconds: live.firstFrameSeconds, retunes: live.retunes)
            }
            #endif

            PlaybackBanner(
                channel: channel,
                nowPlaying: nowPlaying,
                now: now,
                videoSize: live.videoSize,
                isPlaying: live.isPlaying,
                isRecording: isRecording,
                recordError: recordError,
                captionsOn: live.captionsOn,
                showScrubber: true,
                scrubberCurrentTime: live.currentTime,
                scrubberDuration: effectiveDuration,
                isLive: live.isLive,
                timeshiftOffsetSeconds: timeshiftOffsetSeconds,
                onTogglePlayPause: { interact(); live.togglePlayPause() },
                onToggleCaptions: { interact(); live.toggleCaptions() },
                onRecord: {
                    interact()
                    // While recording, the button stops it (confirmed first).
                    if isRecording { confirmStop = true } else { startRecording() }
                },
                onSeek: { time in interact(); live.seek(to: time) },
                onGoLive: { interact(); live.goLive() },
                focus: $bannerFocus,
                onDismiss: { hideBanner() }
            )
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { bannerHeight = $0 }
            .opacity(showBanner ? 1 : 0)
            .allowsHitTesting(showBanner)
            .animation(.easeInOut(duration: 0.25), value: showBanner)
        }
        // Focus can vanish while the banner is up (a pressed button disables itself:
        // Live once you're at the live edge). With nothing focused, Back
        // skips our handler and leaves the channel, so put focus back right away.
        .onChange(of: bannerFocus) { _, newValue in
            guard newValue == nil else { return }
            DispatchQueue.main.async {
                if bannerFocus == nil { bannerFocus = showBanner ? .play : .screen }
            }
        }
        .onMoveCommand { _ in interact() }
        .onPlayPauseCommand { interact(); live.togglePlayPause() }
        // Back: first hide the banner, then leave the channel.
        .onExitCommand {
            if showBanner { hideBanner() } else { dismiss() }
        }
        .onAppear {
            interact()
            bannerFocus = .play
            loadNowPlaying()
            live.connect(channel: channel)
        }
        .onDisappear {
            live.disconnect()
        }
        .alert(nowPlaying?.recordingMark == .scheduled ? "Cancel recording?" : "Stop recording?",
               isPresented: $confirmStop) {
            Button(nowPlaying?.recordingMark == .scheduled ? "Cancel Recording" : "Stop Recording",
                   role: .destructive) { stopRecording() }
            Button("Keep Recording", role: .cancel) {}
        } message: {
            Text(nowPlaying?.recordingMark == .scheduled
                 ? "\"\(nowPlaying?.title ?? channel.name)\" won't be recorded."
                 : "\"\(nowPlaying?.title ?? channel.name)\" stops recording now. What's been recorded so far is kept.")
        }
        .onReceive(clock) { date in
            now = date
        }
    }

    // How far behind the live edge we're currently watching, or nil when at
    // the live edge. Two sources: an explicit scrub (the scrubber's 0...duration
    // space, duration = live edge) or a simple pause (counts up from pausedAt).
    // Window length including time spent paused. The engine may stop updating its
    // window while paused even though the stream keeps filling it, so take the larger
    // of its figure and the wall-clock estimate.
    private var effectiveDuration: TimeInterval {
        guard let pausedAt = live.pausedAt else { return live.duration }
        return max(live.duration, live.durationAtPause + max(now.timeIntervalSince(pausedAt), 0))
    }

    private var timeshiftOffsetSeconds: TimeInterval? {
        if !live.isLive {
            return max(effectiveDuration - live.currentTime, 0)
        }
        if let pausedAt = live.pausedAt {
            return now.timeIntervalSince(pausedAt)
        }
        return nil
    }

    // Any remote interaction (direction press, or a button in the banner) shows the
    // banner and restarts the 5-second countdown to hide it again.
    private func interact() {
        hideTask?.cancel()
        // The banner only becomes focusable once visible; and if focus is
        // still parked on the invisible holder, move it into the banner so
        // the remote can actually navigate it.
        if !showBanner {
            showBanner = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { bannerFocus = .scrubber }
        } else if bannerFocus == nil || bannerFocus == .screen {
            bannerFocus = .scrubber
        }
        let task = DispatchWorkItem { hideBanner() }
        hideTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: task)
    }

    private func hideBanner() {
        hideTask?.cancel()
        showBanner = false
        // The focus holder only becomes focusable once the banner is hidden.
        DispatchQueue.main.async { bannerFocus = .screen }
    }

    private func loadNowPlaying() {
        TVHClient.sharedInstance.fetchNowPlaying(channel: channel) { result in
            if case .success(let event) = result {
                nowPlaying = event
                // Already recording (or about to): the record button starts out as a stop button.
                isRecording = event?.recordingMark != nil
            }
        }
    }

    private func startRecording() {
        guard let nowPlaying else { return }
        recordError = nil
        TVHClient.sharedInstance.createRecording(eventID: nowPlaying.id) { result in
            switch result {
            case .success:
                isRecording = true
                // Picks up the new entry's uuid, which stopping it needs.
                loadNowPlaying()
            case .failure(let error):
                recordError = error.localizedDescription
            }
        }
    }

    private func stopRecording() {
        guard let nowPlaying, let uuid = nowPlaying.dvrUuid else {
            recordError = "Couldn't find this recording on the server."
            loadNowPlaying()
            return
        }
        recordError = nil
        TVHClient.sharedInstance.stopRecording(uuid: uuid, isRunning: nowPlaying.recordingMark == .recording) { result in
            switch result {
            case .success:
                isRecording = false
                loadNowPlaying()
            case .failure(let error):
                recordError = error.localizedDescription
            }
        }
    }
}

private struct PlaybackBanner: View {
    let channel: Channel
    let nowPlaying: EPGEvent?
    let now: Date
    let videoSize: CGSize
    let isPlaying: Bool
    let isRecording: Bool
    let recordError: String?
    let captionsOn: Bool
    let showScrubber: Bool
    let scrubberCurrentTime: TimeInterval
    let scrubberDuration: TimeInterval
    let isLive: Bool
    let timeshiftOffsetSeconds: TimeInterval?
    let onTogglePlayPause: () -> Void
    let onToggleCaptions: () -> Void
    let onRecord: () -> Void
    let onSeek: (TimeInterval) -> Void
    let onGoLive: () -> Void
    var focus: FocusState<BannerFocus?>.Binding
    let onDismiss: () -> Void
    // The down press that moves scrubber -> buttons also bubbles up to the
    // banner's own handler; this stops it from being read as "dismiss".
    @State private var lastScrubberDown = Date.distantPast
    @State private var lastFocusChange = Date.distantPast

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if showScrubber {
                LiveScrubberBar(
                    showStart: nowPlaying?.start,
                    showStop: nowPlaying?.stop,
                    now: now,
                    currentTime: scrubberCurrentTime,
                    duration: scrubberDuration,
                    isLive: isLive,
                    onSeek: onSeek,
                    isFocused: focus.wrappedValue == .scrubber,
                    onDown: {
                        lastScrubberDown = Date()
                        focus.wrappedValue = .play
                    }
                )
                .focused(focus, equals: .scrubber)
            } else if let nowPlaying {
                ProgressRow(start: nowPlaying.start, stop: nowPlaying.stop, now: now)
            }

            HStack(alignment: .center, spacing: 20) {
                if let imageURL = TVHClient.sharedInstance.imageURL(path: nowPlaying?.imagePath ?? channel.iconPath) {
                    AsyncImage(url: imageURL) { image in
                        image.resizable().aspectRatio(contentMode: .fit)
                    } placeholder: {
                        Color.white.opacity(0.1)
                    }
                    .frame(width: 160, height: 90)
                    .clipped()
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        if let number = channel.number {
                            Text(number)
                                .font(.caption.weight(.semibold))
                                .foregroundColor(guideAccent)
                        }
                        Text(channel.name)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        if let streamLabel {
                            Text(streamLabel)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        if let timeshiftOffsetSeconds {
                            Text("Timeshift: \(Self.formattedTimeshiftOffset(timeshiftOffsetSeconds))")
                                .font(.caption.weight(.semibold))
                                .foregroundColor(guideAccent)
                        }
                    }
                    if let nowPlaying {
                        Text(nowPlaying.title)
                            .font(.title3)
                            .bold()
                        if let subtitle = nowPlaying.subtitle {
                            Text(subtitle)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        if let details = nowPlaying.description ?? nowPlaying.summary {
                            Text(details)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(3)
                        }
                    } else {
                        Text("No EPG information available")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    if let recordError {
                        Text(recordError)
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }

                Spacer()

                HStack(spacing: 64) {
                    Button(action: onTogglePlayPause) {
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                            .font(.title2)
                            .frame(width: 60, height: 60)
                    }
                    .buttonStyle(BannerButtonStyle())
                    .focused(focus, equals: .play)

                    if showScrubber {
                        Button(action: { if !isLive { onGoLive() } }) {
                            Image(systemName: isLive ? "dot.radiowaves.left.and.right" : "forward.end.fill")
                                .font(.title2)
                                .frame(width: 60, height: 60)
                        }
                        .buttonStyle(BannerButtonStyle(tint: isLive ? guideAccent : nil))
                        .focused(focus, equals: .live)
                        .disabled(isLive)
                    }

                    Button(action: onToggleCaptions) {
                        Image(systemName: captionsOn ? "captions.bubble.fill" : "captions.bubble")
                            .font(.title2)
                            .frame(width: 60, height: 60)
                    }
                    .buttonStyle(BannerButtonStyle(tint: captionsOn ? guideAccent : nil))
                    .focused(focus, equals: .captions)

                    Button(action: onRecord) {
                        Image(systemName: isRecording ? "stop.circle.fill" : "record.circle")
                            .font(.title2)
                            .frame(width: 60, height: 60)
                    }
                    .buttonStyle(BannerButtonStyle(tint: isRecording ? .red : nil))
                    .focused(focus, equals: .record)
                    .disabled(nowPlaying == nil)
                }
                .focusSection()
            }
        }
        .padding(.horizontal, 48)
        .padding(.vertical, 28)
        .background(alignment: .bottom) {
            // Full-bleed: runs to the screen edges and bottom, while the
            // content above stays inside the tvOS safe area.
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
        .onChange(of: focus.wrappedValue) { _, _ in lastFocusChange = Date() }
        .onMoveCommand { direction in
            if direction == .up, showScrubber {
                focus.wrappedValue = .scrubber
            } else if direction == .down, focus.wrappedValue != .scrubber,
                      Date().timeIntervalSince(lastScrubberDown) > 0.4,
                      Date().timeIntervalSince(lastFocusChange) > 0.5 {
                onDismiss() // down from the buttons closes the banner
            }
        }
    }

    private static func formattedTimeshiftOffset(_ seconds: TimeInterval) -> String {
        let total = max(Int(seconds.rounded()), 0)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "-%dh %02dm", hours, minutes)
        } else if minutes > 0 {
            return String(format: "-%dm %02ds", minutes, secs)
        } else {
            return String(format: "-%ds", secs)
        }
    }

    private var streamLabel: String? {
        guard videoSize.width > 0, videoSize.height > 0 else { return nil }
        let height = Int(videoSize.height)
        // Approximated from resolution alone, following common US ATSC convention:
        // 720-line broadcasts are progressive, 1080-line are interlaced (1080p is rare
        // and not distinguishable from height alone without deeper stream inspection).
        switch height {
        case 1080: return "1080i"
        case 720: return "720p"
        case 480: return "480i"
        default: return "\(Int(videoSize.width))\u{00D7}\(height)"
        }
    }
}

private let bannerTimeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.timeStyle = .short
    return formatter
}()

private struct ProgressRow: View {
    let start: Date
    let stop: Date
    let now: Date

    private var progress: Double {
        let total = stop.timeIntervalSince(start)
        guard total > 0 else { return 0 }
        return min(max(now.timeIntervalSince(start) / total, 0), 1)
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(bannerTimeFormatter.string(from: start))
                .font(.caption2)
                .foregroundColor(.secondary)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.25))
                    Capsule().fill(Color.white).frame(width: max(geo.size.width * progress, 4))
                }
            }
            .frame(height: 6)

            Text(bannerTimeFormatter.string(from: stop))
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }
}

struct BannerButtonStyle: ButtonStyle {
    /// Overrides the icon colour in every state (e.g. red while recording).
    var tint: Color? = nil
    @Environment(\.isFocused) private var focused
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(tint ?? (focused ? .black : .white))
            .frame(width: 76, height: 76)
            .background(Circle().fill(focused ? Color.white : Color.white.opacity(0.1)))
            .overlay(Circle().strokeBorder(focused ? guideAccent : Color.white.opacity(0.12),
                                           lineWidth: focused ? 4 : 1))
            .scaleEffect(focused ? 1.1 : 1)
            .opacity(enabled ? 1 : 0.4)
            .animation(.easeOut(duration: 0.15), value: focused)
    }
}
