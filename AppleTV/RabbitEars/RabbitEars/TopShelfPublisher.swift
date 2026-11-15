// AppleTV/RabbitEars/RabbitEars/TopShelfPublisher.swift
import Combine
import Foundation
import Security
import TVServices

/// Copies what the Top Shelf extension needs to reach the server into the app group the two share, then
/// asks the Home Screen to reload the shelf. The extension can't read this app's own defaults or keychain.
enum TopShelfPublisher {
    /// Must match ContentProvider in the extension.
    private static let appGroup = "group.site.kirsch.RabbitEars"
    private static let keychainService = "site.kirsch.RabbitEars.topshelf"
    /// The channel groups the shelf is limited to, chosen in Settings; empty means every channel.
    static let tagsKey = "topShelfSelectedTags"
    private static let mirroredKeys = ["tvhServerURL", "tvhUsername", tagsKey]

    static func publish() {
        guard let shared = UserDefaults(suiteName: appGroup) else { return }
        for key in mirroredKeys {
            if let value = UserDefaults.standard.object(forKey: key) {
                shared.set(value, forKey: key)
            } else {
                shared.removeObject(forKey: key)
            }
        }
        storePassword(KeychainStore.get(forKey: "tvhPassword"))
        // The guide moves on even when the settings don't, so reload every time.
        TVTopShelfContentProvider.topShelfContentDidChange()
    }

    private static func storePassword(_ password: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: "tvhPassword",
            kSecAttrAccessGroup as String: appGroup
        ]
        SecItemDelete(query as CFDictionary)
        guard !password.isEmpty else { return }
        var attributes = query
        attributes[kSecValueData as String] = Data(password.utf8)
        // Readable by the extension while the Apple TV sits at the Home Screen, not only after unlock.
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(attributes as CFDictionary, nil)
    }
}

/// A channel to open in live view, set when the app is opened from a Top Shelf tile
/// (rabbitears://live/<channel uuid>) and cleared once the guide has opened it.
final class DeepLinkRouter: ObservableObject {
    static let shared = DeepLinkRouter()

    @Published var liveChannelID: String?

    @discardableResult
    func handle(_ url: URL) -> Bool {
        guard url.scheme == "rabbitears", url.host == "live",
              let channelID = url.pathComponents.dropFirst().first, !channelID.isEmpty else { return false }
        liveChannelID = channelID
        return true
    }
}
