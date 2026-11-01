// Adjust AppDelegate to call disconnect instead of cleanup if you wish
// AppleTV/Switft TVH Client/Switft TVH Client/AppDelegate.swift
import UIKit
import Alamofire

@main
class AppDelegate: UIResponder, UIApplicationDelegate {
    private lazy var tvhClient = TVHClient.sharedInstance

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        return true
    }

    func applicationWillResignActive(_ application: UIApplication) {
        tvhClient.cleanup() // optional, if you need to cancel in‑flight requests
    }

    func applicationWillTerminate(_ application: UIApplication) {
        tvhClient.disconnect() // now available
    }
}
