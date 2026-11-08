// Sources/GuideView.swift
import SwiftUI
import UIKit
import Combine

private let guideTimeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.timeStyle = .short
    return formatter
}()

private let guideCellRadius: CGFloat = 12
private let guideCellHeight: CGFloat = 84

/// A guide program picked with Select, waiting on Watch or Record in the action sheet.
private struct ProgramChoice {
    let channel: Channel
    let event: EPGEvent
}

struct GuideView: View {
    @ObservedObject var filter: GuideFilter
    private let client = TVHClient.sharedInstance
    // Rounded down to the current or previous half hour, as a TV guide normally starts.
    // State, not a constant: it must move forward as time passes or after the app
    // has been backgrounded, otherwise the guide stays stuck on the launch time.
    @State private var windowStart: Date = GuideView.currentWindowStart()
    @State private var lastLoad = Date()
    // The cell that was focused when a channel was opened, restored on return.
    @State private var lastOpenedChannelID: String?
    @State private var restoreToken = 0
    // Scroll hint: a channel bubble beside the system scroll indicator while
    // the list is scrolled quickly. Driven by the real scroll offset (a fast
    // scroll moves the view without moving focus), not by the focused row.
    @State private var scrollHintVisible = false
    @State private var scrollHintChannel: Channel?
    @State private var scrollHintFraction: CGFloat = 0
    @State private var scrollWindowOffset: CGFloat = 0
    @State private var scrollWindowTime = Date.distantPast
    @State private var scrollHintHide: DispatchWorkItem?
    private static func currentWindowStart() -> Date {
        let now = Date()
        var components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: now)
        components.minute = (components.minute ?? 0) < 30 ? 0 : 30
        return Calendar.current.date(from: components) ?? now
    }
    private let windowDuration: TimeInterval = 2 * 60 * 60
    private let labelWidth: CGFloat = 300
    private let clock = Timer.publish(every: 20, on: .main, in: .common).autoconnect()

    @State private var channels: [Channel] = []
    @State private var eventsByChannel: [String: [EPGEvent]] = [:]
    @State private var loading = true
    @State private var error: String?
    @State private var selectedChannel: Channel?
    // With selectedChannel: a recording in progress on it, played as the live view's rewind buffer.
    @State private var liveRecording: DVR.Entry?
    @State private var liveFromStart = false
    @State private var pendingChoice: ProgramChoice?
    // Set from the action sheet's Stop/Cancel Recording; confirmed before it's sent.
    @State private var pendingStop: ProgramChoice?
    @State private var recordBusy = false
    @State private var openError: String?
    @State private var now = Date()
    // Kept separately from the focus state so the hero panel doesn't blank out for
    // the instant focus is between two cells.
    @State private var heroChannel: Channel?
    @State private var heroSegment: GuideSegment?
    // Which cell is focused, tracked by "<channelID>|<segmentID>". A single shared
    // FocusState bound to every cell via .focused(_:equals:) -- the standard SwiftUI
    // pattern for collection focus tracking, and more reliable here than reading
    // @Environment(\.isFocused) per cell, which wasn't updating for this plain-
    // focusable (non-Button) view on either programmatic or remote-driven focus moves.
    @FocusState private var focusedCellID: String?

    private var visibleChannels: [Channel] { channels.filter(filter.passes) }

    private var windowEnd: Date { windowStart.addingTimeInterval(windowDuration) }

    var body: some View {
        Group {
            if loading {
                ProgressView("Loading Guide...")
            } else if let error {
                Text("Error: \(error)")
                    .foregroundColor(.red)
            } else {
                GeometryReader { geo in
                    let rowWidth = max(geo.size.width - labelWidth - 80, 0)
                    VStack(alignment: .leading, spacing: 0) {
                        GuideHero(channel: heroChannel, segment: heroSegment, now: now)
                            .padding(.horizontal, 40)
                            .padding(.bottom, 12)

                        timeHeader(rowWidth: rowWidth)
                            .padding(.horizontal, 40)
                            .padding(.bottom, 8)

                        ScrollViewReader { proxy in
                        ScrollView(.vertical, showsIndicators: false) {
                            LazyVStack(alignment: .leading, spacing: 22) {
                                ForEach(visibleChannels) { channel in
                                    GuideRow(
                                        channel: channel,
                                        segments: segments(for: channel),
                                        windowDuration: windowDuration,
                                        labelWidth: labelWidth,
                                        rowWidth: rowWidth,
                                        now: now,
                                        focusedCellID: $focusedCellID,
                                        onSelect: { channel, event in
                                            // No EPG data to record from: just tune in.
                                            if let event {
                                                pendingChoice = ProgramChoice(channel: channel, event: event)
                                            } else {
                                                watchLive(channel)
                                            }
                                        }
                                    )
                                }
                            }
                            .padding(.horizontal, 40)
                            .padding(.vertical, 12)
                            .background(alignment: .topLeading) {
                                gridOverlay(rowWidth: rowWidth)
                                    .padding(.horizontal, 40)
                                    .allowsHitTesting(false)
                            }
                        }
                        .onScrollGeometryChange(for: ScrollMetrics.self) { geo in
                            ScrollMetrics(offset: geo.contentOffset.y,
                                          content: geo.contentSize.height,
                                          viewport: geo.containerSize.height)
                        } action: { old, new in
                            handleScroll(from: old, to: new)
                        }
                        .overlay(alignment: .topTrailing) {
                            ScrollHint(channel: scrollHintChannel, fraction: scrollHintFraction, visible: scrollHintVisible)
                        }
                        .overlay {
                            if visibleChannels.isEmpty && !channels.isEmpty {
                                Text("No channels match this filter")
                                    .font(.title3)
                                    .foregroundColor(.white.opacity(0.6))
                            }
                        }
                        .onChange(of: restoreToken) { _, _ in
                            // Lazy rows may not exist yet: scroll to the row first, then focus it.
                            if let id = lastOpenedChannelID {
                                NSLog("Guide: scrolling to last opened channel %@", id)
                                proxy.scrollTo(id, anchor: .center)
                            }
                        }
                        }
                    }
                }
            }
        }
        .background(
            LinearGradient(
                colors: [Color(red: 0.06, green: 0.09, blue: 0.19), Color(red: 0.02, green: 0.02, blue: 0.06)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
        )
        .background(
            // Navigation is triggered programmatically via selectedChannel (see onSelect
            // above) rather than wrapping each cell in its own NavigationLink, because
            // NavigationLink carries a tvOS focus "halo" effect that .focusEffectDisabled()
            // doesn't fully suppress; a plain focusable view does.
            NavigationLink(
                destination: Group {
                    if let selectedChannel {
                        LiveTVPlayerView(channel: selectedChannel, recording: liveRecording,
                                         startAtBeginning: liveFromStart)
                    }
                },
                isActive: Binding(
                    get: { selectedChannel != nil },
                    set: { isActive in
                        if !isActive {
                            selectedChannel = nil
                            liveRecording = nil
                        }
                    }
                )
            ) {
                EmptyView()
            }
            .hidden()
        )
        .confirmationDialog(
            pendingChoice?.event.title ?? "",
            isPresented: Binding(get: { pendingChoice != nil }, set: { if !$0 { pendingChoice = nil } }),
            titleVisibility: .visible,
            presenting: pendingChoice
        ) { choice in
            let event = choice.event
            let airing = event.start <= now && now < event.stop
            // Being recorded: offer the recording from the start as well as live.
            if event.recordingMark == .recording, event.dvrUuid != nil {
                Button("Start from Beginning") { watchRecording(choice, fromStart: true) }
                Button("Go to Live") { watchRecording(choice, fromStart: false) }
            } else {
                Button(airing ? "Watch Live" : "Watch Channel") { watchLive(choice.channel) }
            }
            switch event.recordingMark {
            case .recording:
                Button("Stop Recording", role: .destructive) { askToStop(choice) }
            case .scheduled:
                Button("Cancel Recording", role: .destructive) { askToStop(choice) }
            case nil:
                if event.stop > now, !recordBusy {
                    Button("Record") { record(choice) }
                }
            }
            Button("Close", role: .cancel) {}
        } message: { choice in
            Text(programMessage(choice.event))
        }
        .alert(
            pendingStop?.event.recordingMark == .scheduled ? "Cancel recording?" : "Stop recording?",
            isPresented: Binding(get: { pendingStop != nil }, set: { if !$0 { pendingStop = nil } }),
            presenting: pendingStop
        ) { choice in
            let scheduled = choice.event.recordingMark == .scheduled
            Button(scheduled ? "Cancel Recording" : "Stop Recording", role: .destructive) { stop(choice) }
            Button("Continue Recording", role: .cancel) {}
        } message: { choice in
            Text(choice.event.recordingMark == .scheduled
                 ? "\"\(choice.event.title)\" won't be recorded."
                 : "\"\(choice.event.title)\" stops recording now. What's been recorded so far is kept.")
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(get: { openError != nil }, set: { if !$0 { openError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(openError ?? "")
        }
        .navigationTitle("Guide")
        .onAppear {
            NSLog("Guide: onAppear channels=%d last=%@", channels.count, lastOpenedChannelID ?? "nil")
            if channels.isEmpty {
                load()
            } else {
                // Coming back from a channel (or the DVR): keep the list on screen,
                // refresh quietly, and put focus back where it was.
                load(silent: true)
                restoreFocusToLastChannel()
            }
        }
        .onChange(of: filter.selected) { _, _ in
            // The focused channel may have been filtered out: restart from the first visible one.
            guard let first = visibleChannels.first, let segment = segments(for: first).first else {
                heroChannel = nil
                heroSegment = nil
                return
            }
            heroChannel = first
            heroSegment = segment
            let id = "\(first.id)|\(segment.id)"
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { focusedCellID = id }
        }
        .onReceive(clock) { date in
            now = date
            // Window rolled into a new half hour, or data is getting old: refresh in place.
            if windowStart != GuideView.currentWindowStart() || date.timeIntervalSince(lastLoad) > 10 * 60 {
                load(silent: true)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            load(silent: true)
        }
        .onChange(of: focusedCellID) { _, newValue in
            updateHero(for: newValue)
        }
    }

    private func watchLive(_ channel: Channel, recording: DVR.Entry? = nil, fromStart: Bool = false) {
        lastOpenedChannelID = channel.id
        liveRecording = recording
        liveFromStart = fromStart
        selectedChannel = channel
    }

    /// Live, with the recording so far as the rewind buffer, opened at its start or at live.
    private func watchRecording(_ choice: ProgramChoice, fromStart: Bool) {
        guard let uuid = choice.event.dvrUuid else { return }
        client.fetchDVREntry(uuid: uuid) { result in
            switch result {
            case .success(let entry?):
                watchLive(choice.channel, recording: entry, fromStart: fromStart)
            case .success(nil):
                openError = "Couldn't find this recording on the server."
            case .failure(let error):
                openError = error.localizedDescription
            }
        }
    }

    private func programMessage(_ event: EPGEvent) -> String {
        let times = "\(guideTimeFormatter.string(from: event.start)) \u{2013} \(guideTimeFormatter.string(from: event.stop))"
        switch event.recordingMark {
        case .recording: return "\(times)  \u{2022}  Recording now"
        case .scheduled: return "\(times)  \u{2022}  Set to record"
        case nil: return times
        }
    }

    private func record(_ choice: ProgramChoice) {
        recordBusy = true
        client.createRecording(eventID: choice.event.id) { result in
            recordBusy = false
            switch result {
            case .success:
                load(silent: true)
            case .failure(let error):
                openError = error.localizedDescription
            }
        }
    }

    // The action sheet is still going away when its button runs; present the confirmation after.
    private func askToStop(_ choice: ProgramChoice) {
        DispatchQueue.main.async { pendingStop = choice }
    }

    private func stop(_ choice: ProgramChoice) {
        guard let uuid = choice.event.dvrUuid else {
            openError = "Couldn't find this recording on the server."
            return
        }
        client.stopRecording(uuid: uuid, isRunning: choice.event.recordingMark == .recording) { result in
            switch result {
            case .success:
                load(silent: true)
            case .failure(let error):
                openError = error.localizedDescription
            }
        }
    }

    // Called on every scroll offset change. Shows the hint only for a fast
    // scroll (several rows within half a second); single focus steps stay quiet.
    private func handleScroll(from old: ScrollMetrics, to new: ScrollMetrics) {
        let rows = visibleChannels
        guard !rows.isEmpty, new.content > new.viewport, abs(new.offset - old.offset) > 0.5 else { return }
        let stride = max((new.content - 24) / CGFloat(rows.count), 1)
        let maxOffset = new.content - new.viewport
        let fraction = min(max(new.offset / maxOffset, 0), 1)

        // The channel the thumb is "at": top row when scrolled to the top,
        // bottom visible row when scrolled to the bottom.
        let visibleRows = new.viewport / stride
        let index = Int((new.offset / stride + fraction * (visibleRows - 1)).rounded())
        scrollHintChannel = rows[min(max(index, 0), rows.count - 1)]
        scrollHintFraction = fraction

        let now = Date()
        if now.timeIntervalSince(scrollWindowTime) > 0.5 {
            scrollWindowTime = now
            scrollWindowOffset = old.offset
        }
        if abs(new.offset - scrollWindowOffset) > stride * 2.5 { scrollHintVisible = true }

        scrollHintHide?.cancel()
        let work = DispatchWorkItem { scrollHintVisible = false }
        scrollHintHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func restoreFocusToLastChannel() {
        guard let id = lastOpenedChannelID,
              let channel = visibleChannels.first(where: { $0.id == id }) else {
            NSLog("Guide: nothing to restore (last=%@)", lastOpenedChannelID ?? "nil")
            return
        }
        let segs = segments(for: channel)
        let current = segs.first(where: { $0.start <= now && now < $0.stop }) ?? segs.first
        guard let seg = current else { return }
        let cellID = "\(channel.id)|\(seg.id)"
        NSLog("Guide: restoring focus to %@", channel.name)
        restoreToken += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { focusedCellID = cellID }
    }

    private func timeHeader(rowWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: labelWidth, height: 1)
            HStack(spacing: 0) {
                ForEach(0..<4, id: \.self) { i in
                    Text(guideTimeFormatter.string(from: windowStart.addingTimeInterval(windowDuration * Double(i) / 4)))
                        .font(.callout.weight(.medium))
                        .foregroundColor(.white.opacity(0.65))
                        .frame(width: rowWidth / 4, alignment: .leading)
                }
            }
        }
    }

    // Faint half-hour gridlines spanning every row.
    private func gridOverlay(rowWidth: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(1..<4, id: \.self) { i in
                Rectangle()
                    .fill(Color.white.opacity(0.06))
                    .frame(width: 1)
                    .offset(x: labelWidth + rowWidth * CGFloat(i) / 4)
            }
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
    }

    private func segments(for channel: Channel) -> [GuideSegment] {
        guideSegments(for: eventsByChannel[channel.id] ?? [], from: windowStart, to: windowEnd)
    }

    private func updateHero(for cellID: String?) {
        guard let cellID else { return }
        let parts = cellID.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2,
              let channel = channels.first(where: { $0.id == parts[0] }),
              let segment = segments(for: channel).first(where: { $0.id == parts[1] }) else { return }
        heroChannel = channel
        heroSegment = segment
    }

    private func load(silent: Bool = false) {
        client.reloadConfiguration()
        if !silent {
            loading = true
            error = nil
        }
        let group = DispatchGroup()
        var fetchedChannels: [Channel] = []
        var fetchedEvents: [EPGEvent] = []
        var fetchedTags: [ChannelTag]?
        var fetchError: String?

        group.enter()
        client.fetchChannels { result in
            switch result {
            case .success(let list): fetchedChannels = list
            case .failure(let err): fetchError = err.localizedDescription
            }
            group.leave()
        }

        group.enter()
        client.fetchEPGEvents { result in
            switch result {
            case .success(let list): fetchedEvents = list
            case .failure(let err): fetchError = err.localizedDescription
            }
            group.leave()
        }

        group.enter()
        client.fetchChannelTags { result in
            // Tags are optional: a failure just leaves the filter unavailable.
            if case .success(let list) = result { fetchedTags = list }
            group.leave()
        }

        group.notify(queue: .main) {
            loading = false
            if let fetchError {
                // A failed background refresh keeps showing the existing guide.
                if !silent { error = fetchError }
                return
            }
            if let fetchedTags { filter.setTags(fetchedTags) }
            lastLoad = Date()
            now = Date()
            windowStart = GuideView.currentWindowStart()
            channels = fetchedChannels.sorted {
                (Double($0.number ?? "") ?? .greatestFiniteMagnitude) < (Double($1.number ?? "") ?? .greatestFiniteMagnitude)
            }
            eventsByChannel = Dictionary(grouping: fetchedEvents, by: \.channelUuid)
            if !silent, let firstChannel = visibleChannels.first, let firstSegment = segments(for: firstChannel).first {
                let id = "\(firstChannel.id)|\(firstSegment.id)"
                heroChannel = firstChannel
                heroSegment = firstSegment
                // The grid doesn't exist until this state change renders it, so the focus
                // request has to wait for that subtree to actually materialize.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    focusedCellID = id
                }
            }
        }
    }
}

// MARK: - Hero

private struct GuideHero: View {
    let channel: Channel?
    let segment: GuideSegment?
    let now: Date

    private var event: EPGEvent? { segment?.event }

    var body: some View {
        HStack(alignment: .top, spacing: 32) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 14) {
                    if let channel {
                        ChannelLogo(channel: channel)
                            .frame(width: 64, height: 36)
                        Text([channel.number, channel.name].compactMap { $0 }.joined(separator: "  "))
                            .font(.callout.weight(.semibold))
                            .foregroundColor(.white.opacity(0.75))
                            .lineLimit(1)
                    }
                    if let status {
                        Text(status.text)
                            .font(.caption.weight(.bold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(status.color))
                            .foregroundColor(.white)
                    }
                    if let mark = event?.recordingMark {
                        RecordingBadge(mark: mark)
                            .font(.caption.weight(.bold))
                    }
                }

                Text(event?.title ?? "No program information")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundColor(.white)
                    .lineLimit(1)

                if let event {
                    HStack(spacing: 14) {
                        Text(timeLine(for: event))
                            .foregroundColor(guideAccent)
                        if let subtitle = event.subtitle, !subtitle.isEmpty {
                            Text(subtitle)
                                .foregroundColor(.white.opacity(0.85))
                                .lineLimit(1)
                        }
                    }
                    .font(.callout.weight(.medium))

                    if let details = event.description ?? event.summary, !details.isEmpty {
                        Text(details)
                            .font(.system(size: 22))
                            .foregroundColor(.white.opacity(0.6))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }

            Spacer(minLength: 0)

            if let imageURL = TVHClient.sharedInstance.imageURL(path: event?.imagePath) {
                AsyncImage(url: imageURL) { phase in
                    if case .success(let image) = phase {
                        image.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Color.white.opacity(0.06)
                    }
                }
                .frame(width: 208, height: 117)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
            }
        }
        .frame(height: 140)
        .animation(.easeInOut(duration: 0.15), value: segment?.id)
    }

    private var status: (text: String, color: Color)? {
        guard let event else { return nil }
        if event.start <= now && now < event.stop {
            let remaining = Int(event.stop.timeIntervalSince(now) / 60)
            return ("ON NOW  \u{2022}  \(remaining) MIN LEFT", .red.opacity(0.85))
        }
        if event.start > now {
            let minutes = Int(event.start.timeIntervalSince(now) / 60)
            let text = minutes < 60 ? "STARTS IN \(minutes) MIN" : "UPCOMING"
            return (text, guideAccent.opacity(0.85))
        }
        return ("ENDED", .gray.opacity(0.6))
    }

    private func timeLine(for event: EPGEvent) -> String {
        let minutes = Int(event.stop.timeIntervalSince(event.start) / 60)
        return "\(guideTimeFormatter.string(from: event.start)) \u{2013} \(guideTimeFormatter.string(from: event.stop))  \u{2022}  \(minutes) min"
    }
}

private struct ChannelLogo: View {
    let channel: Channel

    var body: some View {
        AsyncImage(url: TVHClient.sharedInstance.imageURL(path: channel.iconPath)) { phase in
            if case .success(let image) = phase {
                image.resizable().aspectRatio(contentMode: .fit).padding(6)
            } else {
                Text(channel.number ?? "")
                    .font(.headline)
                    .foregroundColor(.white.opacity(0.7))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.09)))
    }
}

// MARK: - Rows

private struct GuideRow: View {
    let channel: Channel
    let segments: [GuideSegment]
    let windowDuration: TimeInterval
    let labelWidth: CGFloat
    let rowWidth: CGFloat
    let now: Date
    var focusedCellID: FocusState<String?>.Binding
    let onSelect: (Channel, EPGEvent?) -> Void

    private var rowFocused: Bool {
        focusedCellID.wrappedValue?.hasPrefix(channel.id + "|") == true
    }

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            HStack(spacing: 16) {
                ChannelLogo(channel: channel)
                    .frame(width: 92, height: 56)
                VStack(alignment: .leading, spacing: 2) {
                    if let number = channel.number {
                        Text(number)
                            .font(.caption.weight(.bold))
                            .foregroundColor(guideAccent)
                    }
                    Text(channel.name)
                        .font(.callout.weight(.semibold))
                        .foregroundColor(rowFocused ? .white : .white.opacity(0.7))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .frame(width: labelWidth, alignment: .leading)

            HStack(spacing: 6) {
                ForEach(segments) { segment in
                    let cellID = "\(channel.id)|\(segment.id)"
                    SegmentLabel(
                        segment: segment,
                        width: max(rowWidth * segment.duration / windowDuration - 6, 1),
                        highlighted: focusedCellID.wrappedValue == cellID,
                        now: now
                    )
                    .focusable(true)
                    .focusEffectDisabled()
                    .focused(focusedCellID, equals: cellID)
                    .onTapGesture {
                        onSelect(channel, segment.event)
                    }
                }
            }
            .frame(width: rowWidth, alignment: .leading)
            .clipped()
        }
    }
}

// tvOS's default button focus chrome is a rounded "card" that .buttonStyle(.plain)
// alone doesn't remove, so the focus effect is disabled on the cell and this draws its
// own highlight instead, driven by GuideRow comparing the shared focusedCellID against
// this cell's own id (see GuideView for why, not @Environment(\.isFocused)).
private struct SegmentLabel: View {
    let segment: GuideSegment
    let width: CGFloat
    let highlighted: Bool
    let now: Date

    private var airingNow: Bool {
        guard let event = segment.event else { return false }
        return event.start <= now && now < event.stop
    }

    private var progress: Double {
        guard let event = segment.event, airingNow else { return 0 }
        return min(max(now.timeIntervalSince(event.start) / event.stop.timeIntervalSince(event.start), 0), 1)
    }

    private var fill: Color {
        if highlighted { return .white }
        if !segment.hasEvent { return Color.white.opacity(0.04) }
        return airingNow ? Color.white.opacity(0.17) : Color.white.opacity(0.09)
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: guideCellRadius)
                .fill(fill)

            VStack(alignment: .leading, spacing: 3) {
                Text(segment.title)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                if let event = segment.event, width > 150 {
                    Text("\(guideTimeFormatter.string(from: event.start)) \u{2013} \(guideTimeFormatter.string(from: event.stop))")
                        .font(.caption2)
                        .lineLimit(1)
                        .opacity(0.7)
                }
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .italic(!segment.hasEvent)
            .foregroundColor(textColor)

            if airingNow && width > 40 {
                Capsule()
                    .fill(highlighted ? guideAccent : guideAccent.opacity(0.9))
                    .frame(width: max((width - 28) * progress, 4), height: 4)
                    .padding(.leading, 14)
                    .padding(.bottom, 7)
            }
        }
        .frame(width: width, height: guideCellHeight)
        .overlay(alignment: .topTrailing) {
            if let mark = segment.event?.recordingMark, width > 40 {
                RecordingIcon(mark: mark)
                    .font(.callout)
                    .padding(10)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: guideCellRadius)
                .strokeBorder(highlighted ? guideAccent : Color.white.opacity(segment.hasEvent ? 0.1 : 0.05),
                              lineWidth: highlighted ? 4 : 1)
        )
        .shadow(color: highlighted ? guideAccent.opacity(0.55) : .clear, radius: 14)
    }

    private var textColor: Color {
        if highlighted { return .black }
        return segment.hasEvent ? .white : .white.opacity(0.35)
    }
}

// MARK: - Scroll hint

struct ScrollMetrics: Equatable {
    var offset: CGFloat
    var content: CGFloat
    var viewport: CGFloat
}

/// Bubble naming the channel at the scroll position, placed beside the system
/// scroll indicator's thumb (which sits at the right screen edge).
private struct ScrollHint: View {
    let channel: Channel?
    let fraction: CGFloat
    let visible: Bool

    private let bubbleHeight: CGFloat = 52
    // The system indicator's track, fitted to two screenshots of the real thumb
    // (near the top and near the bottom): it starts about 61 pt below the top of
    // the list and runs to the bottom edge.
    private let trackTop: CGFloat = 61
    private let trackBottomInset: CGFloat = 0
    private let thumbRadius: CGFloat = 24

    var body: some View {
        GeometryReader { geo in
            if let channel {
                HStack(spacing: 10) {
                    if let number = channel.number {
                        Text(number).font(.callout.weight(.bold))
                    }
                    Text(channel.name).font(.callout.weight(.medium)).lineLimit(1)
                }
                .foregroundColor(.white)
                .padding(.horizontal, 18)
                .frame(height: bubbleHeight)
                .background(Capsule().fill(guideAccent))
                .shadow(color: .black.opacity(0.5), radius: 6)
                .fixedSize()
                .frame(width: geo.size.width, alignment: .trailing)
                .offset(x: 5, y: trackTop + thumbRadius - bubbleHeight / 2
                        + fraction * (geo.size.height - trackBottomInset - trackTop - 2 * thumbRadius))
            }
        }
        .opacity(visible ? 1 : 0)
        .animation(.easeOut(duration: 0.2), value: visible)
        .allowsHitTesting(false)
    }
}
