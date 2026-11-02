// Sources/PlayerOverlays.swift
import AetherEngine
import SwiftUI

/// Draws the caption line the controller picked, in the style chosen in Settings. The engine hands
/// over cue text; painting it is ours.
struct CaptionOverlay: View {
    let text: String?

    var body: some View {
        if let text {
            VStack {
                Spacer()
                Text(text)
                    .font(.system(size: 44 * CGFloat(CaptionSettings.size.scale), weight: .semibold))
                    .foregroundColor(CaptionSettings.textColor.color)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .background(Color.black.opacity(Double(CaptionSettings.background.opacity) / 255))
                    .cornerRadius(6)
                    // The margin is in 720p video pixels; the screen is 1080 points tall.
                    .padding(.bottom, 60 + CGFloat(CaptionSettings.position.margin) * 1.5)
            }
            .frame(maxWidth: .infinity)
            .allowsHitTesting(false)
        }
    }
}

/// A centred error message over the video.
struct PlaybackFailureOverlay: View {
    let message: String?

    var body: some View {
        if let message {
            Text("Playback error: \(message)")
                .foregroundColor(.red)
                .padding()
                .background(Color.black.opacity(0.7))
                .cornerRadius(10)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Debug-build stats for judging playback (route, decoders, frame delivery). Long-press the video to
/// show or hide it. Split out so the engine's ~10 Hz clock only re-renders this overlay.
struct AetherStatsOverlay: View {
    @ObservedObject var engine: AetherEngine
    @ObservedObject var clock: PlaybackClock
    @ObservedObject var diagnostics: EngineDiagnostics
    let channelName: String
    let failure: String?
    let firstFrameSeconds: Double?
    let retunes: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("AetherEngine — \(channelName)").font(.headline)
            if let failure {
                Text(failure).foregroundColor(.red)
            }
            Text("state: \(String(describing: engine.state))   route: \(String(describing: engine.videoRoute))"
                 + "   audio: \(String(describing: engine.audioDelivery))")
            Text("video: \(engine.sourceVideoCodecName ?? "-") via \(engine.activeVideoDecoder ?? "-")"
                 + "   audio: \(engine.activeAudioDecoder ?? "-")")
            Text("first frame: \(firstFrameSeconds.map { String(format: "%.2fs", $0) } ?? "-")"
                 + "   behind live: \(String(format: "%.1fs", clock.behindLiveSeconds))"
                 + "   retunes: \(retunes)")
            if let t = diagnostics.liveTelemetry {
                Text("fps \(t.observedFps.map { String(format: "%.1f", $0) } ?? "-")"
                     + "   dropped \(t.droppedFrameCount.map(String.init) ?? "-")"
                     + "   cushion \(t.displayCushionSeconds.map { String(format: "%.2fs", $0) } ?? "-")"
                     + "   \(t.averageBitrateMbps.map { String(format: "%.1f", $0) } ?? "-") Mbps")
            }
        }
        .font(.caption.monospacedDigit())
        .padding(20)
        .background(Color.black.opacity(0.6))
        .cornerRadius(10)
        .padding(60)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
    }
}
