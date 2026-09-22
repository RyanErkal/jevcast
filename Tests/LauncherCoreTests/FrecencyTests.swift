import XCTest
@testable import LauncherCore

final class FrecencyTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    func testScoreHalvesAfterHalfLife() {
        var frecency = Frecency()
        frecency.record("app:/Safari.app", query: "saf", now: start)
        frecency.record("app:/Safari.app", query: "saf", now: start)
        XCTAssertEqual(frecency.score("app:/Safari.app", now: start), 2, accuracy: 0.0001)
        XCTAssertEqual(frecency.score("app:/Safari.app", now: start + Frecency.halfLife), 1, accuracy: 0.0001)
    }

    func testRecordsAreCappedByLowestScore() {
        var frecency = Frecency()
        frecency.record("keep", query: "", now: start + 10)
        frecency.record("keep", query: "", now: start + 10)
        for index in 0..<Frecency.maxRecords { frecency.record("id\(index)", query: "", now: start) }
        XCTAssertEqual(frecency.records.count, Frecency.maxRecords)
        XCTAssertNotNil(frecency.records["keep"])
    }

    func testPicksAreCapped() {
        var frecency = Frecency()
        for index in 0...(Frecency.maxPicks + 20) { frecency.record("a", query: "q\(index)", now: start + Double(index)) }
        XCTAssertEqual(frecency.picks.count, Frecency.maxPicks)
        XCTAssertNil(frecency.learned(for: "q0", now: start))
        XCTAssertNotNil(frecency.learned(for: "q\(Frecency.maxPicks + 20)", now: start))
    }

    func testSingleLetterLearnsPickAndBoostsOnlyThatID() {
        var frecency = Frecency()
        frecency.record("app:/Safari.app", query: "S ", now: start)
        XCTAssertEqual(frecency.learned(for: "s", now: start)?.id, "app:/Safari.app")
        XCTAssertGreaterThan(frecency.boost(for: "app:/Safari.app", query: "s", now: start),
                             frecency.boost(for: "app:/Safari.app", query: "x", now: start))
        XCTAssertEqual(frecency.boost(for: "app:/Slack.app", query: "s", now: start), 0)
    }

    func testDifferentPickDisplacesLearnedIDGradually() {
        var frecency = Frecency()
        frecency.record("safari", query: "s", now: start)
        frecency.record("safari", query: "s", now: start)
        frecency.record("slack", query: "s", now: start)
        XCTAssertEqual(frecency.learned(for: "s", now: start)?.id, "safari")
        frecency.record("slack", query: "s", now: start)
        XCTAssertEqual(frecency.learned(for: "s", now: start)?.id, "slack")
    }

    func testBoostIsBoundedBelowOne() {
        var frecency = Frecency()
        for _ in 0..<500 { frecency.record("a", query: "a", now: start) }
        XCTAssertLessThan(frecency.boost(for: "a", query: "a", now: start), 1)
    }

    func testLegacyUsageMigratesWithCap() {
        let frecency = Frecency(legacyUsage: ["a": 3, "b": 900, "c": 0], now: start)
        XCTAssertEqual(frecency.score("a", now: start), 3)
        XCTAssertEqual(frecency.score("b", now: start), 20)
        XCTAssertNil(frecency.records["c"])
    }

    func testCodableRoundTrip() throws {
        var frecency = Frecency()
        frecency.record("a", query: "ab", now: start)
        let decoded = try JSONDecoder().decode(Frecency.self, from: JSONEncoder().encode(frecency))
        XCTAssertEqual(decoded, frecency)
    }
}
