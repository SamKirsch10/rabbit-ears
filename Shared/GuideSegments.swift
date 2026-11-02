// Shared/GuideSegments.swift
import Foundation

struct GuideSegment: Identifiable {
    let title: String
    let start: Date // clipped to the visible window
    let stop: Date
    let event: EPGEvent?

    var hasEvent: Bool { event != nil }
    var id: String { "\(start.timeIntervalSince1970)-\(stop.timeIntervalSince1970)" }
    var duration: TimeInterval { stop.timeIntervalSince(start) }
}

/// Lays one channel's events across the guide window, clipped to it, with "No Data" segments filling
/// real gaps so the row is covered end to end.
func guideSegments(for events: [EPGEvent], from windowStart: Date, to windowEnd: Date) -> [GuideSegment] {
    let channelEvents = events
        .filter { $0.start < windowEnd && $0.stop > windowStart }
        .sorted { $0.start < $1.start }

    // Gaps shorter than this are rounding noise in broadcast EPG data (a show
    // starting a few seconds after the half hour). Rendering them makes a
    // sliver of a "No Data" cell, so the neighbouring program is
    // stretched across them instead.
    let minGap: TimeInterval = 120

    var result: [GuideSegment] = []
    var cursor = windowStart
    for event in channelEvents {
        var clippedStart = max(event.start, windowStart)
        let clippedStop = min(event.stop, windowEnd)
        let gap = clippedStart.timeIntervalSince(cursor)
        if gap >= minGap {
            result.append(GuideSegment(title: "No Data", start: cursor, stop: clippedStart, event: nil))
        } else if gap > 0 {
            clippedStart = cursor
        }
        result.append(GuideSegment(title: event.title, start: clippedStart, stop: clippedStop, event: event))
        cursor = clippedStop
    }
    let tail = windowEnd.timeIntervalSince(cursor)
    if tail >= minGap {
        result.append(GuideSegment(title: "No Data", start: cursor, stop: windowEnd, event: nil))
    } else if tail > 0, let last = result.last {
        result[result.count - 1] = GuideSegment(title: last.title, start: last.start, stop: windowEnd, event: last.event)
    }
    return result
}
