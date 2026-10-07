import SwiftUI

@main
struct AuraApp: App {

    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var environment = AppEnvironment.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(environment)
                .environmentObject(environment.player)
                .environmentObject(environment.library)
                .preferredColorScheme(.dark)
        }
    }
}
