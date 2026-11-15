// AppleTV/RabbitEars/RabbitEars/SceneDelegate.swift
import UIKit
import SwiftUI

class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = UIHostingController(rootView: ContentView())
        self.window = window
        window.makeKeyAndVisible()
        if let url = connectionOptions.urlContexts.first?.url {
            DeepLinkRouter.shared.handle(url)
        }
    }

    // Opened from a Top Shelf tile while already running.
    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        if let url = URLContexts.first?.url {
            DeepLinkRouter.shared.handle(url)
        }
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        TopShelfPublisher.publish()
    }

    // Catches settings changed during this visit before the user is back at the Home Screen.
    func sceneWillResignActive(_ scene: UIScene) {
        TopShelfPublisher.publish()
    }
}
