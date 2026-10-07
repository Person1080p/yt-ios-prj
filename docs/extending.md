# Extending Aura

How to use and extend the two seams this app is built on: `MusicSource` (what
plays) and `PlaybackEngine` (how it plays).

Every code sample here is compiled against the real protocols — see
[Compile-checking your own](#compile-checking-your-own) at the end.

**Contents**

- [Swapping sources](#swapping-sources)
- [The hybrid source](#the-hybrid-source)
- [Tuning the matcher](#tuning-the-matcher)
- [Writing a MusicSource](#writing-a-musicsource)
- [The namespace contract](#the-namespace-contract)
- [Writing a PlaybackEngine](#writing-a-playbackengine)
- [Driving the player from your own UI](#driving-the-player-from-your-own-ui)
- [Testing a source](#testing-a-source)

---

## Swapping sources

At runtime, from Settings or code:

```swift
AppEnvironment.shared.switchSource(to: SubsonicSource())
```

This pauses playback (the current stream belongs to the old backend), rebinds the
player and library store, and refetches the home feed.

To change the launch default, edit `SourceFactory`:

```swift
// App/AppEnvironment.swift
static var preferredKind: Kind { get { ... } set { ... } }   // persisted
static func make(_ kind: Kind) -> MusicSource                // add your case here
```

`makeConfiguredSource()` honours the saved choice when it's usable, then falls
through the other configured backends, then to `DemoSource` — so a fresh install
is never dead.

---

## The hybrid source

`MatchingSource` composes two backends: discovery from one, audio from the other.

```swift
let hybrid = MatchingSource(
    discovery: YouTubeSource(),      // shelves, search, recommendations
    playback:  SubsonicSource(),     // the audio that actually plays
    fallback:  .hideUnmatched
)
```

### The two fallback modes

```swift
.hideUnmatched   // default — only show what your library can play. No ads, ever.
.useDiscovery    // stream the rest from the discovery backend (ads apply)
```

With `.hideUnmatched`, a shelf whose tracks all miss is dropped entirely rather
than rendered empty, and `homeFeed()` throws if *nothing* matched — the message
points at the fallback setting.

### Other useful pairings

Nothing about it is YouTube-specific. Both parameters are just `MusicSource`:

```swift
// Discover against a rich remote catalogue, play from the phone offline.
MatchingSource(discovery: SubsonicSource(), playback: LocalLibrarySource())

// Try your library first and stream anything missing.
MatchingSource(discovery: YouTubeSource(),
               playback: SubsonicSource(),
               fallback: .useDiscovery)
```

### What it costs

Matching is one search per discovery track against the playback backend, run at
6 concurrent, with results cached in memory — **including misses**, so a refresh
doesn't re-search for a track already known to be absent. The cache doesn't
survive relaunch, so the first home feed after launch does the lookups.

`search()` queries your library first and only consults the discovery backend
when the library returns fewer than 5 results, because a YouTube search costs 100
quota units and your own server costs nothing.

---

## Tuning the matcher

`TrackMatcher.Thresholds` controls how confident a match must be:

```swift
MatchingSource(
    discovery: YouTubeSource(),
    playback: SubsonicSource(),
    thresholds: .lenient          // for libraries with sparse tagging
)
```

```swift
struct Thresholds {
    var title: Double = 0.6              // minimum title similarity alone
    var combined: Double = 0.65          // minimum weighted title+artist score
    var durationTolerance: TimeInterval = 15
    var minArtist: Double = 0.35         // artist veto floor
}
```

Two of these deserve explanation:

**`durationTolerance`** rejects a candidate when both sides know their duration
and they differ by more than this. It's what stops a 9-minute live take from
satisfying a request for the 4-minute studio cut. Skipped when either duration is
unknown, which is common — `search.list` returns none.

**`minArtist`** lets an unrelated artist veto an identical title. Without it,
title is weighted 0.75 against artist's 0.25, so *every cover matches the
original* — "Hallelujah" by Pentatonix would satisfy a request for Jeff
Buckley's. Skipped when either side has no usable artist.

Raise `title` and `minArtist` for fewer false positives; lower them if a
well-stocked library is showing too many misses. You can check behaviour without
a server:

```swift
let wanted    = Track(id: "yt1", title: "Sinnerman (Official Audio)", artist: "Nina Simone - Topic")
let candidate = Track(id: "lib1", title: "Sinnerman", artist: "Nina Simone")

TrackMatcher.score(wanted: wanted, candidate: candidate)   // Double? — nil means rejected
TrackMatcher.searchQuery(for: wanted)                      // "sinnerman nina simone"
TrackMatcher.normalizeArtist("RadioheadVEVO")              // "radiohead"
```

---

## Writing a MusicSource

Five methods. Here is a complete, working adapter against a hypothetical JSON API:

```swift
import Foundation

final class MyServerSource: MusicSource, @unchecked Sendable {

    let identifier = "myserver"
    let displayName = "My Server"
    var isConfigured: Bool { token != nil }

    private let base = URL(string: "https://music.example.com/api/")!
    private let session = URLSession(configuration: .default)
    private var token: String? { UserDefaults.standard.string(forKey: "myserver.token") }

    // MARK: Discovery

    func homeFeed() async throws -> [Shelf] {
        let albums: [AlbumDTO] = try await get("albums/recent")

        return [
            Shelf(
                id: "recent",
                title: "Recently added",
                subtitle: nil,
                style: .cards,
                items: albums.map { album in
                    .container(Container(
                        id: album.id,
                        kind: .album,
                        title: album.title,
                        subtitle: album.artist,
                        artworkURL: URL(string: album.artworkURL),
                        trackCount: album.trackCount
                    ))
                }
            )
        ]
    }

    func search(_ query: String) async throws -> SearchResults {
        let escaped = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let songs: [SongDTO] = try await get("search?q=\(escaped)")
        return SearchResults(tracks: songs.map(track(from:)))
    }

    func tracks(in container: Container) async throws -> [Track] {
        let songs: [SongDTO] = try await get("albums/\(container.id)/tracks")
        return songs.map(track(from:))
    }

    // MARK: Playback

    func playbackRequest(for track: Track) async throws -> PlaybackRequest {
        guard let token else {
            throw MusicSourceError.notConfigured("Sign in first.")
        }
        // Headers reach AVPlayer, so bearer auth needs nothing from the player.
        return .streamURL(StreamAsset(
            url: base.appendingPathComponent("stream/\(track.id)"),
            headers: ["Authorization": "Bearer \(token)"],
            expiresAt: Date().addingTimeInterval(3600)
        ))
    }

    /// Optional — has a default returning []. Implement it for endless playback.
    func continuation(seededBy track: Track, excluding knownIDs: Set<String>) async throws -> [Track] {
        let songs: [SongDTO] = try await get("similar/\(track.id)")
        return songs.map(track(from:)).filter { !knownIDs.contains($0.id) }
    }

    // MARK: Plumbing

    private func get<T: Decodable>(_ path: String) async throws -> T {
        var request = URLRequest(url: base.appendingPathComponent(path))
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw MusicSourceError.server(status: http.statusCode, message: nil)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func track(from song: SongDTO) -> Track {
        Track(
            id: song.id,
            title: song.title,
            artist: song.artist,
            album: song.album,
            duration: song.seconds,
            artworkURL: URL(string: song.artworkURL ?? ""),
            // Stash anything you need later to resolve a stream or continuation.
            sourceToken: song.artistID
        )
    }

    struct AlbumDTO: Decodable {
        let id: String, title: String, artist: String, artworkURL: String
        let trackCount: Int
    }

    struct SongDTO: Decodable {
        let id: String, title: String, artist: String
        let album: String?, artworkURL: String?, artistID: String?
        let seconds: TimeInterval?
    }
}
```

Then register it:

```swift
// SourceFactory.Kind
case myServer

// SourceFactory.make(_:)
case .myServer: return MyServerSource()
```

### Shelf styles

```swift
.quickPicks   // 2-row paged grid of individual tracks; tapping plays the shelf
.cards        // horizontally scrolling squares (albums, playlists)
.circles      // horizontally scrolling circles (artists)
```

A `.quickPicks` shelf should hold `.track` items; `.cards` and `.circles` should
hold `.container` items, resolved via `tracks(in:)` when opened.

### Conventions worth following

- **`sourceToken`** is yours. It's an opaque `String?` carried on `Track` so the
  queue stays `Codable`. `SubsonicSource` leaves it nil (the ID is enough),
  `DemoSource` puts a stream URL in it, `YouTubeSource` puts the channel ID in it
  because that's what continuation searches on.
- **Throw `MusicSourceError`** rather than a bare error. `.notConfigured`
  produces a message that tells the user what to do; the player surfaces
  `localizedDescription` directly.
- **Filter out what can't play.** `LocalLibrarySource` drops Apple Music
  streaming items (no `assetURL`), `YouTubeSource` drops deleted and private
  playlist entries. Queueing a track that will fail is worse than hiding it —
  the player will skip it, and five consecutive failures stop playback.

---

## The namespace contract

Only relevant if you compose sources. `MatchingSource` prefixes IDs so it can
route each track back to the backend it came from:

```
p:lib1      → the playback backend, original ID "lib1"
d:yt2       → the discovery backend, original ID "yt2"
```

If you write a composing source, three rules:

1. **Tag on the way out** — every `Track` and `Container` you return.
2. **Strip on the way in** — `playbackRequest(for:)` and `tracks(in:)` must
   restore the original ID before delegating.
3. **Strip exclusion sets too.** `continuation(seededBy:excluding:)` receives
   namespaced IDs, but the backend filters on its own. Forgetting this means the
   backend never excludes anything and continuation repeats itself:

```swift
let originalKnown = Set(knownIDs.compactMap { resolve($0)?.id })
let tracks = try await source.continuation(seededBy: original, excluding: originalKnown)
```

---

## Writing a PlaybackEngine

Only needed if your backend's player *is* the playback mechanism rather than
something that resolves to a URL. Add a `PlaybackRequest` case:

```swift
enum PlaybackRequest: Sendable {
    case streamURL(StreamAsset)
    case youTubeVideo(id: String)
    case myEmbeddedPlayer(token: String)   // your new case
}
```

Conform, and route it in `PlayerController.engine(for:)`:

```swift
@MainActor
final class MyEngine: NSObject, PlaybackEngine {

    weak var delegate: PlaybackEngineDelegate?
    private(set) var elapsed: TimeInterval = 0
    private(set) var duration: TimeInterval?

    private var currentToken: String?

    func canHandle(_ request: PlaybackRequest) -> Bool {
        if case .myEmbeddedPlayer = request { return true }
        return false
    }

    func load(_ request: PlaybackRequest, autoPlay: Bool) {
        guard case .myEmbeddedPlayer(let token) = request else {
            delegate?.engineDidFail(self, error: PlaybackEngineError.unsupportedRequest)
            return
        }
        elapsed = 0
        duration = nil
        currentToken = token
        // ... start loading, then call engineDidBecomeReady when playable ...
        if autoPlay { play() }
    }

    func play() {
        AudioSessionManager.shared.activate()   // required, or there is no audio
        // ...
        delegate?.engineDidChangePlaybackState(self, isPlaying: true)
    }

    func pause() {
        delegate?.engineDidChangePlaybackState(self, isPlaying: false)
    }

    func seek(to time: TimeInterval) {
        elapsed = time
        delegate?.engineDidUpdateTime(self)
    }

    func teardown() {
        // Called when switching engines. Must actually silence playback,
        // or two engines run at once.
    }
}
```

### Delegate contract

| Call | When | Effect on the app |
|---|---|---|
| `engineDidBecomeReady` | playable; `duration` may now be set | clears the loading spinner |
| `engineDidUpdateTime` | position moved (fire often, keep it cheap) | updates the scrubber |
| `engineDidChangePlaybackState` | started or stopped, **including causes the app didn't initiate** | updates play/pause everywhere |
| `engineDidReachEnd` | finished on its own | advances the queue, honouring repeat |
| `engineDidFail` | unrecoverable | skips the track, or stops after 5 in a row |

Two things the controller handles so engines don't have to: a generation counter
discards a slow load whose track was already skipped, and `NowPlayingCenter`
drives the lock screen and CarPlay from controller state. Report accurately and
the car display is correct for free.

---

## Driving the player from your own UI

`PlayerController` is an `ObservableObject` on the main actor:

```swift
@EnvironmentObject private var player: PlayerController
```

```swift
// Start a context — index is where within `tracks` to begin
player.play(tracks: shelfTracks, startingAt: 3)
player.play(track: single)

// Queue additions, exactly as the context menus use them
player.playNext([track])      // immediately after the current track
player.addToQueue([track])    // after everything you've queued, ahead of autoplay

// Transport
player.togglePlayPause()
player.next()
player.previous()             // restarts past 4s in, otherwise steps back
player.seek(to: 90)

// Queue editing
player.jump(to: entry.id)
player.removeFromQueue(entry.id)
player.movePending(fromOffsets: offsets, toOffset: destination)
player.clearUpNext()
player.toggleShuffle()
player.cycleRepeatMode()      // off → all → one → off
```

Observable state:

```swift
player.currentTrack      // Track?
player.isPlaying         // Bool
player.isLoading         // Bool
player.elapsed           // TimeInterval
player.duration          // TimeInterval?
player.progress          // Double, 0...1 — bind straight to a ProgressView
player.lastError         // String?

player.queue.pending     // [QueueEntry] — what the Up Next screen shows
player.queue.canGoForward
player.queue.repeatMode
player.queue.isShuffled
```

Reading the queue's two tiers separately, the way `QueueView` does:

```swift
let explicit = player.queue.pending.filter { $0.origin != .autoplay }
let autoplay = player.queue.pending.filter { $0.origin == .autoplay }
```

---

## Testing a source

The pure parts of a source — decoding, normalisation, ID handling — are testable
with no device and no network, which is where most bugs are. For anything that
needs a backend, a stub conformance is enough:

```swift
private final class FakeSource: MusicSource, @unchecked Sendable {
    let identifier = "fake"
    var displayName: String { identifier }
    var isConfigured = true

    var tracks: [Track] = []
    var searchCount = 0        // assert on call counts to verify caching

    func homeFeed() async throws -> [Shelf] { [] }

    func search(_ query: String) async throws -> SearchResults {
        searchCount += 1
        return SearchResults(tracks: tracks)
    }

    func tracks(in container: Container) async throws -> [Track] { tracks }

    func playbackRequest(for track: Track) async throws -> PlaybackRequest {
        // Encode the identity in the URL so tests can assert on routing.
        .streamURL(StreamAsset(url: URL(string: "https://\(identifier)/\(track.id)")!))
    }
}
```

That pattern is what `Tests/MatchingSourceTests.swift` uses to check namespace
round-trips, fallback behaviour, cache hits and order preservation under
concurrent matching. Worth copying for your own adapter.

Decoding tests want realistic response bodies rather than hand-tidied ones —
`Tests/SubsonicDecodingTests.swift` pins in-band errors, absent arrays and
partially populated records, which are the three shapes that actually break
things in the field.

---

## Compile-checking your own

The app can't build on a machine without Xcode, but the source layer is mostly
pure Foundation and can be checked anywhere Swift runs:

```sh
swift build   # against a package containing Models, MusicSource and your adapter
```

Files importing UIKit, SwiftUI, AVFoundation, CarPlay, MediaPlayer, WebKit,
CryptoKit or Security need a Mac. Keeping a source adapter free of those imports
is worth doing deliberately — it's what makes it testable.
