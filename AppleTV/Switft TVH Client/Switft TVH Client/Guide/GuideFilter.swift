// Sources/GuideFilter.swift
import SwiftUI
import Combine

/// Which channel tags the guide is filtered to. Empty selection = show all.
/// Shared between the toolbar button (ContentView) and the guide itself.
final class GuideFilter: ObservableObject {
    @Published private(set) var tags: [ChannelTag] = []
    @Published private(set) var selected: Set<String>

    private static let defaultsKey = "guideSelectedTags"

    init() {
        let saved = UserDefaults.standard.stringArray(forKey: Self.defaultsKey) ?? []
        selected = Set(saved)
    }

    var isActive: Bool { !selected.isEmpty }

    func setTags(_ newTags: [ChannelTag]) {
        tags = newTags
        // Forget selections for tags that no longer exist on the server.
        let valid = selected.intersection(newTags.map(\.id))
        if valid != selected { selected = valid; persist() }
    }

    func toggle(_ tag: ChannelTag) {
        if selected.contains(tag.id) { selected.remove(tag.id) } else { selected.insert(tag.id) }
        persist()
    }

    func clear() {
        selected = []
        persist()
    }

    /// A channel passes if it carries at least one selected tag.
    func passes(_ channel: Channel) -> Bool {
        guard isActive else { return true }
        return !selected.isDisjoint(with: channel.tags ?? [])
    }

    private func persist() {
        UserDefaults.standard.set(Array(selected), forKey: Self.defaultsKey)
    }
}

/// Tag picker shown from the toolbar's filter button.
struct GuideFilterSheet: View {
    @ObservedObject var filter: GuideFilter
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Filter channels")
                .font(.title2.weight(.bold))
            Text(filter.isActive ? "Showing channels in any selected group." : "Showing all channels. Select groups to narrow the guide.")
                .font(.callout)
                .foregroundColor(.white.opacity(0.6))

            if filter.tags.isEmpty {
                Text("This server has no channel groups.")
                    .foregroundColor(.white.opacity(0.6))
            } else {
                ScrollView {
                    VStack(spacing: 14) {
                        ForEach(filter.tags) { tag in
                            Button { filter.toggle(tag) } label: {
                                HStack {
                                    Text(tag.name).font(.title3)
                                    Spacer()
                                    FilterCheck(isOn: filter.selected.contains(tag.id))
                                }
                                .padding(.horizontal, 28)
                                .padding(.vertical, 18)
                            }
                            .buttonStyle(FilterRowStyle())
                        }
                    }
                    .padding(.vertical, 8)
                }
            }

            HStack(spacing: 24) {
                Button("Clear") { filter.clear() }
                    .disabled(!filter.isActive)
                Button("Done", action: onClose)
            }
        }
        .padding(60)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            LinearGradient(
                colors: [Color(red: 0.06, green: 0.09, blue: 0.19), Color(red: 0.02, green: 0.02, blue: 0.06)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
        )
    }
}

struct FilterRowStyle: ButtonStyle {
    @Environment(\.isFocused) private var focused

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(focused ? .black : .white)
            .background(RoundedRectangle(cornerRadius: 16).fill(focused ? Color.white : Color.white.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 16)
                .strokeBorder(focused ? guideAccent : Color.white.opacity(0.12), lineWidth: focused ? 4 : 1))
            .animation(.easeOut(duration: 0.15), value: focused)
    }
}

private struct FilterCheck: View {
    let isOn: Bool
    @Environment(\.isFocused) private var focused

    var body: some View {
        Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
            .font(.title3)
            .foregroundColor(isOn ? guideAccent : (focused ? .black.opacity(0.45) : .white.opacity(0.45)))
    }
}
