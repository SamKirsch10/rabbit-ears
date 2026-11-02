// iOS/Player/PlayerChrome.swift
import SwiftUI

/// The round icon buttons on the live and recording banners.
struct PlayerIconButtonStyle: ButtonStyle {
    /// Overrides the icon colour (e.g. red while recording).
    var tint: Color? = nil
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.title3)
            .foregroundStyle(tint ?? .white)
            .frame(width: 40, height: 40)
            .background(Circle().fill(Color.white.opacity(configuration.isPressed ? 0.3 : 0.15)))
            .opacity(enabled ? 1 : 0.4)
    }
}

extension View {
    /// The banner's backdrop, as on tvOS: full-bleed to the screen edges and bottom, while the
    /// banner's content stays in the safe area.
    func playerBannerBackground() -> some View {
        background(alignment: .bottom) {
            LinearGradient(
                colors: [Color(red: 0.06, green: 0.09, blue: 0.19).opacity(0.95),
                         Color(red: 0.02, green: 0.02, blue: 0.06).opacity(0.98)],
                startPoint: .top, endPoint: .bottom
            )
            .overlay(alignment: .top) {
                Rectangle().fill(Color.white.opacity(0.12)).frame(height: 1)
            }
            .ignoresSafeArea()
        }
    }
}
