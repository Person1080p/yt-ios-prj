import XCTest
@testable import Aura

/// The matcher decides whether the hybrid source plays the right song, so the
/// cases here are drawn from the shapes YouTube titles and channel names
/// actually take.
final class TrackMatcherTests: XCTestCase {

    private func track(
        _ title: String,
        _ artist: String,
        duration: TimeInterval? = nil,
        id: String = "x"
    ) -> Track {
        Track(id: id, title: title, artist: artist, duration: duration)
    }

    // MARK: - Normalisation

    func testNormalizeStripsDecorationAndPunctuation() {
        XCTAssertEqual(TrackMatcher.normalize("Song Name (Official Video)"), "song name")
        XCTAssertEqual(TrackMatcher.normalize("Song Name [4K]"), "song name")
        XCTAssertEqual(TrackMatcher.normalize("Don't Stop!"), "dont stop")
    }

    func testNormalizeFoldsAccents() {
        XCTAssertEqual(TrackMatcher.normalize("Café Déjà Vu"), "cafe deja vu")
        XCTAssertEqual(TrackMatcher.normalize("Björk"), "bjork")
    }

    func testNormalizeDropsLeadingArticle() {
        XCTAssertEqual(TrackMatcher.normalize("The Beatles"), "beatles")
        // Only when there's something after it.
        XCTAssertEqual(TrackMatcher.normalize("The"), "the")
    }

    func testNormalizeCollapsesSeparators() {
        XCTAssertEqual(TrackMatcher.normalize("Artist - Song  Name"), "artist song name")
    }

    func testNormalizeArtistStripsYouTubeChannelConventions() {
        // Auto-generated artist channels.
        XCTAssertEqual(TrackMatcher.normalizeArtist("Nina Simone - Topic"), "nina simone")
        XCTAssertEqual(TrackMatcher.normalizeArtist("RadioheadVEVO"), "radiohead")
        XCTAssertEqual(TrackMatcher.normalizeArtist("Radiohead VEVO"), "radiohead")
        XCTAssertEqual(TrackMatcher.normalizeArtist("Portishead Official"), "portishead")
        XCTAssertEqual(TrackMatcher.normalizeArtist("Massive Attack - Official Channel"), "massive attack")
    }

    func testNormalizeArtistLeavesOrdinaryNamesAlone() {
        XCTAssertEqual(TrackMatcher.normalizeArtist("Miles Davis"), "miles davis")
    }

    // MARK: - Similarity

    func testIdenticalStringsScoreOne() {
        XCTAssertEqual(TrackMatcher.similarity("song name", "song name"), 1.0)
    }

    func testEmptyStringScoresZero() {
        XCTAssertEqual(TrackMatcher.similarity("", "song"), 0)
    }

    func testSubsetScoresHighly() {
        // A remix or edit of the same title should still be a strong signal.
        XCTAssertGreaterThanOrEqual(TrackMatcher.similarity("song name", "song name remix"), 0.9)
    }

    func testTypoScoresHighlyViaEditDistance() {
        XCTAssertGreaterThan(TrackMatcher.similarity("sinnerman", "sinerman"), 0.8)
    }

    func testUnrelatedTitlesScoreLow() {
        XCTAssertLessThan(TrackMatcher.similarity("blue in green", "smells like teen spirit"), 0.3)
    }

    func testLevenshteinBasics() {
        XCTAssertEqual(TrackMatcher.levenshtein("kitten", "sitting"), 3)
        XCTAssertEqual(TrackMatcher.levenshtein("", "abc"), 3)
        XCTAssertEqual(TrackMatcher.levenshtein("same", "same"), 0)
    }

    // MARK: - Scoring

    func testMatchesAcrossYouTubeDecorationAndTopicChannel() {
        let wanted = track("Sinnerman (Official Audio)", "Nina Simone - Topic")
        let candidate = track("Sinnerman", "Nina Simone")

        XCTAssertNotNil(TrackMatcher.score(wanted: wanted, candidate: candidate))
    }

    func testRejectsDifferentSongByTheSameArtist() {
        let wanted = track("Sinnerman", "Nina Simone")
        let candidate = track("Feeling Good", "Nina Simone")

        XCTAssertNil(TrackMatcher.score(wanted: wanted, candidate: candidate))
    }

    func testRejectsOnDurationMismatchDespiteMatchingTitle() {
        // A 9-minute live take is not the 4-minute studio cut.
        let wanted = track("Sinnerman", "Nina Simone", duration: 240)
        let candidate = track("Sinnerman", "Nina Simone", duration: 560)

        XCTAssertNil(TrackMatcher.score(wanted: wanted, candidate: candidate))
    }

    func testAcceptsSmallDurationDifference() {
        let wanted = track("Sinnerman", "Nina Simone", duration: 603)
        let candidate = track("Sinnerman", "Nina Simone", duration: 608)

        XCTAssertNotNil(TrackMatcher.score(wanted: wanted, candidate: candidate))
    }

    func testMissingDurationDoesNotBlockAMatch() {
        // search.list returns no duration, which must not reject everything.
        let wanted = track("Sinnerman", "Nina Simone", duration: nil)
        let candidate = track("Sinnerman", "Nina Simone", duration: 603)

        XCTAssertNotNil(TrackMatcher.score(wanted: wanted, candidate: candidate))
    }

    func testMatchesWhenArtistTagDiffersButTitleIsStrong() {
        // Libraries often tag the album artist rather than the channel.
        let wanted = track("Blue In Green", "Miles Davis - Topic")
        let candidate = track("Blue In Green", "Miles Davis Quintet")

        XCTAssertNotNil(TrackMatcher.score(wanted: wanted, candidate: candidate))
    }

    func testRejectsSameTitleByAnUnrelatedArtist() {
        // A cover by someone else should not satisfy the match.
        let wanted = track("Hallelujah", "Jeff Buckley")
        let candidate = track("Hallelujah", "Pentatonix")

        XCTAssertNil(TrackMatcher.score(wanted: wanted, candidate: candidate))
    }

    // MARK: - Best match

    func testBestMatchPicksTheHighestScoringCandidate() {
        let wanted = track("Sinnerman (Official Audio)", "Nina Simone - Topic", duration: 603)
        let candidates = [
            track("Sinnerman - Felix Da Housecat Remix", "Nina Simone", duration: 600, id: "remix"),
            track("Sinnerman", "Nina Simone", duration: 603, id: "exact"),
            track("Feeling Good", "Nina Simone", duration: 175, id: "other")
        ]

        XCTAssertEqual(TrackMatcher.bestMatch(for: wanted, in: candidates)?.id, "exact")
    }

    func testBestMatchReturnsNilWhenNothingQualifies() {
        let wanted = track("Sinnerman", "Nina Simone")
        let candidates = [track("Smells Like Teen Spirit", "Nirvana")]

        XCTAssertNil(TrackMatcher.bestMatch(for: wanted, in: candidates))
    }

    func testBestMatchOnEmptyCandidatesIsNil() {
        XCTAssertNil(TrackMatcher.bestMatch(for: track("A", "B"), in: []))
    }

    func testSpacingAndInitialsStillMatch() {
        // Deliberately checking this is ACCEPTED: a differently spaced title and
        // an abbreviated artist are the same recording, and rejecting it would
        // make the hybrid source feel broken on well-tagged libraries.
        let wanted = track("Sinnerman", "Nina Simone")
        let candidate = track("Sinner Man", "N. Simone")

        XCTAssertNotNil(TrackMatcher.score(wanted: wanted, candidate: candidate))
    }

    func testLenientThresholdsAcceptWeakerTitleMatches() {
        // Partial token overlap with no subset relationship: below the default
        // title floor, above the lenient one.
        let wanted = track("Love Me Tender", "Elvis Presley")
        let candidate = track("Love Me Everlasting", "Elvis Presley")

        XCTAssertNil(TrackMatcher.score(wanted: wanted, candidate: candidate))
        XCTAssertNotNil(TrackMatcher.score(wanted: wanted, candidate: candidate, thresholds: .lenient))
    }

    func testUnknownArtistDoesNotTriggerTheArtistVeto() {
        // search.list often yields no channel title, so the floor must not
        // reject everything in that case.
        let wanted = track("Sinnerman", "Unknown")
        let candidate = track("Sinnerman", "Nina Simone")

        XCTAssertNotNil(TrackMatcher.score(wanted: wanted, candidate: candidate))
    }

    func testArtistVetoBeatsAnIdenticalTitle() {
        let wanted = track("Yesterday", "The Beatles")
        let candidate = track("Yesterday", "Boyz II Men")

        XCTAssertNil(TrackMatcher.score(wanted: wanted, candidate: candidate))
    }

    // MARK: - Query construction

    func testSearchQueryIsNormalised() {
        let wanted = track("Sinnerman (Official Video) [HD]", "Nina Simone - Topic")
        XCTAssertEqual(TrackMatcher.searchQuery(for: wanted), "sinnerman nina simone")
    }

    func testSearchQueryOmitsEmptyArtist() {
        XCTAssertEqual(TrackMatcher.searchQuery(for: track("Sinnerman", "")), "sinnerman")
    }
}
