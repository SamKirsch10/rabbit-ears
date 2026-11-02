// iOS/Guide/ProgramDetailView.swift
import SwiftUI

/// What the tvOS guide shows in its hero panel for the focused program, as a sheet: channel, status,
/// times, artwork and description, plus Watch and Record (Stop or Cancel once it's recording).
struct ProgramDetailView: View {
    let channel: Channel
    let event: EPGEvent
    let now: Date
    let onWatch: () -> Void
    /// Called after a recording is made, stopped or cancelled here, so the guide can refresh its marks.
    let onRecordingChanged: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var busy = false
    /// Starts as the event's own DVR state and follows what's done here.
    @State private var mark: RecordingMark?
    @State private var dvrUuid: String?
    @State private var confirmStop = false
    @State private var recordError: String?

    init(channel: Channel, event: EPGEvent, now: Date,
         onWatch: @escaping () -> Void, onRecordingChanged: @escaping () -> Void) {
        self.channel = channel
        self.event = event
        self.now = now
        self.onWatch = onWatch
        self.onRecordingChanged = onRecordingChanged
        _mark = State(initialValue: event.recordingMark)
        _dvrUuid = State(initialValue: event.dvrUuid)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let imageURL = TVHClient.sharedInstance.imageURL(path: event.imagePath) {
                        AsyncImage(url: imageURL) { phase in
                            if case .success(let image) = phase {
                                image.resizable().aspectRatio(contentMode: .fill)
                            } else {
                                Color.white.opacity(0.06)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }

                    HStack(spacing: 10) {
                        ChannelLogo(channel: channel)
                            .frame(width: 56, height: 32)
                        Text([channel.number, channel.name].compactMap { $0 }.joined(separator: "  "))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.75))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        if let status {
                            Text(status.text)
                                .font(.caption2.weight(.bold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(status.color))
                                .foregroundStyle(.white)
                        }
                    }

                    Text(event.title)
                        .font(.title2.bold())

                    Text(timeLine)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(guideAccent)

                    if let subtitle = event.subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.headline)
                            .foregroundStyle(.white.opacity(0.85))
                    }

                    if let details = event.description ?? event.summary, !details.isEmpty {
                        Text(details)
                            .font(.body)
                            .foregroundStyle(.white.opacity(0.7))
                    }

                    if let recordError {
                        Text(recordError)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }

                    HStack(spacing: 12) {
                        Button(action: onWatch) {
                            Label(isAiring ? "Watch Live" : "Watch Channel", systemImage: "play.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)

                        Button {
                            if mark == nil { record() } else { confirmStop = true }
                        } label: {
                            Label(recordTitle, systemImage: mark == nil ? "record.circle" : "stop.circle.fill")
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .tint(.red)
                        .disabled(busy || event.stop <= now)
                    }
                    .controlSize(.large)
                    .padding(.top, 8)
                }
                .padding(20)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { dismiss() }
                }
            }
        }
        .tint(guideAccent)
        .presentationDetents([.medium, .large])
        .presentationBackground(guideBackground)
        .sensoryFeedback(.success, trigger: mark)
        .alert(mark == .scheduled ? "Cancel recording?" : "Stop recording?", isPresented: $confirmStop) {
            Button(mark == .scheduled ? "Cancel Recording" : "Stop Recording", role: .destructive) { stop() }
            Button("Keep Recording", role: .cancel) {}
        } message: {
            Text(mark == .scheduled
                 ? "\"\(event.title)\" won't be recorded."
                 : "\"\(event.title)\" stops recording now. What's been recorded so far is kept.")
        }
    }

    private var recordTitle: String {
        switch mark {
        case .recording: return "Stop Recording"
        case .scheduled: return "Cancel Recording"
        case nil: return "Record"
        }
    }

    private var isAiring: Bool { event.start <= now && now < event.stop }

    private var status: (text: String, color: Color)? {
        if isAiring {
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

    private var timeLine: String {
        let minutes = Int(event.stop.timeIntervalSince(event.start) / 60)
        let day = Calendar.current.isDateInToday(event.start) ? "" : event.start.formatted(.dateTime.weekday(.abbreviated)) + "  "
        return "\(day)\(guideTimeFormatter.string(from: event.start)) \u{2013} \(guideTimeFormatter.string(from: event.stop))  \u{2022}  \(minutes) min"
    }

    private func record() {
        busy = true
        recordError = nil
        let client = TVHClient.sharedInstance
        client.createRecording(eventID: event.id) { result in
            switch result {
            case .success:
                mark = isAiring ? .recording : .scheduled
                onRecordingChanged()
                // Find the new entry's uuid, which stopping or cancelling it needs.
                client.fetchDVREntries { entries in
                    busy = false
                    if case .success(let list) = entries {
                        dvrUuid = list.first { $0.broadcast == event.id }?.id
                    }
                }
            case .failure(let error):
                busy = false
                recordError = error.localizedDescription
            }
        }
    }

    private func stop() {
        guard let dvrUuid else {
            recordError = "Couldn't find this recording on the server."
            return
        }
        busy = true
        recordError = nil
        TVHClient.sharedInstance.stopRecording(uuid: dvrUuid, isRunning: mark == .recording) { result in
            busy = false
            switch result {
            case .success:
                mark = nil
                self.dvrUuid = nil
                onRecordingChanged()
            case .failure(let error):
                recordError = error.localizedDescription
            }
        }
    }
}
