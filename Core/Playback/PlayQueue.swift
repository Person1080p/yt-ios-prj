import Foundation

/// One slot in the queue. Has its own identity so the same track can appear
/// twice and still be moved/removed unambiguously.
struct QueueEntry: Identifiable, Hashable, Codable, Sendable {
    enum Origin: String, Codable, Sendable {
        /// Came from the context the user started (album, playlist, shelf).
        case context
        /// User explicitly chose "Play next" or "Add to queue".
        case userAdded
        /// Auto-generated continuation / radio.
        case autoplay
    }

    let id: UUID
    var track: Track
    var origin: Origin

    init(id: UUID = UUID(), track: Track, origin: Origin) {
        self.id = id
        self.track = track
        self.origin = origin
    }
}

enum RepeatMode: String, CaseIterable, Codable, Sendable {
    case off, all, one
}

/// The play queue.
///
/// Ordering is `history` → `current` → `upNext` → `autoNext`.
///
/// `upNext` holds everything the user or the starting context queued. `autoNext`
/// holds machine-generated continuation. Keeping them separate is what lets
/// "Add to queue" always win over autoplay, and lets us refill autoplay without
/// ever disturbing the user's own ordering.
struct PlayQueue: Codable, Sendable {

    private(set) var history: [QueueEntry] = []
    private(set) var current: QueueEntry?
    private(set) var upNext: [QueueEntry] = []
    private(set) var autoNext: [QueueEntry] = []

    var repeatMode: RepeatMode = .off
    private(set) var isShuffled: Bool = false

    /// Pre-shuffle ordering of `upNext`, so toggling shuffle off is lossless.
    private var unshuffledUpNext: [QueueEntry]?

    // MARK: - Derived state

    /// Everything after the current track, in play order. What the Up Next screen shows.
    var pending: [QueueEntry] { upNext + autoNext }

    var isEmpty: Bool { current == nil && pending.isEmpty && history.isEmpty }

    var canGoBack: Bool { !history.isEmpty || repeatMode == .all }

    var canGoForward: Bool { !pending.isEmpty || repeatMode != .off }

    /// Track IDs anywhere in the queue — used to keep continuation from repeating itself.
    var knownTrackIDs: Set<String> {
        var ids = Set(history.map(\.track.id))
        if let current { ids.insert(current.track.id) }
        ids.formUnion(upNext.map(\.track.id))
        ids.formUnion(autoNext.map(\.track.id))
        return ids
    }

    /// The next track that will play, without mutating anything. Used for prefetching.
    var upcoming: QueueEntry? {
        if repeatMode == .one { return current }
        return pending.first
    }

    // MARK: - Starting playback

    /// Replace the queue with `tracks` and begin at `index`.
    mutating func replace(with tracks: [Track], startingAt index: Int) {
        let entries = tracks.map { QueueEntry(track: $0, origin: .context) }
        guard entries.indices.contains(index) else {
            history = []
            current = nil
            upNext = []
            autoNext = []
            unshuffledUpNext = nil
            return
        }

        history = Array(entries[..<index])
        current = entries[index]
        upNext = Array(entries[(index + 1)...])
        autoNext = []
        unshuffledUpNext = nil

        if isShuffled { applyShuffle() }
    }

    // MARK: - User additions

    /// Insert directly after the current track, ahead of anything already queued.
    mutating func playNext(_ tracks: [Track]) {
        let entries = tracks.map { QueueEntry(track: $0, origin: .userAdded) }
        if current == nil, let first = entries.first {
            current = first
            upNext.insert(contentsOf: entries.dropFirst(), at: 0)
        } else {
            upNext.insert(contentsOf: entries, at: 0)
        }
        unshuffledUpNext?.insert(contentsOf: entries, at: 0)
    }

    /// Append after everything the user has already queued, but still ahead of autoplay.
    mutating func addToQueue(_ tracks: [Track]) {
        let entries = tracks.map { QueueEntry(track: $0, origin: .userAdded) }
        if current == nil, let first = entries.first {
            current = first
            upNext.append(contentsOf: entries.dropFirst())
        } else {
            upNext.append(contentsOf: entries)
        }
        unshuffledUpNext?.append(contentsOf: entries)
    }

    /// Replace the machine-generated tail. Never touches `upNext`.
    mutating func setAutoQueue(_ tracks: [Track]) {
        autoNext = tracks.map { QueueEntry(track: $0, origin: .autoplay) }
    }

    mutating func appendToAutoQueue(_ tracks: [Track]) {
        autoNext.append(contentsOf: tracks.map { QueueEntry(track: $0, origin: .autoplay) })
    }

    // MARK: - Editing

    mutating func remove(_ id: QueueEntry.ID) {
        upNext.removeAll { $0.id == id }
        autoNext.removeAll { $0.id == id }
        unshuffledUpNext?.removeAll { $0.id == id }
    }

    /// Move within the combined `pending` list. Items dragged across the
    /// user/autoplay boundary are promoted to `userAdded` so they survive an
    /// autoplay refill.
    mutating func movePending(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        let combined = Self.moving(pending, fromOffsets: offsets, toOffset: destination)

        // Everything the user deliberately ordered becomes part of the explicit queue.
        let movedIDs = Set(offsets.map { pending[$0].id })
        upNext = combined.map { entry in
            guard movedIDs.contains(entry.id), entry.origin == .autoplay else { return entry }
            var promoted = entry
            promoted.origin = .userAdded
            return promoted
        }
        autoNext = []
        unshuffledUpNext = nil
    }

    mutating func clearUpNext() {
        upNext.removeAll()
        autoNext.removeAll()
        unshuffledUpNext = nil
    }

    /// Jump straight to a queued entry, pushing everything skipped into history.
    mutating func jump(to id: QueueEntry.ID) {
        var combined = pending
        guard let index = combined.firstIndex(where: { $0.id == id }) else { return }

        if let current { history.append(current) }
        history.append(contentsOf: combined[..<index])
        current = combined[index]
        combined.removeSubrange(...index)

        // Preserve the user/autoplay split for the remainder.
        upNext = combined.filter { $0.origin != .autoplay }
        autoNext = combined.filter { $0.origin == .autoplay }
        unshuffledUpNext = nil
    }

    // MARK: - Transport

    /// Advance one track. `userInitiated` distinguishes a skip from a natural
    /// end-of-track, which matters for repeat-one.
    @discardableResult
    mutating func advance(userInitiated: Bool = false) -> QueueEntry? {
        if repeatMode == .one, !userInitiated, current != nil {
            return current
        }

        if let next = upNext.first {
            upNext.removeFirst()
            unshuffledUpNext?.removeAll { $0.id == next.id }
            if let current { history.append(current) }
            current = next
            return current
        }

        if let next = autoNext.first {
            autoNext.removeFirst()
            if let current { history.append(current) }
            current = next
            return current
        }

        if repeatMode == .all, !history.isEmpty {
            var cycle = history
            if let current { cycle.append(current) }
            history = []
            current = cycle.first
            upNext = Array(cycle.dropFirst())
            return current
        }

        // Nothing left to play.
        if let current { history.append(current) }
        current = nil
        return nil
    }

    /// Step back. Mirrors YouTube Music: the first press restarts the track if
    /// we're more than a few seconds in — that check lives in the player, which
    /// calls this only when it actually wants the previous track.
    @discardableResult
    mutating func goBack() -> QueueEntry? {
        if let previous = history.popLast() {
            if let current { upNext.insert(current, at: 0) }
            current = previous
            return current
        }

        if repeatMode == .all, !pending.isEmpty {
            var cycle = pending
            if let current { cycle.insert(current, at: 0) }
            let last = cycle.removeLast()
            history = cycle
            current = last
            upNext = []
            autoNext = []
            return current
        }

        return current
    }

    /// Reorder by offsets, matching the semantics SwiftUI's `onMove` reports:
    /// `destination` is an index in the *original* collection, before which the
    /// moved elements are inserted.
    ///
    /// Implemented here rather than using SwiftUI's `move(fromOffsets:toOffset:)`
    /// so that this type stays free of any UI-framework dependency.
    static func moving<T>(_ array: [T], fromOffsets offsets: IndexSet, toOffset destination: Int) -> [T] {
        let moving = offsets.sorted().compactMap { array.indices.contains($0) ? array[$0] : nil }
        guard !moving.isEmpty else { return array }

        var result = array
        // Remove from the highest index down so the lower indices stay valid.
        for index in offsets.sorted(by: >) where result.indices.contains(index) {
            result.remove(at: index)
        }

        // Removing elements that sat before the destination shifts it left.
        let shift = offsets.filter { $0 < destination }.count
        let insertion = min(max(destination - shift, 0), result.count)
        result.insert(contentsOf: moving, at: insertion)
        return result
    }

    // MARK: - Shuffle

    mutating func setShuffled(_ shuffled: Bool) {
        guard shuffled != isShuffled else { return }
        isShuffled = shuffled
        if shuffled {
            applyShuffle()
        } else if let original = unshuffledUpNext {
            // Keep only entries that haven't played yet.
            let remaining = Set(upNext.map(\.id))
            upNext = original.filter { remaining.contains($0.id) }
            unshuffledUpNext = nil
        }
    }

    private mutating func applyShuffle() {
        unshuffledUpNext = upNext
        upNext.shuffle()
    }
}
