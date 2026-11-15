// AppleTV/RabbitEars/TopShelf/ContentProvider.swift
import TVServices
import UIKit

/// The Top Shelf row shown above the app on the Home Screen: a large tile per channel with what's on
/// now and next. Selecting one opens the app straight into that channel's live view.
///
/// The extension can't see the app's defaults or keychain, so it reads the server settings the app
/// copies into their shared app group (TopShelfPublisher, on the app side), and talks to the server
/// itself with URLSession rather than linking Alamofire.
final class ContentProvider: TVTopShelfContentProvider {
    /// Must match TopShelfPublisher in the app.
    private static let appGroup = "group.site.kirsch.RabbitEars"
    private static let keychainService = "site.kirsch.RabbitEars.topshelf"
    private static let maxChannels = 20

    override func loadTopShelfContent() async -> (any TVTopShelfContent)? {
        guard let server = ServerSettings.load() else { return nil }
        let client = ShelfClient(server: server)
        do {
            async let channelList = client.channels()
            async let eventList = client.events()
            let (channels, events) = try await (channelList, eventList)

            let now = Date()
            let byChannel = Dictionary(grouping: events.filter { $0.stop > now }, by: \.channelUuid)
                .mapValues { $0.sorted { $0.start < $1.start } }
            let shown = channels
                .filter { server.tagFilter.isEmpty || !server.tagFilter.isDisjoint(with: $0.tags ?? []) }
                .sorted { $0.sortNumber < $1.sortNumber }
                .compactMap { channel -> (ShelfChannel, ShelfEvent, ShelfEvent?)? in
                    guard let upcoming = byChannel[channel.id],
                          let current = upcoming.first, current.start <= now else { return nil }
                    return (channel, current, upcoming.dropFirst().first)
                }
                .prefix(Self.maxChannels)

            let tiles = TileStore()
            let items = await withTaskGroup(of: (Int, TVTopShelfSectionedItem).self) { group in
                for (index, (channel, current, next)) in shown.enumerated() {
                    group.addTask {
                        async let logo = client.image(path: channel.iconPath)
                        async let art = client.image(path: current.imagePath)
                        let tile = TileRenderer.render(channel: channel, current: current, next: next,
                                                       logo: await logo, art: await art)
                        let file = tiles.save(tile, name: "\(channel.id)-\(current.id)")
                        return (index, Self.item(channel: channel, current: current, image: file, now: now))
                    }
                }
                var made: [(Int, TVTopShelfSectionedItem)] = []
                for await item in group { made.append(item) }
                return made.sorted { $0.0 < $1.0 }.map(\.1)
            }
            tiles.removeAll(except: Set(shown.map { "\($0.0.id)-\($0.1.id)" }))
            guard !items.isEmpty else { return nil }

            let section = TVTopShelfItemCollection(items: items)
            section.title = "On Now"
            return TVTopShelfSectionedContent(sections: [section])
        } catch {
            NSLog("TopShelf: load failed: %@", error.localizedDescription)
            return nil
        }
    }

    private static func item(channel: ShelfChannel, current: ShelfEvent, image: URL?,
                             now: Date) -> TVTopShelfSectionedItem {
        let item = TVTopShelfSectionedItem(identifier: channel.id)
        item.title = current.title
        item.imageShape = .hdtv
        if let image { item.setImageURL(image, for: [.screenScale1x, .screenScale2x]) }
        let length = current.stop.timeIntervalSince(current.start)
        if length > 0 { item.playbackProgress = min(1, max(0, now.timeIntervalSince(current.start) / length)) }
        // Both Select and Play/Pause go straight to live; the app handles this URL in SceneDelegate.
        if let url = URL(string: "rabbitears://live/\(channel.id)") {
            item.displayAction = TVTopShelfAction(url: url)
            item.playAction = TVTopShelfAction(url: url)
        }
        return item
    }

    // MARK: - Server settings

    fileprivate struct ServerSettings {
        let baseURL: URL
        let username: String?
        let password: String?
        let tagFilter: Set<String>

        static func load() -> ServerSettings? {
            guard let shared = UserDefaults(suiteName: ContentProvider.appGroup),
                  let urlString = shared.string(forKey: "tvhServerURL"), !urlString.isEmpty,
                  let url = URL(string: urlString) else { return nil }
            return ServerSettings(baseURL: url,
                                  username: shared.string(forKey: "tvhUsername"),
                                  password: readPassword(),
                                  tagFilter: Set(shared.stringArray(forKey: "topShelfSelectedTags") ?? []))
        }

        private static func readPassword() -> String? {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: ContentProvider.keychainService,
                kSecAttrAccount as String: "tvhPassword",
                kSecAttrAccessGroup as String: ContentProvider.appGroup,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne
            ]
            var result: AnyObject?
            guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
                  let data = result as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        }
    }
}

// MARK: - Server access

/// Just enough of TVHClient for the shelf: channels, the EPG, and images, with the same credentials.
private final class ShelfClient: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let server: ContentProvider.ServerSettings
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    init(server: ContentProvider.ServerSettings) {
        self.server = server
    }

    func channels() async throws -> [ShelfChannel] {
        try await grid("/api/channel/grid", query: [URLQueryItem(name: "limit", value: "1000")])
    }

    // The whole EPG window, as the guide fetches it; the first event per channel still ending later
    // is what's on now.
    func events() async throws -> [ShelfEvent] {
        try await grid("/api/epg/events/grid", query: [
            URLQueryItem(name: "limit", value: "2000"),
            URLQueryItem(name: "sort", value: "start"),
            URLQueryItem(name: "dir", value: "ASC")
        ])
    }

    /// An icon or program image, or nil if there's none or it won't load. Paths like "imagecache/52" are
    /// relative to the server; full URLs pass through.
    func image(path: String?) async -> UIImage? {
        guard let path, !path.isEmpty else { return nil }
        let url: URL
        if let absolute = URL(string: path), absolute.scheme != nil {
            url = absolute
        } else {
            url = server.baseURL.appendingPathComponent(path)
        }
        guard let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return UIImage(data: data)
    }

    private func grid<T: Decodable>(_ path: String, query: [URLQueryItem]) async throws -> [T] {
        guard var components = URLComponents(url: server.baseURL.appendingPathComponent(path),
                                             resolvingAgainstBaseURL: false) else { throw URLError(.badURL) }
        components.queryItems = query
        guard let url = components.url else { throw URLError(.badURL) }
        let (data, response) = try await session.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(GridResponse<T>.self, from: data).entries
    }

    // tvheadend asks for Basic or Digest depending on its config; answering the challenge covers both.
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let method = challenge.protectionSpace.authenticationMethod
        guard method == NSURLAuthenticationMethodHTTPBasic || method == NSURLAuthenticationMethodHTTPDigest,
              challenge.previousFailureCount == 0,
              let username = server.username, !username.isEmpty else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential,
                          URLCredential(user: username, password: server.password ?? "", persistence: .forSession))
    }
}

private struct GridResponse<T: Decodable>: Decodable {
    let entries: [T]
}

private struct ShelfChannel: Decodable, Sendable {
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

    /// Guide order: by channel number, unnumbered channels last.
    var sortNumber: Double { Double(number ?? "") ?? .greatestFiniteMagnitude }
}

private struct ShelfEvent: Decodable, Sendable {
    let id: Int
    let channelUuid: String
    let title: String
    let imagePath: String?
    let start: Date
    let stop: Date

    private enum CodingKeys: String, CodingKey {
        case id = "eventId"
        case channelUuid
        case title
        case imagePath = "image"
        case start
        case stop
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        channelUuid = try container.decode(String.self, forKey: .channelUuid)
        title = try container.decode(String.self, forKey: .title)
        imagePath = try? container.decode(String.self, forKey: .imagePath)
        start = Date(timeIntervalSince1970: try container.decode(TimeInterval.self, forKey: .start))
        stop = Date(timeIntervalSince1970: try container.decode(TimeInterval.self, forKey: .stop))
    }
}

// MARK: - Tiles

/// Rendered tiles, kept in the app group's caches where the Home Screen can read them. Each file is named
/// for its channel and program, so a new program is a new URL rather than a stale cached image.
private struct TileStore: Sendable {
    private let directory: URL? = FileManager.default
        .containerURL(forSecurityApplicationGroupIdentifier: "group.site.kirsch.RabbitEars")?
        .appendingPathComponent("Library/Caches/TopShelf", isDirectory: true)

    func save(_ image: UIImage, name: String) -> URL? {
        guard let directory, let data = image.jpegData(compressionQuality: 0.85) else { return nil }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("\(name).jpg")
        do {
            try data.write(to: file, options: .atomic)
            return file
        } catch {
            return nil
        }
    }

    func removeAll(except keep: Set<String>) {
        guard let directory,
              let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        else { return }
        for file in files where !keep.contains(file.deletingPathExtension().lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
    }
}

/// Draws a 16:9 tile: program art (or the guide's navy gradient) behind the channel logo, with the
/// program title, its time and what's next along the bottom.
private enum TileRenderer {
    // The sectioned 16:9 tile is 548 x 308 pt; drawn at 2x.
    static let size = CGSize(width: 1096, height: 616)

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter
    }()

    static func render(channel: ShelfChannel, current: ShelfEvent, next: ShelfEvent?,
                       logo: UIImage?, art: UIImage?) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            let cg = context.cgContext
            let bounds = CGRect(origin: .zero, size: size)
            let space = CGColorSpaceCreateDeviceRGB()

            if let art {
                art.draw(in: aspectFill(art.size, in: bounds))
                // Darken toward the bottom so the text stays readable over any picture.
                let shade = CGGradient(colorsSpace: space, colors: [
                    UIColor.black.withAlphaComponent(0.25).cgColor,
                    UIColor.black.withAlphaComponent(0.85).cgColor
                ] as CFArray, locations: [0.2, 1])!
                cg.drawLinearGradient(shade, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
            } else {
                let navy = CGGradient(colorsSpace: space, colors: [
                    UIColor(red: 0.10, green: 0.15, blue: 0.30, alpha: 1).cgColor,
                    UIColor(red: 0.02, green: 0.02, blue: 0.06, alpha: 1).cgColor
                ] as CFArray, locations: [0, 1])!
                cg.drawLinearGradient(navy, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
            }

            let inset: CGFloat = 52
            let shadow = NSShadow()
            shadow.shadowColor = UIColor.black.withAlphaComponent(0.6)
            shadow.shadowBlurRadius = 8

            // Channel identity, top left: the logo, or the name if there's no logo.
            let logoBox = CGRect(x: inset, y: inset - 8, width: 300, height: 140)
            if let logo {
                cg.saveGState()
                cg.setShadow(offset: .zero, blur: 12, color: UIColor.black.withAlphaComponent(0.5).cgColor)
                logo.draw(in: aspectFit(logo.size, in: logoBox))
                cg.restoreGState()
            } else {
                draw(channel.name, font: .systemFont(ofSize: 52, weight: .bold), color: .white, shadow: shadow,
                     in: CGRect(x: inset, y: inset, width: size.width - inset * 2 - 160, height: 130))
            }
            if let number = channel.number, !number.isEmpty {
                let font = UIFont.monospacedDigitSystemFont(ofSize: 44, weight: .semibold)
                let width = (number as NSString).size(withAttributes: [.font: font]).width
                draw(number, font: font, color: UIColor.white.withAlphaComponent(0.8), shadow: shadow,
                     in: CGRect(x: size.width - inset - width, y: inset, width: width + 4, height: 60))
            }

            // Program, bottom up: what's next, its time, then the title above them.
            var bottom = size.height - inset
            let detailFont = UIFont.systemFont(ofSize: 34, weight: .medium)
            let detailColor = UIColor.white.withAlphaComponent(0.75)
            if let next {
                bottom -= 44
                draw("Next: \(next.title) at \(timeFormatter.string(from: next.start))", font: detailFont,
                     color: detailColor, shadow: shadow,
                     in: CGRect(x: inset, y: bottom, width: size.width - inset * 2, height: 44))
            }
            bottom -= 48
            draw("\(timeFormatter.string(from: current.start)) – \(timeFormatter.string(from: current.stop))",
                 font: detailFont, color: detailColor, shadow: shadow,
                 in: CGRect(x: inset, y: bottom, width: size.width - inset * 2, height: 44))

            let titleFont = UIFont.systemFont(ofSize: 64, weight: .bold)
            let titleRect = CGRect(x: inset, y: 0, width: size.width - inset * 2, height: titleFont.lineHeight * 2 + 4)
            let titleHeight = ceil(boundingHeight(current.title, font: titleFont, width: titleRect.width,
                                                  maxHeight: titleRect.height))
            draw(current.title, font: titleFont, color: .white, shadow: shadow,
                 in: CGRect(x: inset, y: bottom - 6 - titleHeight, width: titleRect.width, height: titleHeight))
        }
    }

    private static func attributes(font: UIFont, color: UIColor, shadow: NSShadow) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        return [.font: font, .foregroundColor: color, .shadow: shadow, .paragraphStyle: paragraph]
    }

    private static func draw(_ text: String, font: UIFont, color: UIColor, shadow: NSShadow, in rect: CGRect) {
        (text as NSString).draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                attributes: attributes(font: font, color: color, shadow: shadow), context: nil)
    }

    private static func boundingHeight(_ text: String, font: UIFont, width: CGFloat, maxHeight: CGFloat) -> CGFloat {
        let rect = (text as NSString).boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                                                   options: [.usesLineFragmentOrigin], attributes: [.font: font],
                                                   context: nil)
        return min(rect.height, maxHeight)
    }

    private static func aspectFill(_ image: CGSize, in rect: CGRect) -> CGRect {
        guard image.width > 0, image.height > 0 else { return rect }
        let scale = max(rect.width / image.width, rect.height / image.height)
        let size = CGSize(width: image.width * scale, height: image.height * scale)
        return CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height)
    }

    private static func aspectFit(_ image: CGSize, in rect: CGRect) -> CGRect {
        guard image.width > 0, image.height > 0 else { return rect }
        let scale = min(rect.width / image.width, rect.height / image.height)
        let size = CGSize(width: image.width * scale, height: image.height * scale)
        // Left-aligned in the box, vertically centred.
        return CGRect(x: rect.minX, y: rect.midY - size.height / 2, width: size.width, height: size.height)
    }
}
