# Aura

A native iOS music app in the shape of YouTube Music: a shelf-based homepage, a
now-playing screen, a two-tier queue, and CarPlay. No advertising, no tracking,
no analytics.

The content backend sits behind a protocol, so what plays is a one-file decision.

## The hybrid source (recommended if you want YouTube's discovery)

`MatchingSource` composes two backends: **discovery** from one, **audio** from
another. Browse YouTube's charts and playlists, play from your own server.

Each discovery track is searched for in your library and, when found, **replaced
wholesale by the library's entry** — so what plays is your own tagged file with
real album art. Tracks your library doesn't have are either hidden (default,
never any ads) or streamed from YouTube, set by "Tracks I don't own" in Settings.

That gets you YouTube's discovery surface with zero ads, reliable CarPlay and no
terms problem, for everything your library covers.

Matching is the delicate part, so `TrackMatcher` is pure and heavily tested. It
handles what the two catalogues actually look like:

- YouTube decoration — `Sinnerman (Official Audio) [HD]` → `sinnerman`
- Auto-generated channel names — `Nina Simone - Topic`, `RadioheadVEVO`
- Accents and punctuation — `Björk` → `bjork`, `Don't` → `dont` (one token)
- Duration agreement, when both sides know it, within 15s — this is what keeps a
  9-minute live take from satisfying a request for the 4-minute studio cut
- **An artist floor**, so an identical title can still be vetoed. Without it
  every cover matches the original: "Hallelujah" by Pentatonix would satisfy a
  request for Jeff Buckley's. Skipped when either side has no usable artist,
  which is common from `search.list`.

Two practical notes. Matches are cached in memory, misses included, so a refresh
doesn't re-search your server for a track it already knows is absent — but the
cache doesn't survive relaunch, so the first home feed after launch does the
lookups. And search hits your library first, only consulting YouTube when the
library returns fewer than 5 results, because a YouTube search costs 100 quota
units and your own server costs nothing.

Thresholds are tunable: `TrackMatcher.Thresholds.lenient` accepts more, for
libraries with sparse tagging.

## About the YouTube source

A YouTube backend ships here, built on the **official IFrame embed player** in an
offscreen `WKWebView`. Know what that does and doesn't get you before you use it:

- **Ads still play.** The embed serves whatever YouTube serves, pre-roll
  included. There is no ad filtering in this codebase. Sign in with a **YouTube
  Premium** account in Settings and the embed plays ad-free, because your
  subscription covers it — this is the only ad-free YouTube route here, and it
  involves circumventing nothing.
- **Background and audio-only playback violate the YouTube API Services
  Terms**, which require the video to be visible. This source cannot ship on the
  App Store. It is for a personal, self-signed build.
- **CarPlay is unreliable with this source.** iOS will not play media in a
  `WKWebView` outside a view hierarchy, so the engine parks a 1×1 view in the
  phone's window. Launch straight into CarPlay with no phone window and there is
  nothing to host the player. This is structural to the embed approach, not a
  setting — `SubsonicSource` has no such problem because `AVPlayer` needs no view.
- **Metadata comes from the Data API v3**, which is legitimate but limited. There
  is no personalised feed without OAuth, and `relatedToVideoId` was removed in
  August 2023, so there is no related-videos call. The homepage is the trending
  music chart plus playlists you name; continuation searches the current track's
  channel.
- **Quota.** 10,000 units/day by default. Search costs 100 units (~100 searches
  a day); trending and playlist reads cost 1, which is why the homepage is built
  from those. Exhaustion surfaces as a 403 with a clear message.

### Two approaches that are not used here

- **Stream extraction** (NewPipe, yt-dlp) reverse-engineers YouTube's InnerTube
  endpoints and evaluates the signature-cipher JavaScript. It breaks whenever
  YouTube rotates the cipher or the `nsig` function. NewPipe's extractor is also
  **GPLv3**, which cannot ship in an App Store binary — Apple's distribution
  terms add restrictions the GPL forbids. VLC was pulled from the App Store in
  2011 over exactly this and had to relicense before returning.
- **Ad filtering.** uBlock Origin does not block YouTube ads by URL; the ad video
  comes from the same hosts as the content. It uses scriptlets — `json-prune` to
  strip `adPlacements`/`playerAds` from the player response, plus anti-anti-adblock
  shims. That mechanism cannot be ported to iOS anyway: `WKContentRuleList` is
  declarative Safari content-blocker JSON supporting URL blocking and CSS hiding
  only, with no scriptlet injection or response patching. Replicating it would
  mean hand-maintained `WKUserScript` patches against YouTube's own changes.

If you want ad-free music with working CarPlay and no terms problem, use the
self-hosted backend. It is the only option here that satisfies every requirement
at once.

For how content blocking actually works — the five filtering layers, why video
ads can only be reached at the scriptlet layer, and which layers each platform
exposes — see [docs/content-filtering-architecture.md](docs/content-filtering-architecture.md).

## Requirements

- **Any OS** — a Swift 5.9+ toolchain, to build and test the source layer
- **macOS + Xcode 15+** — to build the app itself
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`make bootstrap`)
- A paid Apple Developer account **only** for CarPlay templates

## Build

```sh
make            # list every target
```

### Without a Mac

The source and queue layers import nothing but Foundation, so they build and
test anywhere:

```sh
make core-test     # the full unit suite
make core-build    # type-check only
```

That's a real SwiftPM package (`Package.swift`) over the portable subset, not a
side project — it is how the queue, the matcher and the source adapters are
tested. Files importing UIKit, SwiftUI, AVFoundation, CarPlay, MediaPlayer,
WebKit, CryptoKit or Security are excluded and need Xcode. `Support/` holds the
platform stand-ins that package uses; it is deliberately **not** in the app
target.

### On macOS

```sh
make bootstrap     # install XcodeGen (once)
make open          # generate Aura.xcodeproj and open it
make build         # or build headlessly for the simulator
make test          # run the XCTest bundle on a simulator
```

`Aura.xcodeproj` is **generated and not committed** — `project.yml` is the source
of truth. Re-run `make project` after adding files.

Override the simulator with `make test SIM='iPhone 15 Pro'`; `make simulators`
lists what you have.

The app runs immediately against a built-in demo catalogue, so you can exercise
the whole UI — including CarPlay in the simulator — before configuring anything.

### VS Code

`.vscode/` is set up with tasks for all of the above (**Terminal → Run Task**),
a default test task bound to the portable suite, and launch configurations for
debugging it on either platform. Recommended extensions are in
`.vscode/extensions.json`; `swiftlang.swift-vscode` is needed for completion,
and `sweetpad.sweetpad` is the practical way to run the app on a simulator
without opening Xcode.

Expect import errors in the editor on files that pull in iOS frameworks — those
only resolve against the iOS SDK inside Xcode, and SourceKit-LSP here indexes
the portable package.

### CarPlay entitlement

`App/Aura.entitlements` declares `com.apple.developer.carplay-audio`. **Signing
fails while this is present and unapproved**, so either request it or comment it
out to build meanwhile:

1. Request it at <https://developer.apple.com/contact/carplay/>, choosing the
   audio category. Apple grants it per developer account, and it has turnaround
   time, so ask early.
2. Regenerate your provisioning profile once granted.

To build without it meanwhile:

```sh
make no-carplay
```

That generates an otherwise identical project with the entitlement stripped. The
phone app and the CarPlay Now Playing screen still work — only the app's own
CarPlay templates are unavailable.

**What the entitlement does and doesn't gate** — this is the detail that trips
people up:

| Behaviour | Needs the entitlement? |
|---|---|
| Current song, artwork and transport controls on CarPlay's Now Playing screen | **No.** Driven system-wide by `MPNowPlayingInfoCenter` / `MPRemoteCommandCenter` |
| Title/artist on a plain Bluetooth or USB head unit | **No.** Same mechanism |
| Your own browsable homepage, search and queue templates in the car | **Yes** |

So half of "CarPlay support" works with no approval at all. Only your own
template UI is gated.

To test in the simulator: **I/O → External Displays → CarPlay**.

## Testing in a car

CarPlay templates cannot be fully exercised in the simulator — notably the
`CPNowPlayingTemplate` Up Next button and real audio routing. Test on a device
with a head unit, or a CarPlay-capable aftermarket unit on a bench supply.

## Configuring a backend

Three adapters ship:

| Adapter | Setup | Ads | CarPlay | App Store |
|---|---|---|---|---|
| `SubsonicSource` | server address + login | none | yes | yes |
| `MatchingSource` | both backends below | none, unless you opt in | yes | no¹ |
| `LocalLibrarySource` | library permission | none | yes | yes |
| `DemoSource` | none | none | yes | yes |
| `YouTubeSource` | API key, or Premium sign-in | yes, unless Premium | unreliable | no |

¹ Metadata still comes from the Data API under terms that forbid this use, so
it stays a personal build — but unlike the plain YouTube source, playback is
your own server, so there are no ads and CarPlay is reliable.

Pick the source in Settings; the choice persists across launches.

`SubsonicSource` is the reference backend. It speaks the Subsonic API, which
**Navidrome**, Airsonic, Gonic and Jellyfin all serve. Navidrome is a single Go
binary pointed at a music folder, so this is the shortest path to the full
experience with real stream URLs and no ads anywhere in the stack.

Use HTTPS where you can. `NSAllowsLocalNetworking` is set in `Info.plist` for
plain-HTTP LAN servers; drop it if you don't need it.

One platform caveat on `LocalLibrarySource`: iOS exposes no playable file for
Apple Music *streaming* items, so only DRM-free local files appear. The adapter
filters accordingly rather than queueing tracks that would fail.

## Adding a backend

> For a fuller treatment with worked, compile-checked examples — a complete
> custom `MusicSource`, a custom `PlaybackEngine`, matcher tuning, the
> namespacing contract and how to test an adapter — see
> [docs/extending.md](docs/extending.md).


Conform to `MusicSource` (`Core/MusicSource.swift`) and return it from
`SourceFactory.makeConfiguredSource()`. Six methods:

```swift
func homeFeed() async throws -> [Shelf]
func search(_ query: String) async throws -> SearchResults
func tracks(in container: Container) async throws -> [Track]
func playbackRequest(for track: Track) async throws -> PlaybackRequest
func continuation(seededBy: Track, excluding: Set<String>) async throws -> [Track]
```

`continuation` has a default returning `[]`; implement it to get endless
radio-style playback. `StreamAsset` carries headers, so bearer-token auth works
without touching the player.

Most sources return `.streamURL` and are played by `AVPlayerEngine`. If your
backend's player *is* the playback mechanism rather than something that resolves
to a URL, add a `PlaybackRequest` case and a matching `PlaybackEngine` — that is
exactly what the YouTube embed does. Nothing above these two protocols knows or
cares where audio comes from or what moves it.

## Architecture

```
App/        entry point, scene routing, DI container
Core/
  Models          Track, Container, Shelf, StreamAsset
  MusicSource     the backend protocol
  Scrobbling/     Scrobbler protocol, tracker, AudioScrobbler client, queue
  Sources/        Demo, Subsonic, LocalLibrary, YouTube, Matching adapters
  Playback/       PlayQueue, PlayerController, audio session, now-playing bridge
    Engines/      PlaybackEngine protocol, AVPlayer and YouTube-embed engines
  Util/           artwork cache, credentials, MD5, track matcher, configs
UI/         SwiftUI: home, search, container detail, now playing, queue, settings
CarPlay/    scene delegate and template construction
Tests/      queue, MD5, decoding, matcher, hybrid source, scrobbling
```

Two points worth knowing before changing things:

**One player, two scenes.** The phone UI and CarPlay are separate `UIScene`s but
must agree on what's playing, so both reach into `AppEnvironment.shared` for a
single `PlayerController`. Instantiating a second one is the bug to avoid.

**Sources compose.** A `MusicSource` can wrap other sources rather than talk to
a server — that is all `MatchingSource` is. Namespaced IDs (`p:` / `d:`) are what
let it route each track back to the backend it came from.

**Scrobbling observes, it is not called.** `ScrobbleCoordinator` subscribes to
the player's published state, so playback has no knowledge that scrobbling
exists and the rules live in a pure, tested type rather than in the player.

**Content and playback are separate seams.** `MusicSource` decides *what* to
play, `PlaybackEngine` decides *how*. The controller owns the queue, the
metadata and the transport semantics; engines only move audio and report back.
Engines are kept alive rather than rebuilt per track, and switching engines tears
the old one down first — otherwise two players run at once.

**The queue is two queues.** `PlayQueue` keeps `upNext` (what you queued) apart
from `autoNext` (machine-generated continuation). That split is what lets "Add
to queue" always beat autoplay, and lets continuation refill without ever
disturbing your ordering. Drag an autoplay track in the Up Next list and it's
promoted to the explicit queue so a refill can't discard it.

## Scrobbling

Last.fm, Libre.fm and self-hosted GNU FM instances all implement AudioScrobbler
2.0, so one client covers all three and adding a custom server is configuration
rather than code. Several can run at once. Set up under **Settings →
Scrobbling**.

- **Last.fm** needs an API key from <https://www.last.fm/api/account/create>.
- **Libre.fm** needs nothing but a login; GNU FM doesn't issue API keys.
- **Custom** takes a hostname; the `/2.0/` path is appended for you.

Your password is exchanged for a session key via `auth.getMobileSession` and is
not stored. Session keys live in the Keychain, accessible after first unlock so
CarPlay can scrobble before the phone has been unlocked.

### When a play counts

Per the spec, and implemented in `ScrobbleTracker`:

- the track must be longer than 30 seconds
- it must have played for **half its length, or four minutes**, whichever is less
- the timestamp submitted is when playback *started*

"Played" means time actually listened, not position. Pauses don't count, and
seeking earns no credit — scrubbing through a 10-minute track never scrobbles
it. Restarting a track you just finished (repeat-one, or seeking back to the
top) is treated as a genuine second play. Autoplay picks are marked
`chosenByUser=0`.

### The offline queue

Completed plays are written to disk *before* submission, so nothing is lost to a
crash or a dead network between the two. The protocol accepts backdated
timestamps, so a play held through a tunnel still lands in the right place in
your history. Entries that keep failing are abandoned after 8 attempts rather
than blocking the queue forever, and the newest 1000 are kept if the backlog
ever grows that far.

An expired session stops submissions and surfaces in Settings instead of
retrying forever.

## Queue behaviour

- **Play next** — immediately after the current track
- **Add to queue** — after everything you've queued, still ahead of autoplay
- Long-press or swipe any track row anywhere in the app
- Reorderable and swipe-to-deletable in Up Next, and in the car via the Now
  Playing screen's Up Next button
- Autoplay tops up when fewer than three tracks remain, so music never just stops
- Previous restarts the track past 4 seconds in, otherwise steps back — matching
  YouTube Music

## Status

Written against the iOS 17 SDK. What was and wasn't verified:

**Compiled and tested** (Swift 6.0.3 on Linux, 171 tests passing): `Models`,
`PlayQueue`, `MusicSource`, `DemoSource`, `SubsonicSource`, `YouTubeSource`,
`TrackMatcher`, `MatchingSource`, `MD5` and the whole scrobbling layer. This covers the queue semantics end to end —
the user/autoplay split, repeat interacting with history, shuffle reversibility,
duplicate-entry removal — Subsonic and YouTube response decoding including
in-band errors and quota failures, the matcher's normalisation and scoring, and
the hybrid source's namespace round-trips, fallback behaviour, cache hits and
order preservation under concurrent matching. On the scrobbling side: MD5
against the RFC 1321 vectors, `api_sig` construction, the play-qualification
rules including seek abuse and replays, endpoint normalisation, error-code
mapping, and queue persistence through a simulated relaunch.

**Not compiled**: everything touching UIKit, SwiftUI, AVFoundation, CarPlay,
MediaPlayer, WebKit, CryptoKit or Security — the views, the playback engines,
`NowPlayingCenter`, the CarPlay scene and the Keychain store. None of those
frameworks exist on Linux, so they need a Mac. Expect to fix small API details
on the first Xcode build.

**Verified separately**: the demo catalogue's stream URLs were checked live and
return audio.

**Needs a real car**: the `CPNowPlayingTemplate` Up Next button and audio
routing can't be exercised in the simulator.
