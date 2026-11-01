// Sources/DVRListView.swift
import SwiftUI

struct DVRListView: View {
    private let client = TVHClient.sharedInstance
    @State private var entries: [DVR.Entry] = []
    @State private var loading = true
    @State private var error: String?
    @State private var selectedEntry: DVR.Entry?
    @State private var pendingDelete: DVR.Entry?
    // Plain focusable cards (like the guide): a Button would swallow the long press.
    @FocusState private var focusedID: String?
    @State private var deleteError: String?

    var body: some View {
        Group {
            if loading {
                ProgressView("Loading...")
            } else if let error {
                Text("Error: \(error)")
                    .foregroundColor(.red)
            } else if entries.isEmpty {
                Text("No recordings")
                    .font(.title3)
                    .foregroundColor(.white.opacity(0.6))
            } else {
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 22) {
                        ForEach(entries) { entry in
                            DVRCard(entry: entry, focused: focusedID == entry.id)
                                .focusable(true)
                                .focusEffectDisabled()
                                .focused($focusedID, equals: entry.id)
                                .onTapGesture { selectedEntry = entry }
                                // Hold select: tvOS context menu. Play/Pause: same prompt, directly.
                                .contextMenu {
                                    Button("Delete Recording", role: .destructive) { pendingDelete = entry }
                                }
                                .onPlayPauseCommand { pendingDelete = entry }
                        }
                    }
                    .padding(.horizontal, 60)
                    .padding(.vertical, 30)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            LinearGradient(
                colors: [Color(red: 0.06, green: 0.09, blue: 0.19), Color(red: 0.02, green: 0.02, blue: 0.06)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
        )
        .background(
            // Programmatic navigation, as in the guide: avoids NavigationLink's
            // tvOS focus halo on each card.
            NavigationLink(
                destination: Group {
                    if let selectedEntry { DVRPlayerView(entry: selectedEntry) }
                },
                isActive: Binding(
                    get: { selectedEntry != nil },
                    set: { isActive in if !isActive { selectedEntry = nil } }
                )
            ) { EmptyView() }
            .hidden()
        )
        .navigationTitle("DVR")
        .onAppear(perform: load)
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
                entries.removeAll { $0.id == entry.id }
            case .failure(let err):
                deleteError = err.localizedDescription
            }
        }
    }

    private func load() {
        client.reloadConfiguration()
        loading = true
        error = nil
        client.fetchDVREntries { result in
            loading = false
            switch result {
            case .success(let list):
                entries = list.sorted { $0.start > $1.start }
            case .failure(let err):
                error = err.localizedDescription
            }
        }
    }
}

private let dvrDayFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "EEE, MMM d"
    return f
}()

private struct DVRCard: View {
    let entry: DVR.Entry
    let focused: Bool

    private var whenText: String {
        let minutes = Int(entry.stop.timeIntervalSince(entry.start) / 60)
        let length = minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
        return "\(dvrDayFormatter.string(from: entry.start)) · "
            + "\(entry.start.formatted(date: .omitted, time: .shortened)) – "
            + "\(entry.stop.formatted(date: .omitted, time: .shortened)) · \(length)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(entry.title)
                .font(.title3.weight(.semibold))
                .lineLimit(1)
            Text(whenText)
                .font(.caption.weight(.semibold))
                .foregroundColor(guideAccent)
            if !entry.description.isEmpty {
                Text(entry.description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 28)
        .padding(.vertical, 20)
        // Same look as the guide cells: dark card, white fill with a blue border when focused.
        .foregroundColor(focused ? .black : .white)
        .background(RoundedRectangle(cornerRadius: 16).fill(focused ? Color.white : Color.white.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 16)
            .strokeBorder(focused ? guideAccent : Color.white.opacity(0.12), lineWidth: focused ? 4 : 1))
        .scaleEffect(focused ? 1.02 : 1)
        .animation(.easeOut(duration: 0.15), value: focused)
        .contentShape(RoundedRectangle(cornerRadius: 16))
    }
}
