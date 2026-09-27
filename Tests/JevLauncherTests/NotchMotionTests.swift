import XCTest
@testable import JevLauncher

final class NotchMotionTests: XCTestCase {
    func testGrowSpringsSettleWithoutVisibleOvershoot() {
        for spring in [NotchMotion.growWidth, NotchMotion.growHeight] {
            XCTAssertTrue((0.45...0.5).contains(spring.response))
            XCTAssertTrue((0.85...0.9).contains(spring.damping))
            XCTAssertLessThan(spring.overshoot, 0.005, "Under 1 pt on a 200 pt move")
        }
        XCTAssertEqual(NotchMotion.Spring(response: 0.4, damping: 1).overshoot, 0)
    }

    func testWidthLeadsOnGrowAndHeightLeadsOnRetract() {
        XCTAssertLessThan(NotchMotion.growWidth.response, NotchMotion.growHeight.response)
        XCTAssertLessThan(NotchMotion.retractHeight.response, NotchMotion.retractWidth.response)
        XCTAssertLessThan(NotchMotion.retractWidth.response, NotchMotion.growWidth.response, "Retract is faster")
        XCTAssertEqual(NotchMotion.slower(NotchMotion.growWidth, NotchMotion.growHeight), NotchMotion.growHeight)
        XCTAssertEqual(NotchMotion.slower(NotchMotion.retractWidth, NotchMotion.retractHeight), NotchMotion.retractWidth)
    }

    func testContentTiming() {
        XCTAssertTrue((0.08...0.12).contains(NotchMotion.contentDelay))
        XCTAssertTrue((4...6).contains(NotchMotion.contentSlide))
        XCTAssertLessThanOrEqual(NotchMotion.contentOut, 0.12)
    }

    func testReduceMotionHasNoShapeSpring() {
        XCTAssertNil(NotchMotion.width(closing: false, reduceMotion: true))
        XCTAssertNil(NotchMotion.height(closing: true, reduceMotion: true))
        XCTAssertNotNil(NotchMotion.width(closing: false, reduceMotion: false))
    }

    func testCloseSequenceIgnoresStaleCompletions() {
        var sequence = NotchCloseSequence()
        let first = sequence.begin()
        XCTAssertTrue(sequence.isCurrent(first))
        sequence.cancel()
        XCTAssertFalse(sequence.isCurrent(first), "A new alert cancels the close")
        let second = sequence.begin()
        XCTAssertFalse(sequence.finish(first))
        XCTAssertTrue(sequence.finish(second))
        XCTAssertFalse(sequence.finish(second), "Finishes once")
    }

    func testMaxPanelFrameHoldsEveryMode() {
        let screens = [
            NotchGeometry(screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982), notchWidth: 200, notchHeight: 32),
            NotchGeometry(screenFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080), notchWidth: 0, notchHeight: 0),
            NotchGeometry(screenFrame: CGRect(x: 0, y: 0, width: 3000, height: 1200), notchWidth: 300, notchHeight: 38)
        ]
        let single = NotchAlert(id: "a", kind: .question, symbol: "q", title: "Q", message: "M", choices: ["A", "B"])
        let members = (0..<6).map { NotchAlert(id: "m\($0)", kind: .failure, symbol: "x", title: "F", message: "M") }
        let stack = NotchQueue.stack(members)
        for g in screens {
            let max = g.maxPanelFrame
            for alert in [single, stack, nil] {
                for mode in [NotchState.Mode.pill, .card, .detail, .reply] {
                    let frame = g.panelFrame(mode, alert: alert)
                    XCTAssertTrue(max.contains(frame), "\(mode) on \(g.notchWidth)")
                    XCTAssertEqual(frame.midX, max.midX)
                    XCTAssertEqual(frame.maxY, max.maxY)
                }
            }
        }
    }
}
