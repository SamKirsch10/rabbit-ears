// AppleTV/Switft TVH Client/Switft TVH Client/SceneDelegate.swift
import UIKit
import SwiftUI

class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        // A window subclass, not a plain UIWindow: it carries the touch-surface recognizer, which no
        // SwiftUI view can host, and reads presses at `sendEvent` (see RemoteScrubWindow). Everything
        // the window sees still goes to super.
        let window = RemoteScrubWindow(windowScene: windowScene)
        window.rootViewController = UIHostingController(rootView: ContentView())
        self.window = window
        window.makeKeyAndVisible()
        // A marker the trace file can be checked against: if `tmp/scrub-trace.log` is missing while this
        // should have run, the writes are failing, not the input capture.
        ScrubTrace.record("scene connected")
    }
}
