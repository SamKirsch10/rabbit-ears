// Sources/ContentView.swift
import SwiftUI

struct ContentView: View {
    @AppStorage("tvhServerURL") private var serverURLString: String = ""
    @AppStorage("tvhUsername") private var username: String = ""
    @State private var showingSettings = false
    @State private var showingFilter = false
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
                        NavigationLink("DVR") {
                            DVRListView()
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
        }
    }
}
