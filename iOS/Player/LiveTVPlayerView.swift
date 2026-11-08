// iOS/LiveTVPlayerView.swift
import SwiftUI
import Combine
import AetherEngine

// Touch version of the tvOS live banner: tap the video to show or hide the controls. They hide
// again after 5 seconds while playing, and stay up while paused or scrubbing.
/// What the live player opens on: a channel, optionally with a recording in progress on it as the
/// rewind buffer.
struct LivePlayback: Identifiable {
    let channel: Channel
    var recording: DVR.Entry? = nil
    var startAtBeginning = false
    var id: String { channel.id + (recording?.id ?? "") }
}

struct LiveTVPlayerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    let channel: Channel
    /// A recording of this channel still being made, played as the rewind buffer behind live.
    var recording: DVR.Entry? = nil
    /// With a recording: open at its start instead of at live.
    var startAtBeginning = false
    @StateObject private var live = AetherLiveController()
    @StateObject private var pip = PictureInPicture()
    @State private var nowPlaying: EPGEvent?
    @State private var isRecording = false
    @State private var confirmStop = false
    @State private var recordError: String?
    @State private var showControls = true
    // Measured, so captions can sit above the banner while it's up.
    @State private var bannerHeight: CGFloat = 0
    @State private var isScrubbing = false
    @State private var hideTask: DispatchWorkItem?
    @State private var now = Date()
    #if DEBUG
    @State private var showStats = false
    #endif

    // 1s: the paused-timeshift counter has to tick visibly.
    private let clock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let engine = live.engine {
                AetherPlayerSurface(engine: engine)
                    .ignoresSafeArea()
            }

            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { toggleControls() }
                #if DEBUG
                .onLongPressGesture { showStats.toggle() }
                #endif
                .ignoresSafeArea()

            // With the banner up, the spinner sits in the play button instead.
            if live.state == .connecting && !showControls {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
            }

            CaptionOverlay(text: live.captionText, bottomClearance: showControls ? bannerHeight : 0)

            PlaybackFailureOverlay(message: live.failure)

            #if DEBUG
            if showStats, let engine = live.engine {
                AetherStatsOverlay(engine: engine, clock: engine.clock, diagnostics: engine.diagnostics,
                                   channelName: channel.name, failure: live.failure,
                                   firstFrameSeconds: live.firstFrameSeconds, retunes: live.retunes)
            }
            #endif

            if showControls {
                controls
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
            loadNowPlaying()
            if let engine = live.engine { pip.bind(engine) }
            live.connect(channel: channel, recording: recording, startAtBeginning: startAtBeginning)
            scheduleHide()
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            hideTask?.cancel()
            pip.unbind()
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
        .onChange(of: live.isPlaying) { _, _ in scheduleHide() }
        .onChange(of: isScrubbing) { _, _ in scheduleHide() }
        .onChange(of: live.failure) { _, failure in
            if failure != nil { interact() }
        }
    }

    // MARK: controls

    // Everything lives on one banner at the bottom, as on tvOS: scrubber, channel and program, then
    // every button in one row. The rest of the screen stays clear so a tap there reaches the video.
    private var controls: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            banner
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { bannerHeight = $0 }
        }
        .foregroundStyle(.white)
    }

    // iPhone in landscape: little height to spare.
    private var isCompactHeight: Bool { verticalSizeClass == .compact }

    private var banner: some View {
        VStack(alignment: .leading, spacing: isCompactHeight ? 8 : 14) {
            LiveScrubber(
                showStart: nowPlaying?.start,
                showStop: nowPlaying?.stop,
                now: now,
                currentTime: live.currentTime,
                duration: effectiveDuration,
                isLive: live.isLive,
                isScrubbing: $isScrubbing,
                onSeek: { time in interact(); live.seek(to: time) }
            )

            if isCompactHeight {
                // The buttons share the info line so the banner covers less of the picture.
                HStack(alignment: .center, spacing: 12) {
                    artwork(width: 72, height: 40)
                    programInfo
                    Spacer(minLength: 8)
                    buttonRow
                        .fixedSize()
                }
            } else {
                HStack(alignment: .top, spacing: 12) {
                    artwork(width: 96, height: 54)
                    programInfo
                }
                buttonRow
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, isCompactHeight ? 10 : 14)
        .padding(.bottom, 8)
        .playerBannerBackground()
    }

    @ViewBuilder
    private func artwork(width: CGFloat, height: CGFloat) -> some View {
        if let imageURL = TVHClient.sharedInstance.imageURL(path: nowPlaying?.imagePath ?? channel.iconPath) {
            AsyncImage(url: imageURL) { image in
                image.resizable().aspectRatio(contentMode: .fit)
            } placeholder: {
                Color.white.opacity(0.1)
            }
            .frame(width: width, height: height)
            .clipped()
        }
    }

    private var programInfo: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                if let number = channel.number {
                    Text(number)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(guideAccent)
                }
                Text(channel.name)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
                if let streamLabel {
                    Text(streamLabel)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.6))
                }
                if let timeshiftOffsetSeconds {
                    Text("Timeshift: \(Self.formattedTimeshiftOffset(timeshiftOffsetSeconds))")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(guideAccent)
                }
            }
            if let nowPlaying {
                Text(nowPlaying.title)
                    .font(.headline)
                    .lineLimit(1)
                if let subtitle = nowPlaying.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                }
            } else {
                Text("No EPG information available")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.7))
            }
            if let recordError {
                Text(recordError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private var buttonRow: some View {
        HStack(spacing: 8) {
            Button { interact(); live.togglePlayPause() } label: {
                if live.state == .connecting {
                    ProgressView().tint(.white)
                } else {
                    Image(systemName: live.isPlaying ? "pause.fill" : "play.fill")
                }
            }
            .buttonStyle(PlayerIconButtonStyle())
            .disabled(live.state == .connecting)
            .accessibilityLabel(live.isPlaying ? "Pause" : "Play")

            Button { interact(); skip(by: -10) } label: {
                Image(systemName: "gobackward.10")
            }
            .buttonStyle(PlayerIconButtonStyle())
            .accessibilityLabel("Back 10 seconds")

            Button { interact(); skip(by: 10) } label: {
                Image(systemName: "goforward.10")
            }
            .buttonStyle(PlayerIconButtonStyle())
            .disabled(live.isLive)
            .accessibilityLabel("Forward 10 seconds")

            Button { interact(); live.goLive() } label: {
                Image(systemName: live.isLive ? "dot.radiowaves.left.and.right" : "forward.end.fill")
            }
            .buttonStyle(PlayerIconButtonStyle(tint: live.isLive ? guideAccent : nil))
            .disabled(live.isLive)
            .accessibilityLabel(live.isLive ? "At live edge" : "Go to live")

            Button { interact(); live.toggleCaptions() } label: {
                Image(systemName: live.captionsOn ? "captions.bubble.fill" : "captions.bubble")
            }
            .buttonStyle(PlayerIconButtonStyle(tint: live.captionsOn ? guideAccent : nil))
            .accessibilityLabel(live.captionsOn ? "Turn off captions" : "Turn on captions")

            // While recording this turns into a stop button (confirmed first).
            Button {
                interact()
                if isRecording { confirmStop = true } else { startRecording() }
            } label: {
                Image(systemName: isRecording ? "stop.circle.fill" : "record.circle")
            }
            .buttonStyle(PlayerIconButtonStyle(tint: isRecording ? .red : nil))
            .disabled(nowPlaying == nil)
            .accessibilityLabel(isRecording ? "Stop recording" : "Record this program")

            Spacer(minLength: 0)

            Button { dismiss() } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(PlayerIconButtonStyle())
            .accessibilityLabel("Close")
        }
    }

    // MARK: timeshift

    // Window length including time spent paused. The engine may stop updating its window while
    // paused even though the stream keeps filling it, so take the larger of its figure and the
    // wall-clock estimate.
    private var effectiveDuration: TimeInterval {
        guard let pausedAt = live.pausedAt else { return live.duration }
        return max(live.duration, live.durationAtPause + max(now.timeIntervalSince(pausedAt), 0))
    }

    // How far behind the live edge we're watching, or nil at the live edge.
    private var timeshiftOffsetSeconds: TimeInterval? {
        if !live.isLive {
            return max(effectiveDuration - live.currentTime, 0)
        }
        if let pausedAt = live.pausedAt {
            return now.timeIntervalSince(pausedAt)
        }
        return nil
    }

    private func skip(by seconds: TimeInterval) {
        live.seek(to: min(max(live.currentTime + seconds, 0), effectiveDuration))
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
        let size = live.videoSize
        guard size.width > 0, size.height > 0 else { return nil }
        let height = Int(size.height)
        // US ATSC convention: 720-line broadcasts are progressive, 1080-line interlaced.
        switch height {
        case 1080: return "1080i"
        case 720: return "720p"
        case 480: return "480i"
        default: return "\(Int(size.width))\u{00D7}\(height)"
        }
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
        guard showControls, live.isPlaying, !isScrubbing, live.failure == nil else { return }
        let task = DispatchWorkItem { showControls = false }
        hideTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: task)
    }

    // MARK: EPG / recording

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

// Live scrubber on the show's timeline, as on tvOS: the track spans the program's start..stop in
// wall-clock time, the lighter segment is what the timeshift buffer holds, and the dot is where
// you are. Drag anywhere on the track; the seek happens on release.
private struct LiveScrubber: View {
    let showStart: Date?
    let showStop: Date?
    let now: Date
    /// Scrubber space from the player: 0 = oldest buffered, duration = live edge.
    let currentTime: TimeInterval
    let duration: TimeInterval
    let isLive: Bool
    @Binding var isScrubbing: Bool
    let onSeek: (TimeInterval) -> Void
    /// Scrubber-space position under the finger while dragging.
    @State private var dragTime: TimeInterval?

    private var bufferStart: Date { now.addingTimeInterval(-duration) }
    private var currentWall: Date { bufferStart.addingTimeInterval(dragTime ?? currentTime) }

    // Track range: the show, widened if the buffer reaches outside it or the guide data is stale.
    private var rangeStart: Date { min(showStart ?? bufferStart, bufferStart) }
    private var rangeStop: Date { max(showStop ?? now, now) }

    private func fraction(_ date: Date) -> Double {
        let total = rangeStop.timeIntervalSince(rangeStart)
        guard total > 0 else { return 0 }
        return min(max(date.timeIntervalSince(rangeStart) / total, 0), 1)
    }

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { geo in
                let w = geo.size.width
                let bufX = w * fraction(bufferStart)
                let liveX = w * fraction(now)
                let dotX = w * fraction(currentWall)
                let dot: CGFloat = dragTime == nil ? 14 : 22
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.2))
                        .frame(height: 4)
                    Capsule().fill(guideAccent.opacity(0.7))
                        .frame(width: max(liveX - bufX, 4), height: 4)
                        .offset(x: bufX)
                    Circle()
                        .fill(guideAccent)
                        .frame(width: dot, height: dot)
                        .shadow(color: .black.opacity(0.6), radius: 4)
                        .offset(x: min(max(dotX - dot / 2, 0), w - dot))
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            isScrubbing = true
                            let total = rangeStop.timeIntervalSince(rangeStart)
                            let target = rangeStart.addingTimeInterval(total * min(max(value.location.x / max(w, 1), 0), 1))
                            let clamped = min(max(target, bufferStart), now)
                            dragTime = clamped.timeIntervalSince(bufferStart)
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
                Text(Self.clock(rangeStart))
                Spacer()
                Text(isLive && dragTime == nil ? "" : Self.clock(currentWall))
                    .bold()
                    .foregroundStyle(.white)
                Spacer()
                Text(Self.clock(rangeStop))
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.white.opacity(0.6))
        }
    }

    private static func clock(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }
}
