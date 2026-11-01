// Sources/CaptionSettings.swift
import SwiftUI

/// How closed captions are drawn by CaptionOverlay. The first case of each choice is the default.
enum CaptionSettings {
    static let sizeKey = "captionSize"
    static let colorKey = "captionColor"
    static let backgroundKey = "captionBackground"
    static let positionKey = "captionPosition"

    enum Size: Int, CaseIterable, Identifiable {
        case medium, small, large, extraLarge
        var id: Int { rawValue }
        var label: String { ["Medium", "Small", "Large", "Extra Large"][rawValue] }
        var scale: Float { [1.0, 0.75, 1.5, 2.0][rawValue] }
    }

    enum TextColor: Int, CaseIterable, Identifiable {
        case white, yellow, cyan
        var id: Int { rawValue }
        var label: String { ["White", "Yellow", "Cyan"][rawValue] }
        var color: Color { [Color.white, Color.yellow, Color.cyan][rawValue] }
    }

    enum Background: Int, CaseIterable, Identifiable {
        case solid, semi, none
        var id: Int { rawValue }
        var label: String { ["Solid", "Semi-transparent", "None"][rawValue] }
        var opacity: Int { [255, 128, 0][rawValue] }
    }

    enum Position: Int, CaseIterable, Identifiable {
        case bottom, raised, high
        var id: Int { rawValue }
        var label: String { ["Bottom", "Raised", "High"][rawValue] }
        var margin: Int { [0, 60, 130][rawValue] }
    }

    static var size: Size { Size(rawValue: UserDefaults.standard.integer(forKey: sizeKey)) ?? .medium }
    static var textColor: TextColor { TextColor(rawValue: UserDefaults.standard.integer(forKey: colorKey)) ?? .white }
    static var background: Background { Background(rawValue: UserDefaults.standard.integer(forKey: backgroundKey)) ?? .solid }
    static var position: Position { Position(rawValue: UserDefaults.standard.integer(forKey: positionKey)) ?? .bottom }
}
