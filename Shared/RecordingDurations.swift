// Shared/RecordingDurations.swift
import AetherEngine
import Combine
import Foundation

/// How long finished recordings really are, read from their files. tvheadend only reports the scheduled
/// window (padding included), which is wrong for a recording started late or stopped early.
final class RecordingDurations: ObservableObject {
    static let shared = RecordingDurations()

    @Published private(set) var seconds: [String: TimeInterval] = [:]
    private var inFlight = Set<String>()

    /// The file's length, once probed; nil before that, or for a recording that isn't finished.
    func duration(of entry: DVR.Entry) -> TimeInterval? {
        seconds[Self.key(entry)]
    }

    /// Probes a finished recording's file once (again only if its size changes). One still being written
    /// keeps growing, so it isn't probed.
    func load(_ entry: DVR.Entry) {
        let key = Self.key(entry)
        guard entry.isFinished, seconds[key] == nil, !inFlight.contains(key),
              let request = PlaybackRequest(TVHClient.sharedInstance.recordingURL(for: entry)) else { return }
        inFlight.insert(key)
        let url = request.url
        let headers = request.headers
        Task.detached(priority: .utility) {
            // Demux-only: reads the container's timing, no decoders, no playback session.
            let duration = try? AetherEngine.probe(url: url, options: LoadOptions(httpHeaders: headers)).durationSeconds
            await MainActor.run {
                self.inFlight.remove(key)
                if let duration, duration > 0 { self.seconds[key] = duration }
            }
        }
    }

    /// "1h 5m" / "15m" for list rows: the file's real length once a finished recording has been probed,
    /// the scheduled length for one still to come or in progress, nil while that probe is outstanding.
    func lengthText(of entry: DVR.Entry) -> String? {
        let length: TimeInterval
        if entry.isFinished {
            guard let probed = duration(of: entry) else { return nil }
            length = probed
        } else {
            length = entry.stop.timeIntervalSince(entry.start)
        }
        let minutes = Int((length / 60).rounded())
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }

    private static func key(_ entry: DVR.Entry) -> String {
        "\(entry.id)|\(entry.filesize ?? 0)"
    }
}
