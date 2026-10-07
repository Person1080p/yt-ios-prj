import CarPlay
import UIKit

/// Routes incoming scenes. CarPlay arrives as a separate scene with its own
/// role, which is why the app needs a UIKit delegate even though the UI is SwiftUI.
final class AppDelegate: NSObject, UIApplicationDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Configure the audio session before any playback so the first play()
        // doesn't race the session setup.
        AudioSessionManager.shared.configure()

        // A play in progress is only scrobbled when it ends. Flush on the way
        // to the background so backgrounded-then-killed doesn't lose it.
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                AppEnvironment.shared.scrobbling.flushNow()
            }
        }

        return true
    }

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {

        if connectingSceneSession.role == .carTemplateApplication {
            let config = UISceneConfiguration(name: "CarPlay", sessionRole: connectingSceneSession.role)
            config.delegateClass = CarPlaySceneDelegate.self
            return config
        }

        // The phone window scene is handled by SwiftUI's WindowGroup.
        return UISceneConfiguration(name: "Default", sessionRole: connectingSceneSession.role)
    }
}
