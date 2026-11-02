// Sources/Captions.swift
import Foundation

/// Closed captions (ATSC CEA-608) arrive inside the MPEG-2 video; AetherEngine decodes CC1 and offers
/// it as a text track once it has seen caption data.
enum Captions {
    private static let key = "captionsEnabled"

    /// The user's preference, kept across channels and launches.
    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}
