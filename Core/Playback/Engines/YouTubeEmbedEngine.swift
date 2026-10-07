import Foundation
import UIKit
import WebKit
import os

/// Plays YouTube videos through the official IFrame player API in an offscreen
/// `WKWebView`, reporting state back over a JS message bridge.
///
/// Important properties and limits of this approach:
///
/// - **Ads still play.** This is the sanctioned embed, so it serves whatever
///   YouTube serves, pre-roll included. Sign in with a Premium account
///   (`presentSignIn`) to get ad-free playback legitimately — the web view uses
///   a persistent data store, so the session survives relaunches.
/// - **It violates the YouTube API Services Terms**, which require the video to
///   be visible and prohibit background and audio-only playback. This cannot be
///   shipped on the App Store.
/// - **It needs a window.** iOS will not play media in a `WKWebView` that is
///   not in a view hierarchy, so the engine attaches a 1×1 transparent view to
///   the foreground window scene. If the app is launched directly into CarPlay
///   with no phone window, there is nothing to attach to and playback fails —
///   see `attachToWindow()`. This is a structural weakness of the embed
///   approach for CarPlay use, not something that can be configured away.
@MainActor
final class YouTubeEmbedEngine: NSObject, PlaybackEngine {

    weak var delegate: PlaybackEngineDelegate?

    private(set) var elapsed: TimeInterval = 0
    private(set) var duration: TimeInterval?

    private var webView: WKWebView?
    private var isBridgeReady = false
    private var isPlaying = false

    /// Set while the bridge is still coming up, replayed once it is.
    private var pendingVideoID: String?
    private var pendingAutoPlay = false

    private let log = Logger(subsystem: "com.example.aura", category: "yt-embed")

    private enum Bridge {
        static let name = "ytbridge"
    }

    /// IFrame player states.
    private enum PlayerState: Int {
        case unstarted = -1, ended = 0, playing = 1, paused = 2, buffering = 3, cued = 5
    }

    // MARK: - PlaybackEngine

    func canHandle(_ request: PlaybackRequest) -> Bool {
        if case .youTubeVideo = request { return true }
        return false
    }

    func load(_ request: PlaybackRequest, autoPlay: Bool) {
        guard case .youTubeVideo(let id) = request else {
            delegate?.engineDidFail(self, error: PlaybackEngineError.unsupportedRequest)
            return
        }

        elapsed = 0
        duration = nil

        guard isBridgeReady else {
            // Remember the request and fire it from the ready callback.
            pendingVideoID = id
            pendingAutoPlay = autoPlay
            buildWebViewIfNeeded()
            return
        }

        let command = autoPlay ? "loadVideoById" : "cueVideoById"
        evaluate("player.\(command)({videoId: '\(Self.sanitize(id))'});")
    }

    func play() {
        AudioSessionManager.shared.activate()
        evaluate("player.playVideo();")
    }

    func pause() {
        evaluate("player.pauseVideo();")
    }

    func seek(to time: TimeInterval) {
        evaluate("player.seekTo(\(max(0, time)), true);")
        elapsed = max(0, time)
        delegate?.engineDidUpdateTime(self)
    }

    func teardown() {
        evaluate("if (window.player && player.stopVideo) player.stopVideo();")
        webView?.configuration.userContentController
            .removeScriptMessageHandler(forName: Bridge.name)
        webView?.removeFromSuperview()
        webView = nil
        isBridgeReady = false
        isPlaying = false
        pendingVideoID = nil
        elapsed = 0
        duration = nil
    }

    // MARK: - Web view

    private func buildWebViewIfNeeded() {
        guard webView == nil else { return }

        let controller = WKUserContentController()
        controller.add(self, name: Bridge.name)

        let config = WKWebViewConfiguration()
        config.userContentController = controller
        config.allowsInlineMediaPlayback = true
        // Autoplay without a tap; the user's intent came from the app's own UI.
        config.mediaTypesRequiringUserActionForPlayback = []
        // Persistent so a Premium sign-in survives relaunches.
        config.websiteDataStore = .default()

        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: config)
        webView.isUserInteractionEnabled = false
        webView.alpha = 0.01
        webView.isOpaque = false
        self.webView = webView

        attachToWindow(webView)

        // A youtube.com base URL satisfies the embed's origin check.
        webView.loadHTMLString(Self.playerHTML, baseURL: URL(string: "https://www.youtube.com"))
    }

    /// Media will not play in a web view that is outside the view hierarchy, so
    /// the player is parked in the foreground window at 1×1 and effectively
    /// invisible.
    private func attachToWindow(_ webView: WKWebView) {
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }?
            .windows.first { $0.isKeyWindow }
            ?? UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows)
                .first

        guard let window else {
            // No phone window: a CarPlay-only launch. Nothing can host the player.
            delegate?.engineDidFail(self, error: PlaybackEngineError.embedUnavailable(
                "YouTube playback needs the app open on the phone at least once per launch."
            ))
            return
        }
        window.addSubview(webView)
        window.sendSubviewToBack(webView)
    }

    private func evaluate(_ javaScript: String) {
        guard let webView else { return }
        webView.evaluateJavaScript(javaScript) { [weak self] _, error in
            if let error {
                self?.log.debug("JS failed: \(error.localizedDescription)")
            }
        }
    }

    /// Video IDs are [A-Za-z0-9_-]{11}; strip anything else before it reaches
    /// a JS string literal.
    private static func sanitize(_ id: String) -> String {
        id.filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
    }

    // MARK: - Premium sign-in

    /// Presents real YouTube sign-in. A Premium account removes ads from the
    /// embed the legitimate way, with no filtering or patching involved.
    static func makeSignInViewController() -> UIViewController {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.load(URLRequest(url: URL(string: "https://accounts.google.com/ServiceLogin?service=youtube")!))

        let controller = UIViewController()
        controller.view = webView
        controller.title = "Sign in to YouTube"
        return controller
    }

    static func signOut() async {
        let store = WKWebsiteDataStore.default()
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        let records = await store.dataRecords(ofTypes: types)
        await store.removeData(ofTypes: types, for: records)
    }

    // MARK: - Player page

    private static let playerHTML = """
    <!DOCTYPE html>
    <html>
      <head><meta name="viewport" content="width=device-width, initial-scale=1"></head>
      <body style="margin:0;padding:0;background:#000;overflow:hidden">
        <div id="player"></div>
        <script src="https://www.youtube.com/iframe_api"></script>
        <script>
          var player, ready = false;

          function post(message) {
            try { window.webkit.messageHandlers.\(Bridge.name).postMessage(message); }
            catch (e) {}
          }

          function onYouTubeIframeAPIReady() {
            player = new YT.Player('player', {
              height: '1', width: '1',
              playerVars: {
                playsinline: 1, controls: 0, disablekb: 1,
                modestbranding: 1, rel: 0, fs: 0, iv_load_policy: 3
              },
              events: {
                onReady: function () {
                  ready = true;
                  post({ type: 'ready' });
                },
                onStateChange: function (event) {
                  post({
                    type: 'state',
                    state: event.data,
                    time: safeTime(),
                    duration: safeDuration()
                  });
                },
                onError: function (event) {
                  post({ type: 'error', code: event.data });
                }
              }
            });
          }

          function safeTime() {
            try { return player.getCurrentTime() || 0; } catch (e) { return 0; }
          }
          function safeDuration() {
            try { return player.getDuration() || 0; } catch (e) { return 0; }
          }

          // The embed emits no periodic time event, so poll while playing.
          setInterval(function () {
            if (!ready || !player || !player.getPlayerState) return;
            if (player.getPlayerState() === 1) {
              post({ type: 'time', time: safeTime(), duration: safeDuration() });
            }
          }, 500);
        </script>
      </body>
    </html>
    """
}

// MARK: - JS bridge

extension YouTubeEmbedEngine: WKScriptMessageHandler {

    nonisolated func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let body = message.body as? [String: Any],
              let type = body["type"] as? String else { return }

        Task { @MainActor in
            self.handle(type: type, body: body)
        }
    }

    private func handle(type: String, body: [String: Any]) {
        switch type {
        case "ready":
            isBridgeReady = true
            // Replay whatever was requested while the bridge was coming up.
            if let id = pendingVideoID {
                pendingVideoID = nil
                load(.youTubeVideo(id: id), autoPlay: pendingAutoPlay)
            }

        case "time":
            applyTime(body)
            delegate?.engineDidUpdateTime(self)

        case "state":
            applyTime(body)
            guard let raw = body["state"] as? Int, let state = PlayerState(rawValue: raw) else { return }
            handle(state: state)

        case "error":
            let code = body["code"] as? Int ?? -1
            delegate?.engineDidFail(self, error: PlaybackEngineError.youTubePlayer(code: code))

        default:
            break
        }
    }

    private func applyTime(_ body: [String: Any]) {
        if let time = body["time"] as? Double, time.isFinite {
            elapsed = time
        }
        if let value = body["duration"] as? Double, value.isFinite, value > 0 {
            duration = value
        }
    }

    private func handle(state: PlayerState) {
        switch state {
        case .playing:
            if !isPlaying {
                isPlaying = true
                delegate?.engineDidChangePlaybackState(self, isPlaying: true)
            }
            delegate?.engineDidBecomeReady(self)

        case .paused:
            if isPlaying {
                isPlaying = false
                delegate?.engineDidChangePlaybackState(self, isPlaying: false)
            }

        case .ended:
            isPlaying = false
            delegate?.engineDidReachEnd(self)

        case .cued:
            delegate?.engineDidBecomeReady(self)

        case .buffering, .unstarted:
            break
        }
    }
}
