import Foundation
#if canImport(os)
import os
#endif

/// Discovery from one backend, audio from another.
///
/// Browse YouTube's shelves, search and recommendations, but play from your own
/// library — so you get the discovery surface without ads, with reliable
/// CarPlay, and without the terms problem, for anything your library covers.
///
/// Tracks that resolve against the playback backend are replaced wholesale by
/// the library's own entry, so what plays is a real tagged file with real album
/// art. Unmatched tracks are either hidden or fall through to the discovery
/// backend, depending on `fallback`.
final class MatchingSource: MusicSource, @unchecked Sendable {

    enum Fallback: String, CaseIterable, Sendable {
        /// Only show what your library can actually play. Fully ad-free.
        case hideUnmatched
        /// Play unmatched tracks from the discovery backend, ads and all.
        case useDiscovery

        var displayName: String {
            switch self {
            case .hideUnmatched: return "Hide what I don't own"
            case .useDiscovery: return "Stream the rest"
            }
        }
    }

    let identifier = "hybrid"

    var displayName: String {
        "\(discovery.displayName) → \(playback.displayName)"
    }

    var isConfigured: Bool { discovery.isConfigured && playback.isConfigured }

    private let discovery: MusicSource
    private let playback: MusicSource
    private let fallback: Fallback
    private let thresholds: TrackMatcher.Thresholds

    /// Resolved matches, keyed by discovery track ID. A miss is cached as `nil`
    /// so a track absent from the library isn't re-searched on every refresh.
    private let cache = MatchCache()

    /// Concurrent lookups per batch. Enough to hide latency, few enough not to
    /// hammer a small self-hosted server.
    private let matchConcurrency = 6

    private let log = Logger(subsystem: "com.example.aura", category: "hybrid")

    /// Namespaces so `playbackRequest` knows which backend a track came from.
    private enum Namespace {
        static let playback = "p:"
        static let discovery = "d:"
    }

    init(
        discovery: MusicSource,
        playback: MusicSource,
        fallback: Fallback = .hideUnmatched,
        thresholds: TrackMatcher.Thresholds = .default
    ) {
        self.discovery = discovery
        self.playback = playback
        self.fallback = fallback
        self.thresholds = thresholds
    }

    // MARK: - Namespacing

    private func tag(_ track: Track, _ prefix: String) -> Track {
        var copy = track
        copy.id = prefix + track.id
        return copy
    }

    private func tag(_ container: Container, _ prefix: String) -> Container {
        var copy = container
        copy.id = prefix + container.id
        return copy
    }

    /// Splits a namespaced ID back into its backend and original ID.
    private func resolve(_ id: String) -> (source: MusicSource, id: String)? {
        if id.hasPrefix(Namespace.playback) {
            return (playback, String(id.dropFirst(Namespace.playback.count)))
        }
        if id.hasPrefix(Namespace.discovery) {
            return (discovery, String(id.dropFirst(Namespace.discovery.count)))
        }
        return nil
    }

    // MARK: - Matching

    /// Resolve one discovery track to a library track, consulting the cache.
    private func match(_ wanted: Track) async -> Track? {
        if let cached = await cache.value(for: wanted.id) {
            return cached.track
        }

        let query = TrackMatcher.searchQuery(for: wanted)
        guard !query.isEmpty else {
            await cache.store(nil, for: wanted.id)
            return nil
        }

        do {
            let results = try await playback.search(query)
            let best = TrackMatcher.bestMatch(for: wanted, in: results.tracks, thresholds: thresholds)
            await cache.store(best, for: wanted.id)
            return best
        } catch {
            // A failed lookup is not a confirmed miss, so don't cache it.
            log.debug("Match lookup failed for \(wanted.title, privacy: .public)")
            return nil
        }
    }

    /// Map a batch of discovery tracks through the matcher, preserving order.
    private func matched(_ tracks: [Track]) async -> [Track] {
        guard !tracks.isEmpty else { return [] }

        var resolved = [Int: Track?](minimumCapacity: tracks.count)

        await withTaskGroup(of: (Int, Track?).self) { group in
            var next = 0
            var running = 0

            func addTask(_ index: Int) {
                let wanted = tracks[index]
                group.addTask { [weak self] in
                    guard let self else { return (index, nil) }
                    return (index, await self.match(wanted))
                }
            }

            // Prime the window, then refill as each finishes — bounded concurrency.
            while next < tracks.count, running < matchConcurrency {
                addTask(next)
                next += 1
                running += 1
            }

            while let (index, result) = await group.next() {
                resolved[index] = result
                running -= 1
                if next < tracks.count {
                    addTask(next)
                    next += 1
                    running += 1
                }
            }
        }

        return tracks.indices.compactMap { index -> Track? in
            if let match = resolved[index] ?? nil {
                return tag(match, Namespace.playback)
            }
            switch fallback {
            case .hideUnmatched: return nil
            case .useDiscovery: return tag(tracks[index], Namespace.discovery)
            }
        }
    }

    // MARK: - MusicSource

    func homeFeed() async throws -> [Shelf] {
        let shelves = try await discovery.homeFeed()

        var result: [Shelf] = []
        for shelf in shelves {
            // Track shelves get matched; container shelves are resolved lazily
            // when opened, so there's nothing to look up here.
            let tracks = shelf.items.compactMap { item -> Track? in
                if case .track(let track) = item { return track }
                return nil
            }

            if tracks.isEmpty {
                let containers = shelf.items.compactMap { item -> ShelfItem? in
                    if case .container(let container) = item {
                        return .container(tag(container, Namespace.discovery))
                    }
                    return nil
                }
                guard !containers.isEmpty else { continue }
                result.append(Shelf(id: shelf.id, title: shelf.title, subtitle: shelf.subtitle,
                                    style: shelf.style, items: containers))
                continue
            }

            let items = await matched(tracks).map { ShelfItem.track($0) }
            // An entirely unmatched shelf is noise; leave it out.
            guard !items.isEmpty else { continue }
            result.append(Shelf(id: shelf.id, title: shelf.title, subtitle: shelf.subtitle,
                                style: shelf.style, items: items))
        }

        guard !result.isEmpty else {
            throw MusicSourceError.malformedResponse(
                "Nothing in the discovery feed matched your library. Try “Stream the rest” in Settings."
            )
        }
        return result
    }

    func search(_ query: String) async throws -> SearchResults {
        // Search the library first: it's exact, playable and costs no quota.
        var results = (try? await playback.search(query)) ?? SearchResults()
        results.tracks = results.tracks.map { tag($0, Namespace.playback) }
        results.albums = results.albums.map { tag($0, Namespace.playback) }
        results.artists = results.artists.map { tag($0, Namespace.playback) }
        results.playlists = results.playlists.map { tag($0, Namespace.playback) }

        // Only reach for the discovery backend when the library came up short —
        // a YouTube search costs 100 quota units.
        guard results.tracks.count < 5 else { return results }

        guard let discovered = try? await discovery.search(query) else { return results }
        let extra = await matched(discovered.tracks)

        let known = Set(results.tracks.map(\.id))
        results.tracks.append(contentsOf: extra.filter { !known.contains($0.id) })
        return results
    }

    func tracks(in container: Container) async throws -> [Track] {
        guard let (source, id) = resolve(container.id) else {
            throw MusicSourceError.malformedResponse("unrecognised container \(container.id)")
        }

        var original = container
        original.id = id
        let tracks = try await source.tracks(in: original)

        // A library container plays as-is; a discovery container needs matching.
        if source === playback {
            return tracks.map { tag($0, Namespace.playback) }
        }
        return await matched(tracks)
    }

    func playbackRequest(for track: Track) async throws -> PlaybackRequest {
        guard let (source, id) = resolve(track.id) else {
            throw MusicSourceError.malformedResponse("unrecognised track \(track.id)")
        }
        var original = track
        original.id = id
        return try await source.playbackRequest(for: original)
    }

    func continuation(seededBy track: Track, excluding knownIDs: Set<String>) async throws -> [Track] {
        guard let (source, id) = resolve(track.id) else { return [] }

        var original = track
        original.id = id

        // Strip namespaces so the backend's own exclusion logic still works.
        let originalKnown = Set(knownIDs.compactMap { resolve($0)?.id })
        let tracks = try await source.continuation(seededBy: original, excluding: originalKnown)

        if source === playback {
            return tracks.map { tag($0, Namespace.playback) }
        }
        return await matched(tracks)
    }
}

// MARK: - Cache

/// Match results, isolated so concurrent lookups can share them safely.
private actor MatchCache {

    /// Boxed so a cached miss is distinguishable from an absent entry.
    struct Entry {
        let track: Track?
    }

    private var entries: [String: Entry] = [:]

    func value(for id: String) -> Entry? {
        entries[id]
    }

    func store(_ track: Track?, for id: String) {
        entries[id] = Entry(track: track)
    }
}
