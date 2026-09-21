import XCTest
import CoreGraphics
@testable import LauncherCore

final class WindowLayoutTests: XCTestCase {
    func testHalvesRespectNonzeroOriginAndGap() {
        let screen = CGRect(x: -1920, y: 24, width: 1920, height: 1056)
        let left = WindowLayout.frame(for: .leftHalf, in: screen, gap: 8)!
        let right = WindowLayout.frame(for: .rightHalf, in: screen, gap: 8)!
        XCTAssertEqual(left, CGRect(x: -1912, y: 32, width: 948, height: 1040))
        XCTAssertEqual(right.minX - left.maxX, 8)
        XCTAssertEqual(right.maxX, screen.maxX - 8)
    }
    func testQuartersAndSixthsUseTopLeftAXCoordinates() {
        let screen = CGRect(x: 100, y: -900, width: 1200, height: 900)
        XCTAssertEqual(WindowLayout.frame(for: .topLeftQuarter, in: screen, gap: 0), CGRect(x: 100, y: -900, width: 600, height: 450))
        XCTAssertEqual(WindowLayout.frame(for: .bottomRightSixth, in: screen, gap: 0), CGRect(x: 900, y: -450, width: 400, height: 450))
        XCTAssertEqual(WindowLayout.frame(for: .leftTwoThirds, in: screen, gap: 0)?.width, 800)
    }
    func testAllGridActionsStayInsideDisplay() {
        for screen in [CGRect(x: -1800, y: -800, width: 1800, height: 1000), CGRect(x: 0, y: 0, width: 30, height: 20)] {
            for gap: CGFloat in [0, 8, 1000] {
                for action in WindowAction.allCases {
                    if let frame = WindowLayout.frame(for: action, in: screen, gap: gap) {
                        XCTAssertTrue(screen.contains(frame), "\(action) \(frame)")
                        XCTAssertGreaterThan(frame.width, 0)
                        XCTAssertGreaterThan(frame.height, 0)
                    }
                }
            }
        }
    }
    func testMaximiseIsNotNativeFullscreen() {
        let screen = CGRect(x: 0, y: 25, width: 1440, height: 850)
        XCTAssertEqual(WindowLayout.frame(for: .maximize, in: screen, gap: 0), screen)
        XCTAssertNil(WindowLayout.frame(for: .fullscreen, in: screen))
    }
    func testUnsortedDisplaysWrapAndUseOriginalIndices() {
        let main = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let left = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        let upper = CGRect(x: 0, y: -1000, width: 1440, height: 1000)
        let displays = [main, left, upper]
        XCTAssertEqual(WindowLayout.adjacentDisplayIndex(for: main, displays: displays, offset: 1), 1)
        XCTAssertEqual(WindowLayout.adjacentDisplayIndex(for: main, displays: displays, offset: -1), 2)
        XCTAssertEqual(WindowLayout.adjacentDisplayIndex(for: left, displays: displays, offset: 1), 2)
        XCTAssertEqual(WindowLayout.adjacentDisplayIndex(for: upper, displays: displays, offset: 1), 0)
    }
    func testTouchingEdgeDoesNotSelectAdjacentDisplay() {
        let screens = [CGRect(x: 0, y: 0, width: 1000, height: 800), CGRect(x: 1000, y: 0, width: 1000, height: 800)]
        let window = CGRect(x: 500, y: 0, width: 500, height: 800)
        XCTAssertEqual(WindowLayout.adjacentDisplayIndex(for: window, displays: screens, offset: 1), 1)
    }
    func testCenterAndResizeClampOversizedWindows() {
        let screen = CGRect(x: -1200, y: 40, width: 1200, height: 800)
        let current = CGRect(x: -2000, y: -2000, width: 3000, height: 2000)
        let centered = WindowLayout.centeredFrame(current: current, in: screen, gap: 0)!
        XCTAssertEqual(centered, screen)
        let resized = WindowLayout.resizedFrame(current: current, in: screen, factor: 1.15, gap: 8)!
        XCTAssertTrue(screen.contains(resized))
    }
    func testGridAndInvalidGeometry() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let grid = WindowLayout.gridFrames(count: 7, in: screen)
        XCTAssertEqual(grid.count, 7)
        for (index, frame) in grid.enumerated() {
            XCTAssertTrue(screen.contains(frame))
            for other in grid.dropFirst(index + 1) { XCTAssertFalse(frame.intersects(other)) }
        }
        XCTAssertNil(WindowLayout.frame(for: .leftHalf, in: .zero))
        XCTAssertEqual(WindowLayout.gridFrames(count: 0, in: screen), [])
        XCTAssertNil(WindowLayout.resizedFrame(current: screen, in: screen, factor: .nan))
    }
}
