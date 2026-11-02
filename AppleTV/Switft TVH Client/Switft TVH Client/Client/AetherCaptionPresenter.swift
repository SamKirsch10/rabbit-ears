// Sources/AetherCaptionPresenter.swift
import AetherEngine
import Combine
import Foundation

/// Keeps the engine's closed-caption track selected while captions are on, and picks the caption line
/// to draw from its cues. Cues are data; which ones show, and when, is the host's job. Shared by live
/// and recording playback.
final class AetherCaptionPresenter {
    private let engine: AetherEngine
    private let onText: (String?) -> Void
    private var isOn: Bool
    private var cancellables = Set<AnyCancellable>()

    init(engine: AetherEngine, isOn: Bool, onText: @escaping (String?) -> Void) {
        self.engine = engine
        self.isOn = isOn
        self.onText = onText

        // Caption tracks appear lazily, once the first caption data is seen in the video. The
        // publisher fires before the property changes, so look after it has.
        engine.$subtitleTracks
            .sink { [weak self] _ in DispatchQueue.main.async { self?.applyTrack() } }
            .store(in: &cancellables)

        Publishers.CombineLatest(engine.clock.$sourceTime, engine.$subtitleCues)
            .map { [weak self] time, cues in self?.activeCaption(at: time, in: cues) }
            .removeDuplicates()
            .sink { [weak self] in self?.onText($0) }
            .store(in: &cancellables)
    }

    func setOn(_ on: Bool) {
        isOn = on
        if !on { onText(nil) }
        applyTrack()
    }

    private func applyTrack() {
        if isOn {
            if engine.activeSubtitleTrackIndex == nil, let track = engine.subtitleTracks.first {
                engine.selectSubtitleTrack(index: track.id)
            }
        } else if engine.activeSubtitleTrackIndex != nil {
            engine.clearSubtitle()
        }
    }

    private func activeCaption(at time: Double, in cues: [SubtitleCue]) -> String? {
        guard isOn, !cues.isEmpty else { return nil }
        let lines = cues
            .filter { $0.startTime <= time && time < $0.endTime }
            .compactMap(\.text)
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}
