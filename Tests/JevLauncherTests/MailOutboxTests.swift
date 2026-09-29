import XCTest
@testable import JevLauncher

/// Mail quits only once its Outbox is empty, and waits about a minute at most. Fake counts stand in for Mail.
final class MailOutboxTests: XCTestCase {
    private final class Counts: @unchecked Sendable {
        private var values: [Int?]
        private(set) var reads = 0
        init(_ values: [Int?]) { self.values = values }
        func next() -> Int? { reads += 1; return values.isEmpty ? nil : values.removeFirst() }
    }

    private func wait(_ values: [Int?], tries: Int = 3) async -> (empty: Bool, reads: Int) {
        let counts = Counts(values)
        let empty = await MailOutbox.waitUntilEmpty(tries: tries, interval: 0) { counts.next() }
        return (empty, counts.reads)
    }

    func testWaitsUntilTheOutboxIsEmpty() async {
        let result = await wait([2, 1, 0, 4], tries: 10)
        XCTAssertTrue(result.empty)
        XCTAssertEqual(result.reads, 3)
    }

    func testAnEmptyOutboxDoesNotWait() async {
        let counts = Counts([0])
        let started = Date()
        let empty = await MailOutbox.waitUntilEmpty(tries: 30, interval: 2) { counts.next() }
        XCTAssertTrue(empty)
        XCTAssertEqual(counts.reads, 1)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
    }

    func testMailStillSendingAtTheLimitKeepsRunning() async {
        let result = await wait([1, 1, 1, 0])
        XCTAssertFalse(result.empty)
        XCTAssertEqual(result.reads, 3, "It stops at the limit")
    }

    func testAFailedCountKeepsTheLastOne() async {
        let held = await wait([1, nil, nil])
        XCTAssertFalse(held.empty, "Mail still had mail when it last answered")
        let unknown = await wait([nil, nil, nil])
        XCTAssertTrue(unknown.empty, "Mail that never answers quits as before")
        let later = await wait([nil, 0, 3])
        XCTAssertTrue(later.empty)
        XCTAssertEqual(later.reads, 2)
    }

    func testCancellingStopsTheWait() async {
        let waiting = Task { await MailOutbox.waitUntilEmpty(tries: 1000, interval: 10) { 1 } }
        try? await Task.sleep(nanoseconds: 50_000_000)
        waiting.cancel()
        let started = Date()
        _ = await waiting.value
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }
}
