// Sources/ClientSideThumbnailProvider.swift
import AetherEngine
import Combine
import Foundation
import SwiftUI

/// The client-side still shown at the playhead while scrubbing.
///
/// One still, not a strip: `FrameMode.thumbnail` is deliberately not frame-accurate (`FrameTypes.swift:37`,
/// `accepts` keeps any frame at or past the target and returns the first coarse keyframe it finds), so
/// every bucket in a sparse MPEG-2 recording resolves to the same keyframe and the cells repeat one
/// picture. `FrameMode.preview` decodes forward to the requested time, which is what a single still
/// beside the scrubber needs.
///
/// One decode at a time. `FrameExtractor.produce` retires the previous decode token on every new
/// request (`FrameExtractor/FrameExtractor.swift:300`), so requests fired together cancel each other
/// and all but the last return nil. This pump is the only caller of the extractor.
///
/// A held remote direction changes the position faster than a decode can finish, and cancelling on
/// every change retires each decode before it lands — a fast scrub then shows nothing. The pump is
/// chained instead: it decodes one position at a time and re-reads `target` after each decode returns,
/// so the newest position asked for is served next and the still keeps updating while presses keep
/// coming. `lastImage` keeps the cell filled while that position's own still is in flight.
///
/// A nil is a retry, not a verdict: elective stills yield while the playback pipeline is starved, and
/// the yield gate needs three healthy 1 Hz ticks to open (`shouldYield`, `yieldMinForwardBufferSeconds`).
/// Nothing is cached as empty, so the cell never sticks at blank.
///
/// The extractor belongs to whoever vended it. `AetherRecordingController` is that owner and the only
/// caller of `shutdown()`; this class owns only its own task.
@MainActor
public final class ClientSideThumbnailProvider: ObservableObject {
    /// How far a position has to move before a new still is worth decoding, and how the cache is
    /// keyed. This is the engine's own bucket quantum (`FrameExtractor`'s cache buckets at 1 s and
    /// floors), so a request and its cache entry cannot drift apart.
    ///
    /// A quantum, not a 10 s bucket: a still describes the frame the player is showing, and flooring
    /// the decode target to a scrubber step put it up to a whole step away from that frame. The
    /// position asked for is decoded exactly; only the cache key is floored.
    public static let quantum: TimeInterval = 1.0

    /// Wait after a pass that produced nothing. An elective `preview` yields while a seek restarts the
    /// producer, and until the forward buffer has held three healthy 1 Hz ticks (`shouldYield`,
    /// `yieldMinForwardBufferSeconds`), so a 1 s retry can be a whole second late for the moment that
    /// gate opens — the picture then describes a position the playhead has already left. 400 ms catches
    /// the opening without hammering the link: the pump only runs while a scrub is on screen (the view
    /// stops it otherwise), so a scrub costs a handful of retries, not a steady pull.
    private static let retryDelay: TimeInterval = 0.4

    /// Stills keyed by the quantized position, plus the order they were decoded in, so the cache can
    /// be trimmed as the playhead moves through a long recording.
    @Published private(set) var images: [TimeInterval: UIImage] = [:]
    private var order: [TimeInterval] = []

    /// The most recently decoded still, from any position. The cell shows it while the position's own
    /// decode is in flight, or while the pipeline is starved, so a scrub never blanks mid-flight. It is
    /// deliberately stale rather than nearest: it is the picture the user last saw.
    @Published private(set) var lastImage: UIImage?

    /// How many stills to keep. Sized against the still's own footprint: at the cell's decode width
    /// each still is a quarter of a megabyte, so this stays in the tens of megabytes. A scrub moves the
    /// dot in small increments, so the entries worth keeping are the ones it revisits as it doubles back.
    private static let cacheLimit = 32

    private let extractor: FrameExtractor
    private let maxWidth: Int

    /// Map a presentation position to the position on the extractor's source axis, or nil while the
    /// caller has not learned the axis yet: the provider then leaves the cell blank and retries instead
    /// of decoding at 0, which for a DVR recording means the first frame at every position.
    ///
    /// Absolute, not an offset: the mapping is a property of the clock, and the clock's answer beats a
    /// frame-derived one. A recording's first DECODED frame sits after the clock's anchor — measured on
    /// this DVR file, anchor 88515.993s against a first frame at 88518.574s — so an origin read from a
    /// decoded frame put every still 2.58 s ahead of the picture the session was showing.
    private let sourceSeconds: (TimeInterval) -> TimeInterval?

    /// The position the pump should serve next, newest wins. Exact, not floored: it is the frame the
    /// player is showing. nil = nothing wanted.
    private var target: TimeInterval?
    /// The position the published still describes, so a pump can tell a move worth a decode from a
    /// clock tick that is still inside the same quantum.
    private var served: TimeInterval?
    private var pump: Task<Void, Never>?

    /// Identity of the current pump. A retired pump must not clear the pump that replaced it when its
    /// cancelled decode returns, so every pump carries the generation it was started under.
    private var generation: UInt64 = 0

    /// The mapping is required, not defaulted: a DVR recording's display axis starts at 0 while its
    /// source axis starts hours into the stream, so a caller that passes 0 asks every bucket for a
    /// position before the stream begins and gets the first frame at every position.
    public init(extractor: FrameExtractor, maxWidth: Int = 160,
                sourceSeconds: @escaping (TimeInterval) -> TimeInterval?) {
        self.extractor = extractor
        self.maxWidth = maxWidth
        self.sourceSeconds = sourceSeconds
    }

    /// The cache key for a position: floored to `quantum`, the way the engine floors its own bucket.
    public func key(for time: TimeInterval, duration: TimeInterval) -> TimeInterval {
        Self.quantized(clamped(time, duration: duration))
    }

    public func image(at time: TimeInterval, duration: TimeInterval) -> UIImage? {
        images[key(for: time, duration: duration)]
    }

    /// A position clamped to the recording, so a stale or padded clock never asks for a frame that
    /// does not exist.
    private func clamped(_ time: TimeInterval, duration: TimeInterval) -> TimeInterval {
        min(max(0, time), max(0, duration))
    }

    /// Floor a position to the cache quantum. The engine's preview cache buckets the same way, so this
    /// is the finest key worth keeping an entry under.
    private static func quantized(_ position: TimeInterval) -> TimeInterval {
        (position / Self.quantum).rounded(.down) * Self.quantum
    }

    /// Point the pump at the position the player is showing. A running pump is not retired: it
    /// re-reads `target` when its decode returns, so a press that landed mid-decode is served next
    /// rather than cancelled.
    public func fill(centeredAt center: TimeInterval, duration: TimeInterval) {
        let position = clamped(center, duration: duration)
        if target == position { return }
        target = position
        let source = sourceSeconds(position)
        EngineLog.emit("[ScrubStill] fill center=\(String(format: "%.1f", center))s "
                       + "source=\(source.map { "\(String(format: "%.1f", $0))s" } ?? "axis unknown") "
                       + "duration=\(Int(duration))s")
        guard pump == nil else { return }
        generation += 1
        let generation = self.generation
        pump = Task { [weak self] in await self?.pumpStills(generation: generation) }
    }

    /// Decode one position at a time, newest first.
    ///
    /// `target` is re-read after every decode, so a press that arrived while a decode was in flight is
    /// served next: the picture changes at the rate decodes complete, which is what a held scrub needs.
    /// A move smaller than `quantum` is not worth a decode, so a 250 ms clock tick during playback
    /// costs nothing. A nil retries after `retryDelay` and then aims at whatever position is newest
    /// then, so a starved pipeline is not hammered and a mid-retry press is picked up not dropped.
    private func pumpStills(generation: UInt64) async {
        // Warm the context once per pump, before the first decode. The pump starts at scrub entry, and
        // after `idleInterval` (10 s) the extractor has closed its context and dropped its cache
        // (`scheduleIdleClose`), so the first miss of a scrub pays a demuxer reopen. `produce` yields
        // *before* it opens (`FrameExtractor.swift:314`, then `:327`), so opening here puts that reopen
        // inside the starved window a fresh seek already holds the pipeline in, and the decode that
        // finally gets through pays only decode time. It sits below the guards, so a pump with nothing
        // to decode never pulls bytes for nothing.
        var warmed = false
        while !Task.isCancelled {
            guard generation == self.generation, let target = self.target else { break }
            // A newer pump owns the extractor's decode token if one was started, so this pump stops
            // serving as soon as its generation is superseded.
            if let served, abs(target - served) < Self.quantum { break }
            if !warmed {
                warmed = true
                await extractor.prewarm()
            }
            if let image = await decode(at: target) {
                publish(image, at: target)
                EngineLog.emit("[ScrubStill] still t=\(String(format: "%.1f", target))s "
                               + "hash=\(Self.hash(of: image))")
                continue
            }
            // The pipeline is still starved. Give it a beat and retry rather than leaving blank.
            EngineLog.emit("[ScrubStill] still t=\(String(format: "%.1f", target))s nil, retrying")
            try? await Task.sleep(for: .seconds(Self.retryDelay))
        }
        if generation == self.generation { pump = nil }
    }

    /// Stop asking for stills. Does not tear the extractor down: its owner does that.
    public func stop() {
        pump?.cancel()
        pump = nil
        target = nil
        generation += 1
    }

    private func decode(at position: TimeInterval) async -> UIImage? {
        guard let source = sourceSeconds(position) else {
            // Blank is honest here. Decoding at 0 would hand back the recording's first frame for
            // every position, which is the symptom this provider exists to fix.
            EngineLog.emit("[ScrubStill] still t=\(String(format: "%.1f", position))s source axis unknown, retrying")
            return nil
        }
        guard let cgImage = await extractor.preview(at: source, maxWidth: maxWidth) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }

    /// A cheap fingerprint of the decoded pixels, so a run of identical stills is visible in the log
    /// rather than guessed from what the screen looks like.
    ///
    /// A sample, not a scan: a still is ~249 KB and this runs on every publish, so walking every byte
    /// was the most expensive thing a publish did. Every 64th byte (~3900 samples) still tells two
    /// frames apart; the byte count is folded into the seed so differing buffer sizes never collide. If
    /// two positions ever report the same hash, shorten the stride rather than go back to a full scan.
    private static func hash(of image: UIImage) -> String {
        guard let cgImage = image.cgImage,
              let data = cgImage.dataProvider?.data,
              let ptr = CFDataGetBytePtr(data) else { return "n/a" }
        let length = CFDataGetLength(data)
        var hash: UInt64 = 0xcbf29ce484222325 ^ UInt64(length)
        var offset = 0
        while offset < length {
            hash = (hash ^ UInt64(ptr[offset])) &* 0x100000001b3
            offset += 64
        }
        return String(hash, radix: 16)
    }

    private func publish(_ image: UIImage, at position: TimeInterval) {
        let key = Self.quantized(position)
        images[key] = image
        lastImage = image
        served = position
        order.append(key)
        while order.count > Self.cacheLimit {
            images.removeValue(forKey: order.removeFirst())
        }
    }
}
