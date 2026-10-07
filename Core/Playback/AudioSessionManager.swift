import AVFoundation
import os

/// Owns the shared `AVAudioSession`. Correct configuration here is what makes
/// background audio, lock-screen controls and CarPlay routing work at all.
final class AudioSessionManager {

    static let shared = AudioSessionManager()

    private let log = Logger(subsystem: "com.example.aura", category: "audio-session")
    private var isActivated = false

    private init() {}

    /// Call once at launch, before the first `play()`.
    func configure() {
        let session = AVAudioSession.sharedInstance()
        do {
            // .playback keeps audio alive when the screen locks and when the app
            // is backgrounded, and it is the category CarPlay audio apps require.
            try session.setCategory(.playback, mode: .default, policy: .longFormAudio)
        } catch {
            log.error("Could not set audio session category: \(error.localizedDescription)")
        }
    }

    func activate() {
        guard !isActivated else { return }
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            isActivated = true
        } catch {
            log.error("Could not activate audio session: \(error.localizedDescription)")
        }
    }

    /// Release the session so other apps can resume. Only worth doing when the
    /// user has genuinely stopped, not on every pause.
    func deactivate() {
        guard isActivated else { return }
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            isActivated = false
        } catch {
            log.error("Could not deactivate audio session: \(error.localizedDescription)")
        }
    }
}
