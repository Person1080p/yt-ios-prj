import Foundation

/// Durable queue of plays waiting to be submitted.
///
/// This matters more than it looks: a car loses signal constantly, and the
/// protocol accepts backdated timestamps, so a play held for an hour still
/// lands in the right place in your history. Losing it because the submission
/// happened to fail would be the common case, not the rare one.
actor ScrobbleQueue {

    /// Beyond this, the oldest entries are dropped. Chosen so a long offline
    /// drive survives without the file growing without bound.
    private let capacity: Int
    /// Give up on an entry the service keeps refusing.
    private let maximumAttempts: Int

    private let fileURL: URL?
    private var entries: [Scrobble] = []
    private var didLoad = false

    init(
        fileURL: URL? = ScrobbleQueue.defaultFileURL(),
        capacity: Int = 1000,
        maximumAttempts: Int = 8
    ) {
        self.fileURL = fileURL
        self.capacity = capacity
        self.maximumAttempts = maximumAttempts
    }

    /// `Application Support/Aura/pending-scrobbles.json`.
    static func defaultFileURL() -> URL? {
        guard let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else { return nil }

        let directory = support.appendingPathComponent("Aura", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("pending-scrobbles.json")
    }

    // MARK: - Access

    var count: Int {
        get async {
            await load()
            return entries.count
        }
    }

    var pending: [Scrobble] {
        get async {
            await load()
            return entries
        }
    }

    func enqueue(_ scrobble: Scrobble) async {
        await load()
        entries.append(scrobble)
        trim()
        await persist()
    }

    func enqueue(_ scrobbles: [Scrobble]) async {
        guard !scrobbles.isEmpty else { return }
        await load()
        entries.append(contentsOf: scrobbles)
        trim()
        await persist()
    }

    /// The next batch to submit, oldest first.
    func nextBatch(limit: Int = AudioScrobblerService.maximumBatchSize) async -> [Scrobble] {
        await load()
        return Array(entries.prefix(limit))
    }

    /// Remove entries the service accepted.
    func remove(ids: [Scrobble.ID]) async {
        guard !ids.isEmpty else { return }
        await load()
        let doomed = Set(ids)
        entries.removeAll { doomed.contains($0.id) }
        await persist()
    }

    /// Record a failed attempt, dropping entries that have failed too often.
    ///
    /// Returns the IDs given up on, so the caller can report them rather than
    /// having plays vanish silently.
    @discardableResult
    func recordFailure(ids: [Scrobble.ID]) async -> [Scrobble.ID] {
        await load()
        let affected = Set(ids)
        var abandoned: [Scrobble.ID] = []

        entries = entries.compactMap { entry in
            guard affected.contains(entry.id) else { return entry }
            var updated = entry
            updated.attempts += 1
            if updated.attempts >= maximumAttempts {
                abandoned.append(updated.id)
                return nil
            }
            return updated
        }

        await persist()
        return abandoned
    }

    func removeAll() async {
        entries = []
        didLoad = true
        await persist()
    }

    // MARK: - Persistence

    private func load() async {
        guard !didLoad else { return }
        didLoad = true

        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return }
        // A corrupt file must not wedge scrobbling forever, so a decode failure
        // starts from empty rather than throwing.
        entries = (try? JSONDecoder().decode([Scrobble].self, from: data)) ?? []
        trim()
    }

    private func persist() async {
        guard let fileURL else { return }
        guard let data = try? JSONEncoder().encode(entries) else { return }
        // Atomic, so a crash mid-write can't leave a truncated file.
        try? data.write(to: fileURL, options: .atomic)
    }

    /// Keep the newest entries; the oldest are the least useful if we must drop.
    private func trim() {
        guard entries.count > capacity else { return }
        entries.removeFirst(entries.count - capacity)
    }
}
