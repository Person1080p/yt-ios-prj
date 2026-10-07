import Foundation

/// Decides when a play has earned a scrobble.
///
/// The rules come from the AudioScrobbler spec: the track must be longer than
/// 30 seconds, and must have played for at least half its length or four
/// minutes, whichever comes first. The timestamp submitted is when playback
/// *started*.
///
/// Pure and synchronous on purpose — getting this wrong means either a silent
/// gap in listening history or inflated play counts, and neither is visible
/// until much later. `ScrobbleCoordinator` is the thin layer that feeds it.
struct ScrobbleTracker {

    struct Rules: Sendable {
        /// Tracks shorter than this never scrobble.
        var minimumTrackDuration: TimeInterval = 30
        /// Fraction of the track that counts as a play.
        var playFraction: Double = 0.5
        /// ...or this many seconds, whichever comes first.
        var playCeiling: TimeInterval = 240
        /// A position jump larger than this is a seek, not listening, so it
        /// earns no credit.
        var maxCredibleDelta: TimeInterval = 5
        /// Treat a jump back to the very start as a replay rather than a seek.
        var replayPositionThreshold: TimeInterval = 1.5

        static let `default` = Rules()
    }

    struct Session: Sendable {
        let track: Track
        let startedAt: Date
        let chosenByUser: Bool
        /// Time actually listened, which is not the same as position — seeks
        /// and pauses are excluded.
        fileprivate(set) var playedTime: TimeInterval = 0
        fileprivate(set) var lastElapsed: TimeInterval = 0
        fileprivate(set) var didAnnounce = false
    }

    var rules: Rules = .default
    private(set) var session: Session?

    init(rules: Rules = .default) {
        self.rules = rules
    }

    // MARK: - Queries

    /// True once the current play has met the threshold.
    var qualifies: Bool {
        session.map(meetsThreshold) ?? false
    }

    /// A "listening now" announcement is due.
    var needsAnnouncement: Bool {
        guard let session else { return false }
        return !session.didAnnounce
    }

    /// Listened time for the current play. Exposed for the UI and for tests.
    var playedTime: TimeInterval { session?.playedTime ?? 0 }

    /// How much more listening the current play needs, or nil if it's done or
    /// can never qualify.
    var remainingToQualify: TimeInterval? {
        guard let session, let required = requiredTime(for: session.track) else { return nil }
        let remaining = required - session.playedTime
        return remaining > 0 ? remaining : nil
    }

    // MARK: - Transitions

    /// Start tracking a new play.
    ///
    /// Returns a scrobble for the outgoing track if it qualified, so a caller
    /// can't forget to flush on a track change.
    @discardableResult
    mutating func begin(track: Track, at now: Date, chosenByUser: Bool) -> Scrobble? {
        let completed = flush()
        session = Session(track: track, startedAt: now, chosenByUser: chosenByUser)
        return completed
    }

    /// Feed the current position.
    ///
    /// Returns a scrobble when it detects the track restarting after an
    /// already-qualified play — repeat-one, or the user seeking back to the top
    /// of a track they just heard. Both are genuinely a second play.
    @discardableResult
    mutating func update(elapsed: TimeInterval, isPlaying: Bool, now: Date) -> Scrobble? {
        guard var current = session else { return nil }

        let delta = elapsed - current.lastElapsed

        // Jumped back to the very beginning: a replay, not a seek.
        if elapsed <= rules.replayPositionThreshold,
           current.lastElapsed > rules.maxCredibleDelta {
            let completed = flush()
            session = Session(
                track: current.track,
                startedAt: now,
                chosenByUser: current.chosenByUser
            )
            session?.lastElapsed = elapsed
            return completed
        }

        // Credit only plausible forward movement. A larger jump is a seek and a
        // negative one is a rewind; both resync without earning time.
        if isPlaying, delta > 0, delta <= rules.maxCredibleDelta {
            current.playedTime += delta
        }
        current.lastElapsed = elapsed
        session = current
        return nil
    }

    /// Record that the announcement has been sent, so it isn't repeated.
    mutating func markAnnounced() {
        session?.didAnnounce = true
    }

    /// End the current play, returning a scrobble if it qualified.
    @discardableResult
    mutating func flush() -> Scrobble? {
        guard let current = session else { return nil }
        session = nil
        guard meetsThreshold(current) else { return nil }
        return scrobble(from: current)
    }

    /// Drop the current play without scrobbling it.
    mutating func discard() {
        session = nil
    }

    /// The announcement payload for the current play.
    var announcement: NowPlayingUpdate? {
        guard let session else { return nil }
        return NowPlayingUpdate(
            artist: session.track.artist,
            track: session.track.title,
            album: session.track.album,
            albumArtist: nil,
            duration: session.track.duration
        )
    }

    // MARK: - Rules

    /// Listening time needed for this track, or nil if it can never qualify.
    private func requiredTime(for track: Track) -> TimeInterval? {
        guard let duration = track.duration else {
            // Without a duration the half-length rule can't apply, so fall back
            // to the ceiling. Conservative: under-reports rather than inflates.
            return rules.playCeiling
        }
        guard duration >= rules.minimumTrackDuration else { return nil }
        return min(duration * rules.playFraction, rules.playCeiling)
    }

    private func meetsThreshold(_ session: Session) -> Bool {
        guard let required = requiredTime(for: session.track) else { return false }
        return session.playedTime >= required
    }

    private func scrobble(from session: Session) -> Scrobble {
        Scrobble(
            artist: session.track.artist,
            track: session.track.title,
            album: session.track.album,
            startedAt: session.startedAt,
            duration: session.track.duration,
            chosenByUser: session.chosenByUser
        )
    }
}
