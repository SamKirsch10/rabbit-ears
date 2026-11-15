// Sources/ContentView.swift
import SwiftUI

struct ContentView: View {
    @AppStorage("tvhServerURL") private var serverURLString: String = ""
    @AppStorage("tvhUsername") private var username: String = ""
    @State private var showingSettings = false
    @State private var showingFilter = false
    @State private var showingDVR = false
    @ObservedObject private var deepLinks = DeepLinkRouter.shared
    @StateObject private var filter = GuideFilter()

    var body: some View {
        NavigationView {
            Group {
                if serverURLString.isEmpty {
                    ServerSetupView(onSave: {})
                } else {
                    GuideView(filter: filter)
                        .id("\(serverURLString)|\(username)")
                }
            }
            .navigationTitle("TVHeadend")
            .toolbar {
                if !serverURLString.isEmpty {
                    ToolbarItem {
                        Button(filter.isActive ? "Filter (\(filter.selected.count))" : "Filter") {
                            showingFilter = true
                        }
                    }
                    ToolbarItem {
                        NavigationLink(destination: DVRListView(), isActive: $showingDVR) {
                            Text("DVR")
                        }
                    }
                    ToolbarItem {
                        Button("Settings") {
                            showingSettings = true
                        }
                    }
                }
            }
            .sheet(isPresented: $showingFilter) {
                GuideFilterSheet(filter: filter) { showingFilter = false }
            }
            .fullScreenCover(isPresented: $showingSettings) {
                SettingsView {
                    showingSettings = false
                }
            }
            .onChange(of: deepLinks.liveChannelID) { _, channelID in
                // Opened from the Top Shelf: get back to the guide, which opens the channel.
                guard channelID != nil else { return }
                showingSettings = false
                showingFilter = false
                showingDVR = false
            }
        }
    }
}
