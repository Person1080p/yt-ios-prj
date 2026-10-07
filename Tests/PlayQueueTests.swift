import XCTest
@testable import Aura

/// The queue is the part of the app with real edge cases — the user/autoplay
/// split, repeat interacting with history, shuffle being reversible — and it's
/// pure logic, so it's worth testing properly.
final class PlayQueueTests: XCTestCase {

    private func makeTracks(_ count: Int, prefix: String = "t") -> [Track] {
        (0..<count).map { Track(id: "\(prefix)\($0)", title: "Song \($0)", artist: "Artist") }
    }

    // MARK: - Starting playback

    func testReplaceSetsCurrentAndSplitsHistory() {
        var queue = PlayQueue()
        queue.replace(with: makeTracks(5), startingAt: 2)

        XCTAssertEqual(queue.current?.track.id, "t2")
        XCTAssertEqual(queue.history.map(\.track.id), ["t0", "t1"])
        XCTAssertEqual(queue.upNext.map(\.track.id), ["t3", "t4"])
    }

    func testReplaceWithOutOfRangeIndexClearsQueue() {
        var queue = PlayQueue()
        queue.replace(with: makeTracks(3), startingAt: 9)

        XCTAssertNil(queue.current)
        XCTAssertTrue(queue.isEmpty)
    }

    // MARK: - User additions vs autoplay

    func testPlayNextJumpsAheadOfExistingQueue() {
        var queue = PlayQueue()
        queue.replace(with: makeTracks(3), startingAt: 0)
        queue.addToQueue([Track(id: "added", title: "Added", artist: "A")])
        queue.playNext([Track(id: "urgent", title: "Urgent", artist: "A")])

        XCTAssertEqual(queue.upNext.first?.track.id, "urgent")
    }

    func testAddToQueueStaysAheadOfAutoplay() {
        var queue = PlayQueue()
        queue.replace(with: makeTracks(1), startingAt: 0)
        queue.setAutoQueue(makeTracks(3, prefix: "auto"))
        queue.addToQueue([Track(id: "mine", title: "Mine", artist: "A")])

        // The user's track must come before every autoplay track.
        XCTAssertEqual(queue.pending.first?.track.id, "mine")
        XCTAssertEqual(queue.pending.map(\.track.id).suffix(3), ["auto0", "auto1", "auto2"])
    }

    func testRefillingAutoplayDoesNotDisturbUserQueue() {
        var queue = PlayQueue()
        queue.replace(with: makeTracks(1), startingAt: 0)
        queue.addToQueue([Track(id: "mine", title: "Mine", artist: "A")])
        queue.setAutoQueue(makeTracks(2, prefix: "old"))
        queue.setAutoQueue(makeTracks(2, prefix: "new"))

        XCTAssertEqual(queue.pending.map(\.track.id), ["mine", "new0", "new1"])
    }

    func testAddToEmptyQueueStartsPlayback() {
        var queue = PlayQueue()
        queue.addToQueue(makeTracks(2))

        XCTAssertEqual(queue.current?.track.id, "t0")
        XCTAssertEqual(queue.upNext.map(\.track.id), ["t1"])
    }

    // MARK: - Transport

    func testAdvanceDrainsUpNextBeforeAutoplay() {
        var queue = PlayQueue()
        queue.replace(with: makeTracks(2), startingAt: 0)
        queue.setAutoQueue(makeTracks(1, prefix: "auto"))

        queue.advance()
        XCTAssertEqual(queue.current?.track.id, "t1")
        queue.advance()
        XCTAssertEqual(queue.current?.track.id, "auto0")
    }

    func testAdvanceAtEndClearsCurrent() {
        var queue = PlayQueue()
        queue.replace(with: makeTracks(1), startingAt: 0)

        queue.advance()
        XCTAssertNil(queue.current)
        XCTAssertFalse(queue.canGoForward)
    }

    func testRepeatOneHoldsOnNaturalEndButNotOnSkip() {
        var queue = PlayQueue()
        queue.replace(with: makeTracks(2), startingAt: 0)
        queue.repeatMode = .one

        queue.advance(userInitiated: false)
        XCTAssertEqual(queue.current?.track.id, "t0", "a natural end should repeat the track")

        queue.advance(userInitiated: true)
        XCTAssertEqual(queue.current?.track.id, "t1", "an explicit skip should move on")
    }

    func testRepeatAllWrapsAroundAtEnd() {
        var queue = PlayQueue()
        queue.replace(with: makeTracks(3), startingAt: 2)
        queue.repeatMode = .all

        queue.advance()
        XCTAssertEqual(queue.current?.track.id, "t0")
        XCTAssertEqual(queue.upNext.map(\.track.id), ["t1", "t2"])
    }

    func testGoBackRestoresPreviousAndRequeuesCurrent() {
        var queue = PlayQueue()
        queue.replace(with: makeTracks(3), startingAt: 1)

        queue.goBack()
        XCTAssertEqual(queue.current?.track.id, "t0")
        XCTAssertEqual(queue.upNext.map(\.track.id), ["t1", "t2"])
    }

    func testGoBackAtStartStaysPut() {
        var queue = PlayQueue()
        queue.replace(with: makeTracks(2), startingAt: 0)

        queue.goBack()
        XCTAssertEqual(queue.current?.track.id, "t0")
    }

    // MARK: - Editing

    func testJumpPushesSkippedTracksIntoHistory() {
        var queue = PlayQueue()
        queue.replace(with: makeTracks(5), startingAt: 0)
        let target = queue.pending[2].id

        queue.jump(to: target)
        XCTAssertEqual(queue.current?.track.id, "t3")
        XCTAssertEqual(queue.history.map(\.track.id), ["t0", "t1", "t2"])
    }

    func testRemoveTakesEntryOutOfPending() {
        var queue = PlayQueue()
        queue.replace(with: makeTracks(3), startingAt: 0)
        let doomed = queue.pending[0].id

        queue.remove(doomed)
        XCTAssertEqual(queue.pending.map(\.track.id), ["t2"])
    }

    func testDuplicateTracksAreRemovedIndependently() {
        var queue = PlayQueue()
        let track = Track(id: "dup", title: "Dup", artist: "A")
        queue.replace(with: [track], startingAt: 0)
        queue.addToQueue([track, track])

        let first = queue.pending[0].id
        queue.remove(first)

        // Entry identity, not track identity, decides what gets removed.
        XCTAssertEqual(queue.pending.count, 1)
    }

    func testMovingAnAutoplayTrackPromotesItToUserQueue() {
        var queue = PlayQueue()
        queue.replace(with: makeTracks(1), startingAt: 0)
        queue.addToQueue([Track(id: "mine", title: "Mine", artist: "A")])
        queue.setAutoQueue(makeTracks(2, prefix: "auto"))

        // Drag the first autoplay track to the front.
        queue.movePending(fromOffsets: IndexSet(integer: 1), toOffset: 0)

        XCTAssertEqual(queue.pending.first?.track.id, "auto0")
        XCTAssertEqual(queue.pending.first?.origin, .userAdded,
                       "a deliberately reordered track must survive an autoplay refill")
    }

    func testClearUpNextLeavesCurrentPlaying() {
        var queue = PlayQueue()
        queue.replace(with: makeTracks(4), startingAt: 1)

        queue.clearUpNext()
        XCTAssertEqual(queue.current?.track.id, "t1")
        XCTAssertTrue(queue.pending.isEmpty)
    }

    // MARK: - Shuffle

    func testShuffleIsReversible() {
        var queue = PlayQueue()
        queue.replace(with: makeTracks(12), startingAt: 0)
        let original = queue.upNext.map(\.track.id)

        queue.setShuffled(true)
        queue.setShuffled(false)

        XCTAssertEqual(queue.upNext.map(\.track.id), original)
    }

    func testUnshufflingAfterPlayingKeepsOnlyRemainingTracks() {
        var queue = PlayQueue()
        queue.replace(with: makeTracks(6), startingAt: 0)
        queue.setShuffled(true)

        queue.advance()
        queue.advance()
        let playedIDs = Set(queue.history.map(\.track.id))

        queue.setShuffled(false)
        let remaining = Set(queue.upNext.map(\.track.id))

        XCTAssertTrue(remaining.isDisjoint(with: playedIDs),
                      "already-played tracks must not reappear when shuffle is turned off")
    }

    // MARK: - Continuation support

    func testKnownTrackIDsSpansEverySection() {
        var queue = PlayQueue()
        queue.replace(with: makeTracks(3), startingAt: 1)
        queue.setAutoQueue(makeTracks(1, prefix: "auto"))

        XCTAssertEqual(queue.knownTrackIDs, ["t0", "t1", "t2", "auto0"])
    }

    func testUpcomingReportsCurrentWhenRepeatingOne() {
        var queue = PlayQueue()
        queue.replace(with: makeTracks(2), startingAt: 0)
        queue.repeatMode = .one

        XCTAssertEqual(queue.upcoming?.track.id, "t0")
    }
}
