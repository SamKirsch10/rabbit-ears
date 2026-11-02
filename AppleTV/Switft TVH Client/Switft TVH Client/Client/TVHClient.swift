// Sources/TVHClient.swift
import Foundation
import Alamofire

enum TVHClientError: LocalizedError {
    case notConfigured
    case noDVRConfigAvailable

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "No TVHeadend server configured yet."
        case .noDVRConfigAvailable:
            return "No DVR recording profile is configured on the server."
        }
    }
}

class TVHClient {
    static let sharedInstance = TVHClient()
    // Set by the UI once the user enters a server address; nil until then.
    var baseURL: URL?
    // Optional credentials; only applied when username is non-empty.
    var username: String?
    var password: String?
    private let session = Session()

    private func request(_ url: URL) -> DataRequest {
        let req = session.request(url)
        guard let username, !username.isEmpty else { return req }
        return req.authenticate(username: username, password: password ?? "")
    }

    // Re-reads server address/credentials from storage. Called by each screen before
    // fetching, rather than relying on a parent view's onAppear running first --
    // SwiftUI fires a child's onAppear before its parent's, so that ordering isn't safe.
    func reloadConfiguration() {
        guard let urlString = UserDefaults.standard.string(forKey: "tvhServerURL"),
              let url = URL(string: urlString) else {
            baseURL = nil
            return
        }
        baseURL = url
        username = UserDefaults.standard.string(forKey: "tvhUsername")
        password = KeychainStore.get(forKey: "tvhPassword")
    }

    // MARK: - Server Connection
    func connectToServer(completion: @escaping (Result<Void, Error>) -> Void) {
        guard let baseURL else {
            completion(.failure(TVHClientError.notConfigured))
            return
        }
        let infoURL = baseURL.appendingPathComponent("/api/serverinfo")
        request(infoURL)
            .validate()
            .responseDecodable(of: SystemInfo.self) { response in
                switch response.result {
                case .success:
                    completion(.success(()))
                case .failure(let error):
                    completion(.failure(error))
                }
            }
    }

    // MARK: - DVR Entries
    func fetchDVREntries(completion: @escaping (Result<[DVR.Entry], Error>) -> Void) {
        guard let baseURL else {
            completion(.failure(TVHClientError.notConfigured))
            return
        }
        guard let url = griddedURL(path: "/api/dvr/entry/grid") else {
            completion(.failure(TVHClientError.notConfigured))
            return
        }
        request(url)
            .validate()
            .responseDecodable(of: DVREntriesResponse.self) { response in
                completion(response.result.map { $0.entries }.mapError { $0 as Error })
            }
    }

    // MARK: - Channels
    func fetchChannels(completion: @escaping (Result<[Channel], Error>) -> Void) {
        guard let baseURL else {
            completion(.failure(TVHClientError.notConfigured))
            return
        }
        guard let url = griddedURL(path: "/api/channel/grid") else {
            completion(.failure(TVHClientError.notConfigured))
            return
        }
        request(url)
            .validate()
            .responseDecodable(of: ChannelsResponse.self) { response in
                completion(response.result.map { $0.entries }.mapError { $0 as Error })
            }
    }

    func fetchChannelTags(completion: @escaping (Result<[ChannelTag], Error>) -> Void) {
        guard let url = griddedURL(path: "/api/channeltag/grid") else {
            completion(.failure(TVHClientError.notConfigured))
            return
        }
        request(url)
            .validate()
            .responseDecodable(of: ChannelTagsResponse.self) { response in
                completion(response.result.map { $0.entries.filter { $0.enabled ?? true } }.mapError { $0 as Error })
            }
    }

    // TVHeadend's grid endpoints default to a page size of 50 when "limit" is omitted,
    // which silently truncates results on servers with more channels/entries than that.
    private func griddedURL(path: String, limit: Int = 1000) -> URL? {
        guard let baseURL,
              var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.queryItems = [URLQueryItem(name: "limit", value: String(limit))]
        return components.url
    }

    // MARK: - EPG
    // Fetches the whole known EPG window in one call (typically a few hundred to low
    // thousands of events); callers filter client-side to whatever time range they need,
    // since epg/events/grid's "start" param is a pagination offset, not a time filter.
    func fetchEPGEvents(completion: @escaping (Result<[EPGEvent], Error>) -> Void) {
        guard let baseURL else {
            completion(.failure(TVHClientError.notConfigured))
            return
        }
        guard var components = URLComponents(
            url: baseURL.appendingPathComponent("/api/epg/events/grid"),
            resolvingAgainstBaseURL: false
        ) else {
            completion(.failure(TVHClientError.notConfigured))
            return
        }
        components.queryItems = [
            URLQueryItem(name: "limit", value: "2000"),
            URLQueryItem(name: "sort", value: "start"),
            URLQueryItem(name: "dir", value: "ASC")
        ]
        guard let url = components.url else {
            completion(.failure(TVHClientError.notConfigured))
            return
        }
        request(url)
            .validate()
            .responseDecodable(of: EPGEventsResponse.self) { response in
                completion(response.result.map { $0.entries }.mapError { $0 as Error })
            }
    }

    // MARK: - Now Playing
    func fetchNowPlaying(channel: Channel, completion: @escaping (Result<EPGEvent?, Error>) -> Void) {
        guard let baseURL else {
            completion(.failure(TVHClientError.notConfigured))
            return
        }
        guard var components = URLComponents(
            url: baseURL.appendingPathComponent("/api/epg/events/grid"),
            resolvingAgainstBaseURL: false
        ) else {
            completion(.failure(TVHClientError.notConfigured))
            return
        }
        components.queryItems = [
            URLQueryItem(name: "mode", value: "now"),
            URLQueryItem(name: "channel", value: channel.id),
            URLQueryItem(name: "limit", value: "1")
        ]
        guard let url = components.url else {
            completion(.failure(TVHClientError.notConfigured))
            return
        }
        request(url)
            .validate()
            .responseDecodable(of: EPGEventsResponse.self) { response in
                completion(response.result.map { $0.entries.first }.mapError { $0 as Error })
            }
    }

    // MARK: - Recording
    func createRecording(eventID: Int, completion: @escaping (Result<Void, Error>) -> Void) {
        fetchDefaultDVRConfigUUID { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let configUUID):
                self.submitRecording(eventID: eventID, configUUID: configUUID, completion: completion)
            }
        }
    }

    private func fetchDefaultDVRConfigUUID(completion: @escaping (Result<String, Error>) -> Void) {
        guard let baseURL else {
            completion(.failure(TVHClientError.notConfigured))
            return
        }
        let url = baseURL.appendingPathComponent("/api/dvr/config/grid")
        request(url)
            .validate()
            .responseDecodable(of: DVRConfigsResponse.self) { response in
                switch response.result {
                case .success(let configs):
                    if let uuid = configs.entries.first?.uuid {
                        completion(.success(uuid))
                    } else {
                        completion(.failure(TVHClientError.noDVRConfigAvailable))
                    }
                case .failure(let error):
                    completion(.failure(error))
                }
            }
    }

    private func submitRecording(eventID: Int, configUUID: String, completion: @escaping (Result<Void, Error>) -> Void) {
        guard let baseURL else {
            completion(.failure(TVHClientError.notConfigured))
            return
        }
        guard var components = URLComponents(
            url: baseURL.appendingPathComponent("/api/dvr/entry/create_by_event"),
            resolvingAgainstBaseURL: false
        ) else {
            completion(.failure(TVHClientError.notConfigured))
            return
        }
        components.queryItems = [
            URLQueryItem(name: "event_id", value: String(eventID)),
            URLQueryItem(name: "config_uuid", value: configUUID)
        ]
        guard let url = components.url else {
            completion(.failure(TVHClientError.notConfigured))
            return
        }
        request(url)
            .validate()
            .response { response in
                completion(response.result.map { _ in () }.mapError { $0 as Error })
            }
    }

    /// Deletes a recording (and its file); for an upcoming entry this cancels it.
    func deleteRecording(uuid: String, completion: @escaping (Result<Void, Error>) -> Void) {
        guard let baseURL,
              var components = URLComponents(
                url: baseURL.appendingPathComponent("/api/dvr/entry/remove"),
                resolvingAgainstBaseURL: false
              ) else {
            completion(.failure(TVHClientError.notConfigured))
            return
        }
        components.queryItems = [URLQueryItem(name: "uuid", value: uuid)]
        guard let url = components.url else {
            completion(.failure(TVHClientError.notConfigured))
            return
        }
        request(url)
            .validate()
            .response { response in
                completion(response.result.map { _ in () }.mapError { $0 as Error })
            }
    }

    // MARK: - Images
    // Icon/artwork paths from the API (e.g. "imagecache/52") are relative to the server;
    // some sources instead give a full external URL, which is passed through unchanged.
    func imageURL(path: String?) -> URL? {
        guard let path, !path.isEmpty else { return nil }
        if let absolute = URL(string: path), absolute.scheme != nil {
            return absolute
        }
        return baseURL?.appendingPathComponent(path)
    }

    // MARK: - Live Streaming
    // Builds the passthrough stream URL for a channel, embedding credentials (if any)
    // as URL userinfo since AVPlayer doesn't go through our Alamofire session.
    func streamURL(for channel: Channel) -> URL? {
        guard let baseURL, var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.path = "/stream/channel/\(channel.id)"
        if let username, !username.isEmpty {
            components.user = username
            components.password = password ?? ""
        }
        return components.url
    }

    // MARK: - DVR Playback
    // Unlike live streaming, this serves a finite, already-recorded file and
    // fully supports HTTP Range requests (confirmed against a real server),
    // so the player can seek within it natively -- no special handling needed.
    func recordingURL(for entry: DVR.Entry) -> URL? {
        guard let baseURL, var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.path = "/dvrfile/\(entry.id)"
        if let username, !username.isEmpty {
            components.user = username
            components.password = password ?? ""
        }
        return components.url
    }

    // MARK: - Session cleanup
    func cleanup() {
        session.cancelAllRequests()
    }

    // MARK: - Disconnect
    func disconnect() {
        session.cancelAllRequests()
    }
}

// MARK: - Models

nonisolated struct SystemInfo: Decodable, Sendable {
    let name: String
    let swVersion: String
    let apiVersion: Int

    private enum CodingKeys: String, CodingKey {
        case name
        case swVersion = "sw_version"
        case apiVersion = "api_version"
    }
}

nonisolated struct DVREntriesResponse: Decodable, Sendable {
    let entries: [DVR.Entry]
}

nonisolated struct DVRConfigsResponse: Decodable, Sendable {
    let entries: [DVRConfig]
}

nonisolated struct DVRConfig: Decodable, Sendable {
    let uuid: String
}

nonisolated struct ChannelsResponse: Decodable, Sendable {
    let entries: [Channel]
}

nonisolated struct Channel: Decodable, Identifiable, Sendable, Hashable {
    let id: String
    let name: String
    let number: String?
    let iconPath: String?
    let tags: [String]?

    private enum CodingKeys: String, CodingKey {
        case id = "uuid"
        case name
        case number
        case iconPath = "icon_public_url"
        case tags
    }
}

nonisolated struct ChannelTag: Decodable, Identifiable, Sendable, Hashable {
    let id: String
    let name: String
    let enabled: Bool?

    private enum CodingKeys: String, CodingKey {
        case id = "uuid"
        case name
        case enabled
    }
}

nonisolated struct ChannelTagsResponse: Decodable, Sendable {
    let entries: [ChannelTag]
}

nonisolated struct EPGEventsResponse: Decodable, Sendable {
    let entries: [EPGEvent]
}

nonisolated struct EPGEvent: Decodable, Identifiable, Sendable {
    let id: Int
    let channelUuid: String
    let title: String
    let subtitle: String?
    let summary: String?
    let description: String?
    let imagePath: String?
    let start: Date
    let stop: Date

    private enum CodingKeys: String, CodingKey {
        case id = "eventId"
        case channelUuid
        case title
        case subtitle
        case summary
        case description
        case imagePath = "image"
        case start
        case stop
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        channelUuid = try container.decode(String.self, forKey: .channelUuid)
        title = try container.decode(String.self, forKey: .title)
        subtitle = try? container.decode(String.self, forKey: .subtitle)
        summary = try? container.decode(String.self, forKey: .summary)
        description = try? container.decode(String.self, forKey: .description)
        imagePath = try? container.decode(String.self, forKey: .imagePath)
        let startEpoch = try container.decode(TimeInterval.self, forKey: .start)
        let stopEpoch = try container.decode(TimeInterval.self, forKey: .stop)
        start = Date(timeIntervalSince1970: startEpoch)
        stop = Date(timeIntervalSince1970: stopEpoch)
    }
}

nonisolated struct DVR: Decodable {
    struct Entry: Decodable, Identifiable, Sendable {
        let id: String
        let title: String
        let description: String
        let start: Date
        let stop: Date

        private enum CodingKeys: String, CodingKey {
            case id = "uuid"
            case title = "disp_title"
            case description = "disp_description"
            case start
            case stop
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            title = try container.decode(String.self, forKey: .title)
            description = (try? container.decode(String.self, forKey: .description)) ?? ""
            let startEpoch = try container.decode(TimeInterval.self, forKey: .start)
            let stopEpoch = try container.decode(TimeInterval.self, forKey: .stop)
            start = Date(timeIntervalSince1970: startEpoch)
            stop = Date(timeIntervalSince1970: stopEpoch)
        }
    }
}
