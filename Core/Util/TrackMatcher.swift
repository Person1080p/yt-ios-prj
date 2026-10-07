import Foundation

/// Matches a track from one catalogue against a track in another.
///
/// This is what makes the hybrid source work: YouTube titles are messy
/// ("Song Name (Official Music Video) [4K]") and its "artist" is a channel name
/// ("Artist - Topic", "ArtistVEVO"), while a tagged library has clean fields.
/// All logic here is pure and unit-tested, because a bad matcher silently plays
/// the wrong song.
enum TrackMatcher {

    /// How confident a match has to be before it's used.
    struct Thresholds {
        /// Minimum title similarity, considered on its own.
        var title: Double = 0.6
        /// Minimum weighted score across title and artist.
        var combined: Double = 0.65
        /// Reject when both durations are known and differ by more than this —
        /// catches live takes, extended mixes and radio edits.
        var durationTolerance: TimeInterval = 15
        /// Minimum artist similarity when both artists are known. Without this
        /// an identical title can never be vetoed, so every cover matches the
        /// original — "Hallelujah" by Pentatonix would satisfy a request for
        /// Jeff Buckley's.
        var minArtist: Double = 0.35

        static let `default` = Thresholds()
        /// Accepts more, for libraries with sparse or inconsistent tagging.
        static let lenient = Thresholds(
            title: 0.45, combined: 0.5, durationTolerance: 30, minArtist: 0.2
        )
    }

    // MARK: - Normalisation

    /// Lowercase, strip accents, drop decorations and punctuation, collapse
    /// whitespace. The shared first step for every comparison.
    static func normalize(_ raw: String) -> String {
        var value = raw.cleanedTrackTitle

        value = value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)

        // Drop anything still bracketed; by this point it's noise like "[4K]".
        value = value.replacingOccurrences(
            of: #"[\(\[\{][^\)\]\}]*[\)\]\}]"#,
            with: " ",
            options: .regularExpression
        )

        // Intra-word marks are dropped rather than split on, or "don't"
        // becomes two tokens. Plain replacements, because these characters are
        // awkward to express safely inside a regex literal.
        for mark in ["'", "\u{2019}", "\u{02BC}", "`", "\u{00B4}"] {
            value = value.replacingOccurrences(of: mark, with: "")
        }

        // "Artist - Song" separators and punctuation become spaces so tokens split.
        value = value.replacingOccurrences(
            of: #"[^\p{L}\p{N}]+"#,
            with: " ",
            options: .regularExpression
        )

        var tokens = value.split(separator: " ").map(String.init)
        // A leading article is noise for matching ("The Beatles" / "Beatles").
        if tokens.count > 1, tokens[0] == "the" { tokens.removeFirst() }

        return tokens.joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }

    /// Normalisation plus the channel-name conventions YouTube uses for music.
    static func normalizeArtist(_ raw: String) -> String {
        var value = raw

        // YouTube's auto-generated artist channels are "Artist - Topic".
        if let range = value.range(of: #"\s*-\s*Topic\s*$"#, options: [.regularExpression, .caseInsensitive]) {
            value.removeSubrange(range)
        }
        // "ArtistVEVO" and "Artist VEVO".
        value = value.replacingOccurrences(
            of: #"\s*VEVO\s*$"#, with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        // Trailing "Official", "Official Channel", "Music".
        value = value.replacingOccurrences(
            of: #"\s*-?\s*(Official(\s+(Channel|Music|Artist))?|Music)\s*$"#, with: "",
            options: [.regularExpression, .caseInsensitive]
        )

        return normalize(value)
    }

    // MARK: - Similarity

    /// 0...1 similarity between two already-normalised strings.
    ///
    /// Combines token overlap with edit distance and takes the better of the
    /// two: token logic handles reordering and extra words, edit distance
    /// handles typos and short strings where tokens are too coarse.
    static func similarity(_ a: String, _ b: String) -> Double {
        if a.isEmpty || b.isEmpty { return 0 }
        if a == b { return 1 }

        let tokensA = Set(a.split(separator: " ").map(String.init))
        let tokensB = Set(b.split(separator: " ").map(String.init))

        var tokenScore = 0.0
        if !tokensA.isEmpty, !tokensB.isEmpty {
            if tokensA.isSubset(of: tokensB) || tokensB.isSubset(of: tokensA) {
                // One is a strict extension of the other: "song" vs "song remix".
                tokenScore = 0.9
            } else {
                let intersection = Double(tokensA.intersection(tokensB).count)
                let union = Double(tokensA.union(tokensB).count)
                tokenScore = union > 0 ? intersection / union : 0
            }
        }

        let distance = Double(levenshtein(a, b))
        let longest = Double(max(a.count, b.count))
        let editScore = longest > 0 ? max(0, 1 - distance / longest) : 0

        return max(tokenScore, editScore)
    }

    /// Classic DP edit distance over two rows.
    static func levenshtein(_ a: String, _ b: String) -> Int {
        if a == b { return 0 }
        let first = Array(a), second = Array(b)
        if first.isEmpty { return second.count }
        if second.isEmpty { return first.count }

        var previous = Array(0...second.count)
        var current = [Int](repeating: 0, count: second.count + 1)

        for i in 1...first.count {
            current[0] = i
            for j in 1...second.count {
                let substitution = previous[j - 1] + (first[i - 1] == second[j - 1] ? 0 : 1)
                current[j] = min(
                    previous[j] + 1,      // deletion
                    current[j - 1] + 1,   // insertion
                    substitution
                )
            }
            swap(&previous, &current)
        }
        return previous[second.count]
    }

    // MARK: - Scoring

    /// Weighted confidence that `candidate` is the same recording as `wanted`.
    /// Returns nil when a hard check rules it out.
    static func score(
        wanted: Track,
        candidate: Track,
        thresholds: Thresholds = .default
    ) -> Double? {
        let titleScore = similarity(normalize(wanted.title), normalize(candidate.title))
        guard titleScore >= thresholds.title else { return nil }

        // Duration is the strongest available signal when both sides have it.
        if let wantedDuration = wanted.duration, let candidateDuration = candidate.duration,
           wantedDuration > 0, candidateDuration > 0 {
            guard abs(wantedDuration - candidateDuration) <= thresholds.durationTolerance else {
                return nil
            }
        }

        let wantedArtist = normalizeArtist(wanted.artist)
        let candidateArtist = normalizeArtist(candidate.artist)
        let artistScore = similarity(wantedArtist, candidateArtist)

        // A clearly different artist vetoes the match outright, whatever the
        // title says. Skipped when either side has no usable artist, which is
        // common from search.list.
        if isUsableArtist(wantedArtist), isUsableArtist(candidateArtist),
           artistScore < thresholds.minArtist {
            return nil
        }

        // Title still carries most of the weight: channel names are unreliable,
        // and a library's artist tags may use a different form of the same name.
        let combined = titleScore * 0.75 + artistScore * 0.25
        return combined >= thresholds.combined ? combined : nil
    }

    /// An artist string we can actually compare against.
    private static func isUsableArtist(_ normalized: String) -> Bool {
        !normalized.isEmpty && normalized != "unknown" && normalized != "unknown artist"
    }

    /// Best scoring candidate, or nil when nothing clears the thresholds.
    static func bestMatch(
        for wanted: Track,
        in candidates: [Track],
        thresholds: Thresholds = .default
    ) -> Track? {
        candidates
            .compactMap { candidate -> (Track, Double)? in
                guard let score = score(wanted: wanted, candidate: candidate, thresholds: thresholds) else {
                    return nil
                }
                return (candidate, score)
            }
            .max { $0.1 < $1.1 }?
            .0
    }

    /// Query text to send to the playback backend when looking for `track`.
    /// Normalised, because search engines choke on "(Official Video) [4K]".
    static func searchQuery(for track: Track) -> String {
        let title = normalize(track.title)
        let artist = normalizeArtist(track.artist)
        return artist.isEmpty ? title : "\(title) \(artist)"
    }
}
