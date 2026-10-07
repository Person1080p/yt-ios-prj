import XCTest
@testable import Aura

/// The AudioScrobbler rules: longer than 30s, and played for half its length or
/// four minutes, whichever comes first. Getting these wrong produces either a
/// silent gap in listening history or inflated play counts, neither of which is
/// noticeable until much later — so they are pinned here.
final class ScrobbleTrackerTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func track(_ duration: TimeInterval?, id: String = "t1") -> Track {
        Track(id: id, title: "Song", artist: "Artist", album: "Album", duration: duration)
    }

    /// Feed position in steps the player would plausibly report.
    private func play(
        _ tracker: inout ScrobbleTracker,
        seconds: TimeInterval,
        step: TimeInterval = 0.5,
        from offset: TimeInterval = 0
    ) {
        var elapsed = offset
        let target = offset + seconds
        while elapsed < target {
            elapsed += step
            tracker.update(elapsed: elapsed, isPlaying: true, now: start.addingTimeInterval(elapsed))
        }
    }

    // MARK: - The half-length rule

    func testQualifiesAtHalfTheTrackLength() {
        var tracker = ScrobbleTracker()
        tracker.begin(track: track(200), at: start, chosenByUser: true)

        play(&tracker, seconds: 99)
        XCTAssertFalse(tracker.qualifies)

        play(&tracker, seconds: 2, from: 99)
        XCTAssertTrue(tracker.qualifies)
    }

    func testQualifiesAtFourMinutesForALongTrack() {
        // Half of 20 minutes is 10, but the ceiling is 4.
        var tracker = ScrobbleTracker()
        tracker.begin(track: track(1200), at: start, chosenByUser: true)

        play(&tracker, seconds: 239)
        XCTAssertFalse(tracker.qualifies)

        play(&tracker, seconds: 2, from: 239)
        XCTAssertTrue(tracker.qualifies)
    }

    func testTrackShorterThanThirtySecondsNeverQualifies() {
        var tracker = ScrobbleTracker()
        tracker.begin(track: track(20), at: start, chosenByUser: true)

        play(&tracker, seconds: 20)
        XCTAssertFalse(tracker.qualifies)
        XCTAssertNil(tracker.flush())
    }

    func testUnknownDurationFallsBackToTheCeiling() {
        // search.list returns no duration, so this is a common case.
        var tracker = ScrobbleTracker()
        tracker.begin(track: track(nil), at: start, chosenByUser: true)

        play(&tracker, seconds: 120)
        XCTAssertFalse(tracker.qualifies, "should not use a half-length rule it can't compute")

        play(&tracker, seconds: 121, from: 120)
        XCTAssertTrue(tracker.qualifies)
    }

    // MARK: - Accumulation

    func testPausedTimeDoesNotCount() {
        var tracker = ScrobbleTracker()
        tracker.begin(track: track(200), at: start, chosenByUser: true)

        play(&tracker, seconds: 50)
        let afterPlaying = tracker.playedTime

        // Position is static while paused, but assert the intent directly.
        for _ in 0..<100 {
            tracker.update(elapsed: 50, isPlaying: false, now: start)
        }
        XCTAssertEqual(tracker.playedTime, afterPlaying, accuracy: 0.01)
    }

    func testSeekingForwardEarnsNoCredit() {
        var tracker = ScrobbleTracker()
        tracker.begin(track: track(400), at: start, chosenByUser: true)

        play(&tracker, seconds: 10)
        let beforeSeek = tracker.playedTime

        // Jump most of the way through the track.
        tracker.update(elapsed: 350, isPlaying: true, now: start)
        XCTAssertEqual(tracker.playedTime, beforeSeek, accuracy: 0.01,
                       "a skip ahead is not listening")
        XCTAssertFalse(tracker.qualifies)
    }

    func testSeekingBackwardEarnsNoCreditButKeepsProgress() {
        var tracker = ScrobbleTracker()
        tracker.begin(track: track(400), at: start, chosenByUser: true)

        play(&tracker, seconds: 100)
        let before = tracker.playedTime

        tracker.update(elapsed: 50, isPlaying: true, now: start)
        XCTAssertEqual(tracker.playedTime, before, accuracy: 0.01)

        // Re-listening to a section does accumulate.
        play(&tracker, seconds: 60, from: 50)
        XCTAssertGreaterThan(tracker.playedTime, before)
    }

    func testRepeatedSeekingCannotInflateAPlay() {
        var tracker = ScrobbleTracker()
        tracker.begin(track: track(600), at: start, chosenByUser: true)

        // Scrub around without ever listening.
        for position in stride(from: 0.0, to: 600.0, by: 20.0) {
            tracker.update(elapsed: position, isPlaying: true, now: start)
        }
        XCTAssertFalse(tracker.qualifies)
        XCTAssertLessThan(tracker.playedTime, 30)
    }

    // MARK: - Session boundaries

    func testTrackChangeFlushesAQualifiedPlay() {
        var tracker = ScrobbleTracker()
        tracker.begin(track: track(100, id: "first"), at: start, chosenByUser: true)
        play(&tracker, seconds: 60)

        let flushed = tracker.begin(
            track: track(100, id: "second"),
            at: start.addingTimeInterval(60),
            chosenByUser: true
        )

        XCTAssertEqual(flushed?.track, "Song")
        XCTAssertEqual(flushed?.startedAt, start, "timestamp must be when the play began")
    }

    func testTrackChangeDiscardsAnUnqualifiedPlay() {
        var tracker = ScrobbleTracker()
        tracker.begin(track: track(300, id: "first"), at: start, chosenByUser: true)
        play(&tracker, seconds: 10)

        XCTAssertNil(tracker.begin(track: track(300, id: "second"), at: start, chosenByUser: true))
    }

    func testFlushYieldsTheScrobbleOnce() {
        var tracker = ScrobbleTracker()
        tracker.begin(track: track(100), at: start, chosenByUser: true)
        play(&tracker, seconds: 60)

        XCTAssertNotNil(tracker.flush())
        XCTAssertNil(tracker.flush(), "a flushed play must not be submitted twice")
    }

    func testDiscardDropsAQualifiedPlay() {
        var tracker = ScrobbleTracker()
        tracker.begin(track: track(100), at: start, chosenByUser: true)
        play(&tracker, seconds: 60)

        tracker.discard()
        XCTAssertNil(tracker.flush())
    }

    // MARK: - Replays

    func testRestartingAQualifiedTrackScrobblesItAgain() {
        // Repeat-one, or seeking back to the top of a track just heard.
        var tracker = ScrobbleTracker()
        tracker.begin(track: track(100), at: start, chosenByUser: true)
        play(&tracker, seconds: 60)

        let replay = tracker.update(elapsed: 0, isPlaying: true, now: start.addingTimeInterval(100))
        XCTAssertNotNil(replay, "a second play should be scrobbled")

        // And the new session starts clean.
        XCTAssertLessThan(tracker.playedTime, 1)
        XCTAssertFalse(tracker.qualifies)
    }

    func testRestartingAnUnqualifiedTrackScrobblesNothing() {
        var tracker = ScrobbleTracker()
        tracker.begin(track: track(300), at: start, chosenByUser: true)
        play(&tracker, seconds: 5)

        XCTAssertNil(tracker.update(elapsed: 0, isPlaying: true, now: start))
    }

    func testSecondPlayCanQualifyAfterARestart() {
        var tracker = ScrobbleTracker()
        tracker.begin(track: track(100), at: start, chosenByUser: true)
        play(&tracker, seconds: 60)
        tracker.update(elapsed: 0, isPlaying: true, now: start.addingTimeInterval(100))

        play(&tracker, seconds: 60)
        XCTAssertTrue(tracker.qualifies)
    }

    // MARK: - Announcements

    func testAnnouncementIsDueOncePerPlay() {
        var tracker = ScrobbleTracker()
        tracker.begin(track: track(100), at: start, chosenByUser: true)

        XCTAssertTrue(tracker.needsAnnouncement)
        tracker.markAnnounced()
        XCTAssertFalse(tracker.needsAnnouncement)

        tracker.begin(track: track(100, id: "next"), at: start, chosenByUser: true)
        XCTAssertTrue(tracker.needsAnnouncement, "a new play needs its own announcement")
    }

    func testAnnouncementCarriesTheMetadata() {
        var tracker = ScrobbleTracker()
        tracker.begin(track: track(210), at: start, chosenByUser: true)

        let update = tracker.announcement
        XCTAssertEqual(update?.artist, "Artist")
        XCTAssertEqual(update?.track, "Song")
        XCTAssertEqual(update?.album, "Album")
        XCTAssertEqual(update?.duration, 210)
    }

    func testNoAnnouncementWithoutASession() {
        let tracker = ScrobbleTracker()
        XCTAssertNil(tracker.announcement)
        XCTAssertFalse(tracker.needsAnnouncement)
    }

    // MARK: - Provenance

    func testAutoplayPicksAreMarkedNotChosenByUser() {
        var tracker = ScrobbleTracker()
        tracker.begin(track: track(100), at: start, chosenByUser: false)
        play(&tracker, seconds: 60)

        XCTAssertEqual(tracker.flush()?.chosenByUser, false)
    }

    // MARK: - Progress reporting

    func testRemainingToQualifyCountsDown() {
        var tracker = ScrobbleTracker()
        tracker.begin(track: track(200), at: start, chosenByUser: true)
        XCTAssertEqual(tracker.remainingToQualify ?? 0, 100, accuracy: 0.6)

        play(&tracker, seconds: 40)
        XCTAssertEqual(tracker.remainingToQualify ?? 0, 60, accuracy: 0.6)
    }

    func testRemainingIsNilOnceQualified() {
        var tracker = ScrobbleTracker()
        tracker.begin(track: track(100), at: start, chosenByUser: true)
        play(&tracker, seconds: 60)

        XCTAssertNil(tracker.remainingToQualify)
    }
}
