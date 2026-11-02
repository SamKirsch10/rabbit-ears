// iOS/Recordings/RecordingsView.swift
import SwiftUI

/// The server's DVR entries, newest first, as on tvOS. Tap to play; swipe or long-press to delete.
struct RecordingsView: View {
    private let client = TVHClient.sharedInstance
    @State private var entries: [DVR.Entry] = []
    @State private var loading = true
    @State private var error: String?
    @State private var playing: DVR.Entry?
    @State private var pendingDelete: DVR.Entry?
    @State private var deleteError: String?

    var body: some View {
        Group {
            if loading && entries.isEmpty {
                ProgressView("Loading...")
            } else if let error, entries.isEmpty {
                ContentUnavailableView("Couldn't Load Recordings",
                                       systemImage: "exclamationmark.triangle",
                                       description: Text(error))
            } else if entries.isEmpty {
                ContentUnavailableView("No Recordings", systemImage: "recordingtape")
            } else {
                List(entries) { entry in
                    Button { playing = entry } label: {
                        RecordingRow(entry: entry)
                    }
                    .foregroundStyle(.primary)
                    .listRowBackground(Color.clear)
                    .swipeActions(allowsFullSwipe: false) {
                        Button { pendingDelete = entry } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        .tint(.red)
                    }
                    .contextMenu {
                        Button("Delete Recording", systemImage: "trash", role: .destructive) { pendingDelete = entry }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(guideBackground.ignoresSafeArea())
        .refreshable { await load() }
        .navigationTitle("Recordings")
        .fullScreenCover(item: $playing) { entry in
            RecordingPlayerView(entry: entry)
        }
        .task { await load() }
        .alert(
            "Delete recording?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            presenting: pendingDelete
        ) { entry in
            Button("Delete", role: .destructive) { delete(entry) }
            Button("Cancel", role: .cancel) {}
        } message: { entry in
            Text("\"\(entry.title)\" and its video file will be removed from the server.")
        }
        .alert(
            "Couldn't delete",
            isPresented: Binding(get: { deleteError != nil }, set: { if !$0 { deleteError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(deleteError ?? "")
        }
    }

    private func delete(_ entry: DVR.Entry) {
        client.deleteRecording(uuid: entry.id) { result in
            switch result {
            case .success:
                withAnimation { entries.removeAll { $0.id == entry.id } }
            case .failure(let err):
                deleteError = err.localizedDescription
            }
        }
    }

    private func load() async {
        client.reloadConfiguration()
        let result = await withCheckedContinuation { continuation in
            client.fetchDVREntries { continuation.resume(returning: $0) }
        }
        loading = false
        switch result {
        case .success(let list):
            error = nil
            entries = list.sorted { $0.start > $1.start }
        case .failure(let err):
            error = err.localizedDescription
        }
    }
}

private let recordingDayFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "EEE, MMM d"
    return f
}()

private struct RecordingRow: View {
    let entry: DVR.Entry

    @ObservedObject private var durations = RecordingDurations.shared

    // The show's slot, then how long the recording really is (see RecordingDurations).
    private var whenText: String {
        let slot = "\(recordingDayFormatter.string(from: entry.start)) · "
            + "\(entry.start.formatted(date: .omitted, time: .shortened)) – "
            + "\(entry.stop.formatted(date: .omitted, time: .shortened))"
        guard let length = durations.lengthText(of: entry) else { return slot }
        return slot + " · \(length)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.title)
                .font(.headline)
                .lineLimit(1)
            Text(whenText)
                .font(.caption.weight(.semibold))
                .foregroundStyle(guideAccent)
            if !entry.description.isEmpty {
                Text(entry.description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onAppear { durations.load(entry) }
    }
}
