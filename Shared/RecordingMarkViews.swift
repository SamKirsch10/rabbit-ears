// Shared/RecordingMarkViews.swift
import SwiftUI

/// A program's DVR state on a guide cell: a filled red dot while recording, a ring when scheduled.
struct RecordingIcon: View {
    let mark: RecordingMark

    var body: some View {
        Image(systemName: mark == .recording ? "record.circle.fill" : "record.circle")
            .foregroundStyle(.red)
            .accessibilityLabel(mark == .recording ? "Recording" : "Scheduled to record")
    }
}

/// The same state as a pill, for the program details (tvOS hero, iOS sheet). The caller sets the font.
struct RecordingBadge: View {
    let mark: RecordingMark

    var body: some View {
        Label(mark == .recording ? "RECORDING" : "SCHEDULED",
              systemImage: mark == .recording ? "record.circle.fill" : "record.circle")
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.red.opacity(mark == .recording ? 0.85 : 0)))
            .overlay(Capsule().strokeBorder(Color.red, lineWidth: mark == .scheduled ? 1.5 : 0))
            .foregroundStyle(.white)
    }
}
