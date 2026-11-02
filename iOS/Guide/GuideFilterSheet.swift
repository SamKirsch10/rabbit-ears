// iOS/Guide/GuideFilterSheet.swift
import SwiftUI

/// Tag picker shown from the guide's filter button.
struct GuideFilterSheet: View {
    @ObservedObject var filter: GuideFilter
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if filter.tags.isEmpty {
                    Text("This server has no channel groups.")
                        .foregroundStyle(.secondary)
                } else {
                    Section {
                        ForEach(filter.tags) { tag in
                            Button {
                                filter.toggle(tag)
                            } label: {
                                HStack {
                                    Text(tag.name)
                                    Spacer()
                                    if filter.selected.contains(tag.id) {
                                        Image(systemName: "checkmark")
                                            .fontWeight(.semibold)
                                            .foregroundStyle(guideAccent)
                                    }
                                }
                            }
                            .foregroundStyle(.primary)
                        }
                    } footer: {
                        Text(filter.isActive
                             ? "Showing channels in any selected group."
                             : "Showing all channels. Select groups to narrow the guide.")
                    }
                }
            }
            .navigationTitle("Filter Channels")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Clear") { filter.clear() }
                        .disabled(!filter.isActive)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
