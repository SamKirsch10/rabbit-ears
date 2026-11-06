// Sources/ScrubStillView.swift
import SwiftUI

/// The frame the player is showing, drawn above the scrubber while scrubbing.
///
/// Two positions, deliberately: the still's *picture* comes from `stillTime` (the engine's clock once
/// a seek has landed, the requested position while one is in flight) and its *place* comes from
/// `currentTime` (where the scrubber's dot is). The engine's software host lands a seek on the
/// keyframe at or before the target, so the requested position runs seconds ahead of the frame on
/// screen; decoding the settled still at the dot is what made a fast scrub show a picture seconds
/// ahead of what ended up playing. Driving the still off the engine clock alone is the other failure:
/// the clock only moves at landings, and a burst of presses supersedes most of them, so the still
/// barely updates.
public struct ScrubStillView: View {
    @ObservedObject var provider: ClientSideThumbnailProvider
    /// Where the scrubber's dot sits.
    let currentTime: TimeInterval
    /// What the still decodes at. The controller hands over from the requested position to the
    /// engine's clock as soon as a seek lands, so a settled scrub describes the frame on screen while
    /// a held scrub keeps describing where the remote is going.
    let stillTime: TimeInterval
    let duration: TimeInterval
    /// Ask for stills only while the banner is up. A hidden still would pull bytes over the same link
    /// playback needs for a picture nobody is looking at.
    var isActive: Bool = true

    public init(provider: ClientSideThumbnailProvider, currentTime: TimeInterval,
                stillTime: TimeInterval, duration: TimeInterval, isActive: Bool = true) {
        self.provider = provider
        self.currentTime = currentTime
        self.stillTime = stillTime
        self.duration = duration
        self.isActive = isActive
    }

    /// Cache key for the position the still describes: changes only when a decode is worth firing,
    /// not on every 250 ms clock tick.
    private static let idleKey = TimeInterval(-1)

    public var body: some View {
        let key = isActive ? provider.key(for: stillTime, duration: duration) : Self.idleKey
        let progress = duration > 0 ? min(max(currentTime / duration, 0), 1) : 0

        // The still sits over the dot the scrubber draws at the same fraction, not at the banner's
        // leading edge: a picture floating to the left of the position it describes reads as an
        // unrelated widget. Same clamp as ScrubberBar's dot, so the two stay aligned at the ends.
        GeometryReader { geo in
            ScrubStillCell(image: provider.image(at: stillTime, duration: duration) ?? provider.lastImage)
                .position(x: Self.dotCenter(in: geo.size.width, progress: progress),
                          y: geo.size.height / 2)
        }
        .frame(height: ScrubStillCell.size.height)
        .task(id: key) {
            if key == Self.idleKey {
                provider.stop()
            } else {
                provider.fill(centeredAt: stillTime, duration: duration)
            }
        }
    }

    /// x of the still's centre on a scrubber of width `w`: where the dot is, clamped so the picture
    /// never runs past the ends. Mirrors ScrubberBar's dot placement (`w * progress`, clamped by half
    /// the dot's own size), so a change to one clamp has to change the other.
    static func dotCenter(in width: CGFloat, progress: Double,
                          halfSize: CGFloat = ScrubStillCell.size.width / 2) -> CGFloat {
        min(max(width * CGFloat(progress), halfSize), width - halfSize)
    }
}

/// The still, or the space it will occupy once decoded. Blank only before the first decode: after
/// that the view keeps the previous picture up until the current position's own still lands.
struct ScrubStillCell: View {
    /// Width the provider decodes at, shared with `ClientSideThumbnailProvider` so the picture lands
    /// at its native size instead of being rescaled. Sized for the tvOS banner on a 4K panel: 160
    /// read as a thumbnail and 208 still read small, so this is 208 grown another 60%.
    static let decodeWidth = 333
    /// 16:9 at the decode width.
    static let size = CGSize(width: CGFloat(decodeWidth), height: CGFloat(decodeWidth) * 9 / 16)

    let image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Color.white.opacity(0.08)
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
