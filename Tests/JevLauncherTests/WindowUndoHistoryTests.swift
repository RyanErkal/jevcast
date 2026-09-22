import CoreGraphics
import XCTest
@testable import JevLauncher

final class WindowUndoHistoryTests: XCTestCase {
    private typealias History = WindowUndoHistory<String, String>

    func testBulkRestorePopsOnlyWindowsTheArrangementMoved() {
        var history = History()
        let earlierB = CGRect(x: 1, y: 1, width: 100, height: 100)
        history.recordSingle(earlierB, for: "b")
        let originalA = CGRect(x: 0, y: 0, width: 500, height: 400)
        // "b" was already in place, so the arrangement moved only "a".
        history.recordBulk(members: ["a", "b"], moved: [.init(key: "a", original: originalA, element: "a-window")])

        let moves = history.bulkMoves(including: "b")
        XCTAssertEqual(moves?.map(\.key), ["a"])
        XCTAssertEqual(moves?.first?.original, originalA)
        history.completeBulkRestore(restored: ["a"])

        XCTAssertNil(history.bulk)
        XCTAssertNil(history.stacks["a"])
        // The unmoved window keeps its earlier, unrelated undo entry.
        XCTAssertEqual(history.stacks["b"], [earlierB])
    }

    func testFailedBulkRestoreKeepsThatWindowsEntry() {
        var history = History()
        let a = CGRect(x: 0, y: 0, width: 10, height: 10)
        let b = CGRect(x: 5, y: 5, width: 10, height: 10)
        history.recordBulk(members: ["a", "b"], moved: [.init(key: "a", original: a, element: ""), .init(key: "b", original: b, element: "")])
        history.completeBulkRestore(restored: ["a"])
        XCTAssertNil(history.stacks["a"])
        XCTAssertEqual(history.popLast(for: "b"), b)
    }

    func testBulkWithoutMovesAndSingleActionsEndTheBulkEntry() {
        var history = History()
        history.recordBulk(members: ["a"], moved: [])
        XCTAssertNil(history.bulk)
        XCTAssertNil(history.bulkMoves(including: "a"))

        history.recordBulk(members: ["a", "c"], moved: [.init(key: "a", original: .zero, element: "")])
        XCTAssertNil(history.bulkMoves(including: "z"))
        history.recordSingle(CGRect(x: 1, y: 2, width: 3, height: 4), for: "c")
        XCTAssertNil(history.bulkMoves(including: "a"))
    }

    func testStacksAreBoundedAndEmptyStacksHaveNothingToRestore() {
        var history = History(limit: 2)
        XCTAssertNil(history.popLast(for: "a"))
        for x in 0..<3 { history.recordSingle(CGRect(x: CGFloat(x), y: 0, width: 1, height: 1), for: "a") }
        XCTAssertEqual(history.stacks["a"]?.map(\.minX), [1, 2])
        let last = history.popLast(for: "a")!
        history.reinstate(last, for: "a")
        XCTAssertEqual(history.stacks["a"]?.map(\.minX), [1, 2])
    }
}
