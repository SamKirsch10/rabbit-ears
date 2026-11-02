// Shared/GuideFilter.swift
import SwiftUI
import Combine

/// Which channel tags the guide is filtered to. Empty selection = show all.
/// Shared between the toolbar button and the guide itself.
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
