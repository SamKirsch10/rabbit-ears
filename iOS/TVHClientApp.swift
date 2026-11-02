// iOS/TVHClientApp.swift
import SwiftUI

@main
struct TVHClientApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    @AppStorage("tvhServerURL") private var serverURLString: String = ""
    @AppStorage("tvhUsername") private var username: String = ""
    @StateObject private var filter = GuideFilter()

    var body: some View {
        if serverURLString.isEmpty {
            NavigationStack {
                ServerSetupView(onSave: {})
            }
        } else {
            TabView {
                Tab("Guide", systemImage: "square.grid.3x3.topleft.filled") {
                    NavigationStack { GuideView(filter: filter) }
                }
                Tab("Recordings", systemImage: "recordingtape") {
                    NavigationStack { RecordingsView() }
                }
            }
            .tint(guideAccent)
            .id("\(serverURLString)|\(username)")
        }
    }
}
