// iOS/Guide/GuideView.swift
import SwiftUI
import Combine

let guideTimeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.timeStyle = .short
    return formatter
}()

/// Background behind the guide, the sticky channel column and the time header.
let guideBackground = Color(red: 0.04, green: 0.05, blue: 0.11)

private let guideCellGap: CGFloat = 4
private let guideCellRadius: CGFloat = 10
private let guideHeaderHeight: CGFloat = 30

/// The tvOS guide's grid for touch: rows of channels against a timeline that scrolls sideways, with
/// the channel column and time header pinned. Tap a channel to watch it, a program for its details.
struct GuideView: View {
    @ObservedObject var filter: GuideFilter
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.scenePhase) private var scenePhase
    private let client = TVHClient.sharedInstance

    // Rounded down to the current or previous half hour, as a TV guide normally starts. State, so it
    // moves forward as time passes (see the clock below).
    @State private var windowStart = GuideView.currentWindowStart()
    @State private var windowEnd = GuideView.currentWindowStart().addingTimeInterval(GuideView.minWindow)
    @State private var lastLoad = Date()
    @State private var channels: [Channel] = []
    @State private var eventsByChannel: [String: [EPGEvent]] = [:]
    @State private var loading = true
    @State private var error: String?
    @State private var now = Date()
    @State private var playing: Channel?
    @State private var selected: ProgramSelection?
    // Set by the details sheet's Watch button; the player opens once the sheet is gone.
    @State private var playAfterSheet: Channel?
    @State private var showingFilter = false
    @State private var showingServer = false
    @State private var position = ScrollPosition(edge: .leading)

    private static let minWindow: TimeInterval = 2 * 60 * 60
    private static let maxWindow: TimeInterval = 12 * 60 * 60
    private let clock = Timer.publish(every: 20, on: .main, in: .common).autoconnect()

    private var regular: Bool { horizontalSizeClass == .regular }
    private var pointsPerMinute: CGFloat { regular ? 6 : 4 }
    private var labelWidth: CGFloat { regular ? 132 : 76 }
    private var rowHeight: CGFloat { regular ? 72 : 64 }
    private var timelineWidth: CGFloat {
        CGFloat(windowEnd.timeIntervalSince(windowStart) / 60) * pointsPerMinute
    }
    private var visibleChannels: [Channel] { channels.filter(filter.passes) }

    var body: some View {
        Group {
            if loading && channels.isEmpty {
                ProgressView("Loading Guide...")
            } else if let error, channels.isEmpty {
                ContentUnavailableView("Couldn't Load the Guide",
                                       systemImage: "exclamationmark.triangle",
                                       description: Text(error))
            } else if visibleChannels.isEmpty {
                ContentUnavailableView("No channels match this filter",
                                       systemImage: "line.3.horizontal.decrease.circle")
            } else {
                grid
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(guideBackground.ignoresSafeArea())
        .navigationTitle("Guide")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Now") {
                    withAnimation { position.scrollTo(edge: .leading) }
                }
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    showingFilter = true
                } label: {
                    Image(systemName: filter.isActive
                          ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                }
                .accessibilityLabel(filter.isActive ? "Filter (\(filter.selected.count))" : "Filter")

                Button("Server", systemImage: "server.rack") { showingServer = true }
            }
        }
        .sheet(isPresented: $showingFilter) {
            GuideFilterSheet(filter: filter)
        }
        .sheet(isPresented: $showingServer) {
            NavigationStack {
                ServerSetupView { showingServer = false }
            }
        }
        .sheet(item: $selected, onDismiss: {
            if let channel = playAfterSheet {
                playAfterSheet = nil
                playing = channel
            }
        }) { selection in
            ProgramDetailView(channel: selection.channel, event: selection.event, now: now,
                              onWatch: {
                                  playAfterSheet = selection.channel
                                  selected = nil
                              },
                              onRecordingChanged: { load(silent: true) })
        }
        .fullScreenCover(item: $playing) { channel in
            LiveTVPlayerView(channel: channel)
        }
        .onAppear {
            load(silent: !channels.isEmpty)
        }
        .onReceive(clock) { date in
            now = date
            // Window rolled into a new half hour, or data is getting old: refresh in place.
            if windowStart != GuideView.currentWindowStart() || date.timeIntervalSince(lastLoad) > 10 * 60 {
                load(silent: true)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { load(silent: true) }
        }
    }

    // The horizontal scroll view holds the time header and a vertical scroll view of rows, so the
    // header stays put vertically and both scroll sideways together. Channel labels pin themselves to
    // the leading edge (see GuideRow).
    private var grid: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                TimeHeader(windowStart: windowStart, windowEnd: windowEnd, now: now,
                           pointsPerMinute: pointsPerMinute, labelWidth: labelWidth)
                // The rows take the height the horizontal scroll view offers, which stops at the tab
                // bar. A scroll view touching that edge gets stretched underneath the floating bar,
                // so the small bottom gap (below) keeps the rows clear of it on every screen size.
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(visibleChannels) { channel in
                            GuideRow(
                                channel: channel,
                                segments: guideSegments(for: eventsByChannel[channel.id] ?? [],
                                                        from: windowStart, to: windowEnd),
                                now: now,
                                nowX: nowX,
                                pointsPerMinute: pointsPerMinute,
                                labelWidth: labelWidth,
                                rowHeight: rowHeight,
                                showsName: regular,
                                onPlay: { playing = channel },
                                onSelect: { event in selected = ProgramSelection(channel: channel, event: event) }
                            )
                        }
                    }
                }
                .clipped()
                .padding(.bottom, 8)
            }
            .frame(width: labelWidth + timelineWidth, alignment: .leading)
        }
        .scrollPosition($position)
        // A horizontal scroll view draws into the side safe areas in landscape; the pinned
        // column sits at the safe edge, so clip anything that would show beside it.
        .clipped()
    }

    private var nowX: CGFloat? {
        guard now >= windowStart, now < windowEnd else { return nil }
        return CGFloat(now.timeIntervalSince(windowStart) / 60) * pointsPerMinute
    }

    private static func currentWindowStart() -> Date {
        let now = Date()
        var components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: now)
        components.minute = (components.minute ?? 0) < 30 ? 0 : 30
        return Calendar.current.date(from: components) ?? now
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
                if !silent || channels.isEmpty { error = fetchError }
                return
            }
            error = nil
            if let fetchedTags { filter.setTags(fetchedTags) }
            lastLoad = Date()
            now = Date()
            let start = GuideView.currentWindowStart()
            // As far ahead as the EPG reaches, in whole half hours, within min...max.
            let lastStop = fetchedEvents.map(\.stop).max() ?? start
            let span = min(max(lastStop.timeIntervalSince(start), GuideView.minWindow), GuideView.maxWindow)
            windowStart = start
            windowEnd = start.addingTimeInterval((span / 1800).rounded(.up) * 1800)
            channels = fetchedChannels.sorted {
                (Double($0.number ?? "") ?? .greatestFiniteMagnitude) < (Double($1.number ?? "") ?? .greatestFiniteMagnitude)
            }
            eventsByChannel = Dictionary(grouping: fetchedEvents, by: \.channelUuid)
        }
    }
}

struct ProgramSelection: Identifiable {
    let channel: Channel
    let event: EPGEvent
    var id: Int { event.id }
}

// MARK: - Header

private struct TimeHeader: View {
    let windowStart: Date
    let windowEnd: Date
    let now: Date
    let pointsPerMinute: CGFloat
    let labelWidth: CGFloat

    private var slots: Int { max(Int(windowEnd.timeIntervalSince(windowStart) / 1800), 1) }

    var body: some View {
        HStack(spacing: 0) {
            // Blank corner above the channel column, pinned like the labels so times slide under it.
            guideBackground
                .frame(width: labelWidth, height: guideHeaderHeight)
                .pinnedToLeadingEdge()
                .zIndex(1)
            HStack(spacing: 0) {
                ForEach(0..<slots, id: \.self) { i in
                    Text(guideTimeFormatter.string(from: windowStart.addingTimeInterval(Double(i) * 1800)))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.white.opacity(0.65))
                        .padding(.leading, 6)
                        .frame(width: 30 * pointsPerMinute, alignment: .leading)
                        .overlay(alignment: .leading) {
                            Rectangle().fill(Color.white.opacity(0.15)).frame(width: 1, height: 12)
                        }
                }
            }
        }
        .frame(height: guideHeaderHeight)
        .background(guideBackground)
    }
}

// MARK: - Rows

private struct GuideRow: View {
    let channel: Channel
    let segments: [GuideSegment]
    let now: Date
    let nowX: CGFloat?
    let pointsPerMinute: CGFloat
    let labelWidth: CGFloat
    let rowHeight: CGFloat
    let showsName: Bool
    let onPlay: () -> Void
    let onSelect: (EPGEvent) -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onPlay) {
                ChannelLabel(channel: channel, showsName: showsName)
                    .frame(width: labelWidth, height: rowHeight)
                    .background(guideBackground)
                    .overlay(alignment: .trailing) {
                        Rectangle().fill(Color.white.opacity(0.08)).frame(width: 1)
                    }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Watch \(channel.name)")
            .pinnedToLeadingEdge()
            .zIndex(1)

            HStack(spacing: guideCellGap) {
                ForEach(segments) { segment in
                    GuideCell(segment: segment,
                              width: max(CGFloat(segment.duration / 60) * pointsPerMinute - guideCellGap, 1),
                              height: rowHeight - 8,
                              now: now)
                        .onTapGesture {
                            if let event = segment.event { onSelect(event) }
                        }
                }
            }
            .padding(.leading, guideCellGap)
            .frame(height: rowHeight)
            .overlay(alignment: .topLeading) {
                if let nowX {
                    Rectangle()
                        .fill(Color.red.opacity(0.85))
                        .frame(width: 2, height: rowHeight)
                        .offset(x: nowX - 1)
                        .allowsHitTesting(false)
                }
            }
        }
    }
}

private struct ChannelLabel: View {
    let channel: Channel
    let showsName: Bool

    var body: some View {
        VStack(spacing: 4) {
            ChannelLogo(channel: channel)
                .frame(width: 60, height: 32)
            HStack(spacing: 4) {
                if let number = channel.number {
                    Text(number)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(guideAccent)
                }
                if showsName {
                    Text(channel.name)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 6)
    }
}

struct ChannelLogo: View {
    let channel: Channel

    var body: some View {
        AsyncImage(url: TVHClient.sharedInstance.imageURL(path: channel.iconPath)) { phase in
            if case .success(let image) = phase {
                image.resizable().aspectRatio(contentMode: .fit).padding(4)
            } else {
                Text(channel.number ?? "")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.09)))
    }
}

// Same look as the tvOS cells, minus focus: brighter while airing, with a progress bar.
private struct GuideCell: View {
    let segment: GuideSegment
    let width: CGFloat
    let height: CGFloat
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
        if !segment.hasEvent { return Color.white.opacity(0.04) }
        return airingNow ? Color.white.opacity(0.17) : Color.white.opacity(0.09)
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: guideCellRadius)
                .fill(fill)

            VStack(alignment: .leading, spacing: 2) {
                Text(segment.title)
                    .font(.footnote.weight(.semibold))
                    .lineLimit(width > 90 ? 1 : 2)
                if let event = segment.event, width > 90 {
                    Text("\(guideTimeFormatter.string(from: event.start)) \u{2013} \(guideTimeFormatter.string(from: event.stop))")
                        .font(.caption2)
                        .lineLimit(1)
                        .opacity(0.7)
                }
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .italic(!segment.hasEvent)
            .foregroundStyle(segment.hasEvent ? Color.white : Color.white.opacity(0.35))

            if airingNow && width > 24 {
                Capsule()
                    .fill(guideAccent)
                    .frame(width: max((width - 16) * progress, 3), height: 3)
                    .padding(.leading, 8)
                    .padding(.bottom, 5)
            }
        }
        .frame(width: width, height: height)
        .overlay(alignment: .topTrailing) {
            if let mark = segment.event?.recordingMark, width > 30 {
                RecordingIcon(mark: mark)
                    .font(.caption)
                    .padding(6)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: guideCellRadius)
                .strokeBorder(Color.white.opacity(segment.hasEvent ? 0.1 : 0.05), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: guideCellRadius))
    }
}

private extension View {
    /// Keeps the view at the leading edge of the horizontally scrolling guide: as the content scrolls
    /// left, the view is pushed right by the same amount.
    func pinnedToLeadingEdge() -> some View {
        visualEffect { content, proxy in
            content.offset(x: max(-proxy.frame(in: .scrollView(axis: .horizontal)).minX, 0))
        }
    }
}
