// Sources/PlaybackRequest.swift
import Foundation

/// A playback URL with its credentials moved out of the userinfo into a Basic header. TVHClient embeds
/// credentials in the URL; the engine reads through URLSession, so they go as a header instead (a
/// Digest-only server would need more).
struct PlaybackRequest {
    let url: URL
    let headers: [String: String]

    init?(_ url: URL?) {
        guard let url, var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        var headers: [String: String] = [:]
        if let user = parts.user, !user.isEmpty {
            headers["Authorization"] = "Basic " + Data("\(user):\(parts.password ?? "")".utf8).base64EncodedString()
        }
        parts.user = nil
        parts.password = nil
        guard let clean = parts.url else { return nil }
        self.url = clean
        self.headers = headers
    }
}
