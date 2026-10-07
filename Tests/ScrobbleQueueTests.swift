import XCTest
@testable import Aura

/// The queue is what makes scrobbling survive a tunnel. These tests use a
/// temporary file so persistence is exercised for real rather than mocked.
final class ScrobbleQueueTests: XCTestCase {

    private var fileURL: URL!

    override func setUp() {
        super.setUp()
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("scrobble-queue-\(UUID().uuidString).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: fileURL)
        super.tearDown()
    }

    private func play(_ name: String, at offset: TimeInterval = 0) -> Scrobble {
        Scrobble(
            artist: "Artist",
            track: name,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000 + offset)
        )
    }

    // MARK: - Basics

    func testEnqueueAndRead() async {
        let queue = ScrobbleQueue(fileURL: fileURL)
        await queue.enqueue(play("One"))
        await queue.enqueue(play("Two", at: 10))

        let pending = await queue.pending
        let count = await queue.count
        XCTAssertEqual(pending.map(\.track), ["One", "Two"])
        XCTAssertEqual(count, 2)
    }

    func testBatchIsOldestFirstAndCapped() async {
        let queue = ScrobbleQueue(fileURL: fileURL)
        await queue.enqueue((0..<10).map { play("T\($0)", at: Double($0)) })

        let batch = await queue.nextBatch(limit: 3)
        XCTAssertEqual(batch.map(\.track), ["T0", "T1", "T2"])
    }

    func testRemoveTakesAcceptedEntriesOut() async {
        let queue = ScrobbleQueue(fileURL: fileURL)
        let first = play("One")
        await queue.enqueue([first, play("Two", at: 10)])

        await queue.remove(ids: [first.id])
        let remaining = await queue.pending
        XCTAssertEqual(remaining.map(\.track), ["Two"])
    }

    // MARK: - Persistence

    func testSurvivesAReload() async {
        let first = ScrobbleQueue(fileURL: fileURL)
        await first.enqueue(play("Persisted"))

        // A fresh instance over the same file is what a relaunch looks like.
        let second = ScrobbleQueue(fileURL: fileURL)
        let reloaded = await second.pending
        XCTAssertEqual(reloaded.map(\.track), ["Persisted"])
    }

    func testTimestampSurvivesTheRoundTrip() async throws {
        // Backdating is the whole point: a play held offline must land in the
        // right place in history.
        let queue = ScrobbleQueue(fileURL: fileURL)
        let original = play("Backdated", at: 500)
        await queue.enqueue(original)

        let reloaded = ScrobbleQueue(fileURL: fileURL)
        let pending = await reloaded.pending
        let restored = try XCTUnwrap(pending.first)
        XCTAssertEqual(
            restored.startedAt.timeIntervalSince1970,
            original.startedAt.timeIntervalSince1970,
            accuracy: 0.001
        )
    }

    func testCorruptFileStartsEmptyRatherThanWedging() async {
        try? Data("not json at all".utf8).write(to: fileURL)

        let queue = ScrobbleQueue(fileURL: fileURL)
        let initial = await queue.count
        XCTAssertEqual(initial, 0)

        // And remains usable.
        await queue.enqueue(play("After"))
        let afterWrite = await queue.count
        XCTAssertEqual(afterWrite, 1)
    }

    func testNilFileURLWorksInMemory() async {
        let queue = ScrobbleQueue(fileURL: nil)
        await queue.enqueue(play("Ephemeral"))
        let count = await queue.count
        XCTAssertEqual(count, 1)
    }

    // MARK: - Capacity

    func testOldestEntriesAreDroppedAtCapacity() async {
        let queue = ScrobbleQueue(fileURL: fileURL, capacity: 5)
        await queue.enqueue((0..<8).map { play("T\($0)", at: Double($0)) })

        let pending = await queue.pending
        XCTAssertEqual(pending.count, 5)
        XCTAssertEqual(pending.map(\.track), ["T3", "T4", "T5", "T6", "T7"],
                       "the newest plays are the ones worth keeping")
    }

    // MARK: - Failure handling

    func testFailureIncrementsAttemptsAndKeepsTheEntry() async {
        let queue = ScrobbleQueue(fileURL: fileURL, maximumAttempts: 3)
        let entry = play("Retry")
        await queue.enqueue(entry)

        let abandoned = await queue.recordFailure(ids: [entry.id])
        let pending = await queue.pending
        XCTAssertTrue(abandoned.isEmpty)
        XCTAssertEqual(pending.first?.attempts, 1)
    }

    func testEntryIsAbandonedAfterTooManyAttempts() async {
        let queue = ScrobbleQueue(fileURL: fileURL, maximumAttempts: 3)
        let entry = play("Doomed")
        await queue.enqueue(entry)

        _ = await queue.recordFailure(ids: [entry.id])
        _ = await queue.recordFailure(ids: [entry.id])
        let abandoned = await queue.recordFailure(ids: [entry.id])

        let remaining = await queue.count
        XCTAssertEqual(abandoned, [entry.id])
        XCTAssertEqual(remaining, 0, "a permanently failing entry must not block the queue")
    }

    func testFailureOnlyAffectsNamedEntries() async {
        let queue = ScrobbleQueue(fileURL: fileURL)
        let first = play("One")
        let second = play("Two", at: 10)
        await queue.enqueue([first, second])

        _ = await queue.recordFailure(ids: [first.id])
        let pending = await queue.pending

        XCTAssertEqual(pending.first(where: { $0.id == first.id })?.attempts, 1)
        XCTAssertEqual(pending.first(where: { $0.id == second.id })?.attempts, 0)
    }

    func testAttemptCountPersists() async {
        let queue = ScrobbleQueue(fileURL: fileURL)
        let entry = play("Counted")
        await queue.enqueue(entry)
        _ = await queue.recordFailure(ids: [entry.id])

        let reloaded = ScrobbleQueue(fileURL: fileURL)
        let restored = await reloaded.pending
        XCTAssertEqual(restored.first?.attempts, 1)
    }

    func testRemoveAllClearsFileAndMemory() async {
        let queue = ScrobbleQueue(fileURL: fileURL)
        await queue.enqueue(play("Gone"))
        await queue.removeAll()

        let count = await queue.count
        let afterReload = await ScrobbleQueue(fileURL: fileURL).count
        XCTAssertEqual(count, 0)
        XCTAssertEqual(afterReload, 0)
    }
}
