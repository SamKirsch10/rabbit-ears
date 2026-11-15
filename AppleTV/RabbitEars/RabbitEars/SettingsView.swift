// Sources/SettingsView.swift
import SwiftUI

struct SettingsView: View {
    let onClose: () -> Void

    @AppStorage("tvhServerURL") private var serverURL = ""
    @StateObject private var topShelfFilter = GuideFilter(defaultsKey: TopShelfPublisher.tagsKey)
    @AppStorage(CaptionSettings.sizeKey) private var size = 0
    @AppStorage(CaptionSettings.colorKey) private var color = 0
    @AppStorage(CaptionSettings.backgroundKey) private var background = 0
    @AppStorage(CaptionSettings.positionKey) private var position = 0

    var body: some View {
        NavigationView {
            List {
                Section("Server") {
                    NavigationLink {
                        ServerSetupView(onSave: onClose)
                    } label: {
                        HStack {
                            Text("TVHeadend Server")
                            Spacer()
                            Text(serverURL).foregroundColor(.secondary).lineLimit(1)
                        }
                    }
                }

                Section {
                    NavigationLink {
                        TopShelfFilterView(filter: topShelfFilter)
                    } label: {
                        HStack {
                            Text("Channels")
                            Spacer()
                            let count = topShelfFilter.selected.count
                            Text(count == 0 ? "All" : "\(count) \(count == 1 ? "group" : "groups")")
                                .foregroundColor(.secondary)
                        }
                    }
                } header: {
                    Text("Top Shelf")
                } footer: {
                    Text("Which channels get a tile above the app when it's in the top row of the Home Screen.")
                }

                Section {
                    ChoiceRow(title: "Text Size", selection: $size,
                              options: CaptionSettings.Size.allCases.sorted { $0.scale < $1.scale }.map { ($0.rawValue, $0.label) })
                    ChoiceRow(title: "Text Color", selection: $color,
                              options: CaptionSettings.TextColor.allCases.map { ($0.rawValue, $0.label) })
                    ChoiceRow(title: "Background", selection: $background,
                              options: CaptionSettings.Background.allCases.map { ($0.rawValue, $0.label) })
                    ChoiceRow(title: "Position", selection: $position,
                              options: CaptionSettings.Position.allCases.map { ($0.rawValue, $0.label) })
                    captionPreview
                } header: {
                    Text("Closed Captions")
                } footer: {
                    Text("Turn captions on with the speech bubble button while watching.")
                }
            }
            .navigationTitle("Settings")
        }
        .background(
            LinearGradient(
                colors: [Color(red: 0.06, green: 0.09, blue: 0.19), Color(red: 0.02, green: 0.02, blue: 0.06)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
        )
    }

    /// Approximation of how the chosen style will look.
    private var captionPreview: some View {
        let style = CaptionSettings.TextColor(rawValue: color) ?? .white
        let bg = CaptionSettings.Background(rawValue: background) ?? .solid
        let scale = CGFloat((CaptionSettings.Size(rawValue: size) ?? .medium).scale)
        return Text("This is how captions will look")
            .font(.system(size: 30 * scale, weight: .semibold))
            .foregroundColor(style.color)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(Color.black.opacity(Double(bg.opacity) / 255))
            .frame(maxWidth: .infinity, minHeight: 90)
            .background(Color(white: 0.25))
            .cornerRadius(10)
    }
}

/// The channel groups the Top Shelf is limited to; the same picker as the guide's filter, with its own
/// selection.
private struct TopShelfFilterView: View {
    @ObservedObject var filter: GuideFilter
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        GuideFilterSheet(filter: filter, title: "Top Shelf channels", scope: "the Top Shelf") { dismiss() }
            .onAppear {
                let client = TVHClient.sharedInstance
                client.reloadConfiguration()
                client.fetchChannelTags { result in
                    if case .success(let tags) = result { filter.setTags(tags) }
                }
            }
    }
}

/// A settings row showing the current choice; opens a list to pick another.
private struct ChoiceRow: View {
    let title: String
    @Binding var selection: Int
    let options: [(value: Int, label: String)]

    var body: some View {
        NavigationLink {
            ChoiceListView(title: title, options: options, selection: $selection)
        } label: {
            HStack {
                Text(title)
                Spacer()
                Text(options.first { $0.value == selection }?.label ?? "")
                    .foregroundColor(.secondary)
            }
        }
    }
}

private struct ChoiceListView: View {
    let title: String
    let options: [(value: Int, label: String)]
    @Binding var selection: Int
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text(title)
                .font(.title2.weight(.bold))
            ScrollView {
                VStack(spacing: 14) {
                    ForEach(options, id: \.value) { option in
                        Button {
                            selection = option.value
                            dismiss()
                        } label: {
                            HStack {
                                Text(option.label).font(.title3)
                                Spacer()
                                if selection == option.value {
                                    Image(systemName: "checkmark.circle.fill").foregroundColor(guideAccent)
                                }
                            }
                            .padding(.horizontal, 28)
                            .padding(.vertical, 18)
                        }
                        .buttonStyle(FilterRowStyle())
                    }
                }
                .padding(.vertical, 8)
            }
        }
        .padding(60)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            LinearGradient(
                colors: [Color(red: 0.06, green: 0.09, blue: 0.19), Color(red: 0.02, green: 0.02, blue: 0.06)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
        )
    }
}
