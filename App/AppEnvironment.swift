import Combine
import Foundation

/// Process-wide container.
///
/// The phone UI and the CarPlay scene are two separate `UIScene`s, but they must
/// drive one player and one queue — otherwise the car and the phone disagree
/// about what's playing. Both reach in here, so there is exactly one of each.
@MainActor
final class AppEnvironment: ObservableObject {

    static let shared = AppEnvironment()

    @Published private(set) var source: MusicSource
    let player: PlayerController
    let library: LibraryStore
    let scrobbling: ScrobbleCoordinator

    private init() {
        let source = SourceFactory.makeConfiguredSource()
        self.source = source
        self.player = PlayerController(source: source)
        self.library = LibraryStore(source: source)
        self.scrobbling = ScrobbleCoordinator()

        // Scrobbling observes the player rather than being called by it, so
        // playback has no knowledge that it exists.
        scrobbling.setAccounts(ScrobblerAccountStore.shared.accounts())
        scrobbling.observe(player)
    }

    /// Re-read accounts after a sign-in or a settings change.
    func reloadScrobblers() {
        scrobbling.setAccounts(ScrobblerAccountStore.shared.accounts())
    }

    /// Swap the backend at runtime (Settings). Playback stops, because the
    /// current stream belongs to the old source.
    func switchSource(to newSource: MusicSource) {
        source = newSource
        player.pause()
        player.updateSource(newSource)
        library.updateSource(newSource)
        Task { await library.refreshHome(force: true) }
    }
}

/// Decides which backend to use at launch. Swap the default here, or add a case.
enum SourceFactory {

    /// Which backend the user last chose, so the selection survives relaunch.
    private static let preferenceKey = "source.preferred"

    enum Kind: String, CaseIterable {
        case subsonic, hybrid, youTube, local, demo

        var displayName: String {
            switch self {
            case .subsonic: return "Self-hosted server"
            case .hybrid: return "YouTube discovery → my library"
            case .youTube: return "YouTube"
            case .local: return "On this iPhone"
            case .demo: return "Demo catalogue"
            }
        }
    }

    /// Where the hybrid source sends tracks your library doesn't have.
    private static let fallbackKey = "hybrid.fallback"

    static var hybridFallback: MatchingSource.Fallback {
        get {
            UserDefaults.standard.string(forKey: fallbackKey)
                .flatMap(MatchingSource.Fallback.init(rawValue:)) ?? .hideUnmatched
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: fallbackKey) }
    }

    static var preferredKind: Kind {
        get {
            UserDefaults.standard.string(forKey: preferenceKey)
                .flatMap(Kind.init(rawValue:)) ?? .subsonic
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: preferenceKey) }
    }

    static func make(_ kind: Kind) -> MusicSource {
        switch kind {
        case .subsonic:
            return SubsonicSource()
        case .hybrid:
            // Discovery from YouTube's metadata API, audio from your own server.
            return MatchingSource(
                discovery: YouTubeSource(),
                playback: SubsonicSource(),
                fallback: hybridFallback
            )
        case .youTube:
            return YouTubeSource()
        case .local:
            return LocalLibrarySource()
        case .demo:
            return DemoSource()
        }
    }

    static func makeConfiguredSource() -> MusicSource {
        // Honour the saved choice when it's actually usable, then fall back
        // through the other configured backends, then to the demo catalogue so
        // the app is never dead on a fresh install.
        let preferred = make(preferredKind)
        if preferred.isConfigured { return preferred }

        for kind in Kind.allCases where kind != preferredKind {
            let source = make(kind)
            if source.isConfigured { return source }
        }
        return DemoSource()
    }
}

/// Owns fetched content so the home feed survives scene changes and is ready
/// the instant CarPlay connects, instead of refetching on every attach.
@MainActor
final class LibraryStore: ObservableObject {

    @Published private(set) var shelves: [Shelf] = []
    @Published private(set) var isLoadingHome = false
    @Published private(set) var homeError: String?

    private var source: MusicSource
    private var hasLoadedOnce = false

    init(source: MusicSource) {
        self.source = source
    }

    func updateSource(_ newSource: MusicSource) {
        source = newSource
        hasLoadedOnce = false
        shelves = []
    }

    func refreshHome(force: Bool = false) async {
        if hasLoadedOnce, !force { return }
        guard !isLoadingHome else { return }

        isLoadingHome = true
        homeError = nil
        do {
            shelves = try await source.homeFeed()
            hasLoadedOnce = true
        } catch {
            homeError = error.localizedDescription
        }
        isLoadingHome = false
    }

    func tracks(in container: Container) async throws -> [Track] {
        try await source.tracks(in: container)
    }

    func search(_ query: String) async throws -> SearchResults {
        try await source.search(query)
    }
}
