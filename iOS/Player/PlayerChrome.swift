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

    /// The PiP toggle, in the top-right corner rather than the banner, which is already full of
    /// buttons. It rides the banner's visibility, so the tap that hides the chrome hides it too.
    func playerPiPCorner(_ pip: PictureInPicture, onToggle: @escaping () -> Void) -> some View {
        VStack(alignment: .trailing, spacing: 6) {
            Button { onToggle() } label: {
                Image(systemName: pip.isActive ? "pip.exit" : "pip.enter")
            }
            .buttonStyle(PlayerIconButtonStyle(tint: pip.isActive ? guideAccent : nil))
            .disabled(!pip.hasSource)
            .accessibilityLabel(pip.isActive ? "Stop picture in picture" : "Start picture in picture")

            // Why the button is dim, or why a start failed. It is not interactive, so it must not
            // swallow the tap that reaches the video.
            if let failure = pip.failure {
                Text(failure)
                    .font(.caption2)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.black.opacity(0.6))
                    .cornerRadius(6)
                    .lineLimit(2)
                    .allowsHitTesting(false)
            }
        }
        .padding(.top, 10)
        .padding(.trailing, 16)
        .transition(.opacity)
    }
}
