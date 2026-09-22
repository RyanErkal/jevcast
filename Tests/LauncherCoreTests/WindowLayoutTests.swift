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

    func testAlmostMaximizeIsCenteredNinetyPercent() {
        let screen = CGRect(x: -1000, y: 25, width: 1000, height: 800)
        XCTAssertEqual(WindowLayout.frame(for: .almostMaximize, in: screen), CGRect(x: -950, y: 65, width: 900, height: 720))
        XCTAssertTrue(WindowAction.almostMaximize.aliases.contains("almost max"))
    }
    func testHalvesCycleHalfTwoThirdsThirdAgainstTheirEdge() {
        let screen = CGRect(x: 0, y: 0, width: 1200, height: 900)
        let left = WindowLayout.cycleFrames(for: .leftHalf, in: screen, gap: 0)
        XCTAssertEqual(left.map(\.width), [600, 800, 400])
        XCTAssertEqual(left.first, WindowLayout.frame(for: .leftHalf, in: screen, gap: 0))
        XCTAssertTrue(left.allSatisfy { $0.minX == 0 && $0.height == 900 })
        let right = WindowLayout.cycleFrames(for: .rightHalf, in: screen, gap: 8)
        XCTAssertTrue(right.allSatisfy { $0.maxX == screen.maxX - 8 })
        XCTAssertEqual(right.first, WindowLayout.frame(for: .rightHalf, in: screen, gap: 8))
        let top = WindowLayout.cycleFrames(for: .topHalf, in: screen, gap: 0)
        XCTAssertEqual(top.map(\.height), [450, 600, 300])
        XCTAssertTrue(top.allSatisfy { $0.minY == 0 && $0.width == 1200 })
        let bottom = WindowLayout.cycleFrames(for: .bottomHalf, in: screen, gap: 0)
        XCTAssertEqual(bottom.map(\.height), [450, 600, 300])
        XCTAssertTrue(bottom.allSatisfy { $0.maxY == 900 })
        let center = WindowLayout.cycleFrames(for: .centerThird, in: screen, gap: 0)
        XCTAssertEqual(center.map(\.width), [400, 600, 800])
        XCTAssertTrue(center.allSatisfy { $0.midX == screen.midX })
        XCTAssertEqual(WindowLayout.cycleFrames(for: .maximize, in: screen), [])
        for action in [WindowAction.leftHalf, .rightHalf, .topHalf, .bottomHalf, .centerThird] {
            XCTAssertTrue(WindowLayout.cycleFrames(for: action, in: screen, gap: 8).allSatisfy(screen.contains))
        }
    }
    func testCycleIndexUsesCurrentFrameThenRememberedStep() {
        let screen = CGRect(x: 0, y: 0, width: 1200, height: 900)
        let frames = WindowLayout.cycleFrames(for: .leftHalf, in: screen, gap: 0)
        XCTAssertEqual(WindowLayout.nextCycleIndex(current: CGRect(x: 300, y: 200, width: 500, height: 400), frames: frames), 0)
        XCTAssertEqual(WindowLayout.nextCycleIndex(current: frames[0].offsetBy(dx: 2, dy: 1), frames: frames), 1)
        XCTAssertEqual(WindowLayout.nextCycleIndex(current: frames[1], frames: frames), 2)
        XCTAssertEqual(WindowLayout.nextCycleIndex(current: frames[2], frames: frames), 0)
        // A window held wider by its minimum size advances from the remembered step.
        let heldWide = CGRect(x: 0, y: 0, width: 700, height: 900)
        XCTAssertEqual(WindowLayout.nextCycleIndex(current: heldWide, frames: frames, previousIndex: 0), 1)
        XCTAssertEqual(WindowLayout.nextCycleIndex(current: heldWide, frames: frames, previousIndex: 9), 0)
        XCTAssertEqual(WindowLayout.nextCycleIndex(current: heldWide, frames: []), 0)
    }
    func testAnchoredFrameKeepsFixedSizeWindowsOnTheirEdge() {
        let screen = CGRect(x: 0, y: 25, width: 1200, height: 875)
        let right = WindowLayout.frame(for: .rightHalf, in: screen, gap: 8)!
        let wide = CGSize(width: 800, height: 500)
        let anchoredRight = WindowLayout.anchoredFrame(size: wide, target: right, in: screen)!
        XCTAssertEqual(anchoredRight.maxX, right.maxX)
        // A full-height target is symmetric vertically, so the window stays centered there.
        XCTAssertEqual(anchoredRight.midY, right.midY)
        let left = WindowLayout.frame(for: .leftHalf, in: screen, gap: 8)!
        XCTAssertEqual(WindowLayout.anchoredFrame(size: wide, target: left, in: screen)!.minX, left.minX)
        let bottom = WindowLayout.frame(for: .bottomRightQuarter, in: screen, gap: 8)!
        let anchoredBottom = WindowLayout.anchoredFrame(size: CGSize(width: 300, height: 200), target: bottom, in: screen)!
        XCTAssertEqual(anchoredBottom.maxY, bottom.maxY)
        XCTAssertEqual(anchoredBottom.maxX, bottom.maxX)
        let maximized = WindowLayout.frame(for: .maximize, in: screen, gap: 8)!
        let small = WindowLayout.anchoredFrame(size: CGSize(width: 400, height: 300), target: maximized, in: screen)!
        XCTAssertEqual(small.midX, maximized.midX)
        XCTAssertEqual(small.midY, maximized.midY)
        let oversized = WindowLayout.anchoredFrame(size: CGSize(width: 1500, height: 1000), target: right, in: screen)!
        XCTAssertEqual(oversized.origin, screen.origin)
        XCTAssertNil(WindowLayout.anchoredFrame(size: .zero, target: right, in: screen))
    }
    func testEdgeSnappingIgnoresEdgesSharedWithAnotherDisplay() {
        let main = CGRect(x: 0, y: 0, width: 1000, height: 800)
        XCTAssertEqual(WindowLayout.edgeSnapAction(at: CGPoint(x: 2, y: 400), displays: [main]), .leftHalf)
        XCTAssertEqual(WindowLayout.edgeSnapAction(at: CGPoint(x: 999, y: 400), displays: [main]), .rightHalf)
        XCTAssertEqual(WindowLayout.edgeSnapAction(at: CGPoint(x: 500, y: 0), displays: [main]), .topHalf)
        XCTAssertEqual(WindowLayout.edgeSnapAction(at: CGPoint(x: 500, y: 800), displays: [main]), .bottomHalf)
        XCTAssertEqual(WindowLayout.edgeSnapAction(at: CGPoint(x: 1, y: 1), displays: [main]), .topLeftQuarter)
        XCTAssertNil(WindowLayout.edgeSnapAction(at: CGPoint(x: 500, y: 400), displays: [main]))

        // A shorter display to the right shares only the upper part of the edge.
        let side = CGRect(x: 1000, y: 0, width: 800, height: 500)
        let displays = [main, side]
        XCTAssertNil(WindowLayout.edgeSnapAction(at: CGPoint(x: 999, y: 300), displays: displays))
        XCTAssertNil(WindowLayout.edgeSnapAction(at: CGPoint(x: 1001, y: 300), displays: displays))
        XCTAssertEqual(WindowLayout.edgeSnapAction(at: CGPoint(x: 999, y: 700), displays: displays), .rightHalf)
        XCTAssertEqual(WindowLayout.edgeSnapAction(at: CGPoint(x: 1799, y: 300), displays: displays), .rightHalf)
        // The corner beside the shared edge snaps to the unshared top edge only.
        XCTAssertEqual(WindowLayout.edgeSnapAction(at: CGPoint(x: 999, y: 1), displays: displays), .topHalf)
        XCTAssertEqual(WindowLayout.edgeSnapAction(at: CGPoint(x: 1001, y: 1), displays: displays), .topHalf)

        // A display stacked above makes the main display's top edge shared.
        let above = CGRect(x: 0, y: -900, width: 1440, height: 900)
        XCTAssertNil(WindowLayout.edgeSnapAction(at: CGPoint(x: 500, y: 0), displays: [main, above]))
        XCTAssertEqual(WindowLayout.edgeSnapAction(at: CGPoint(x: 500, y: -899), displays: [main, above]), .topHalf)
    }
    func testDisplayMoveUsesTheTestedDisplayOrder() {
        let main = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let left = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        let displays = [main, left]
        let window = CGRect(x: 100, y: 100, width: 720, height: 450)
        XCTAssertEqual(WindowLayout.displayIndex(for: window, displays: displays), 0)
        XCTAssertEqual(WindowLayout.adjacentDisplayIndex(for: window, displays: displays, offset: 1), 1)
        XCTAssertEqual(WindowLayout.adjacentDisplayIndex(for: window, displays: displays, offset: -1), 1)
        let moved = WindowLayout.frame(window, movedFrom: main, to: left)!
        XCTAssertEqual(moved.minX, -1920 + 100 * 1920 / 1440, accuracy: 0.001)
        XCTAssertEqual(moved.minY, 120, accuracy: 0.001)
        XCTAssertEqual(moved.width, 960, accuracy: 0.001)
        XCTAssertEqual(moved.height, 540, accuracy: 0.001)
        let oversized = WindowLayout.frame(CGRect(x: 1400, y: 850, width: 1440, height: 900), movedFrom: main, to: left)!
        XCTAssertTrue(left.contains(oversized))
        XCTAssertNil(WindowLayout.displayIndex(for: window, displays: []))
    }
}
