import XCTest
import SwiftUI
@testable import JevLauncher

/// Pointer events must reach the panel content: scrolling a list in the panel moves it.
final class PanelScrollTests: XCTestCase {
    @MainActor func testScrollWheelMovesListsInsideThePanel() throws {
        for glass in [true, false] {
            let panel = LauncherPanel(glass: glass)
            panel.acceptsKey = false
            panel.host(VStack(spacing: 0) {
                ScrollView { LazyVStack { ForEach(0..<200, id: \.self) { Text("row \($0)").frame(height: 30) } } }.frame(height: 300)
                List(0..<200, id: \.self) { Text("row \($0)") }.frame(height: 300)
            }.frame(width: 680).fixedSize(horizontal: false, vertical: true))
            panel.setFrame(NSRect(x: 100, y: 100, width: 680, height: 600), display: true)
            // Invisible, as in snapshot runs; the window must be ordered in to take events.
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            let scrolls = scrollViews(in: try XCTUnwrap(panel.contentView))
            XCTAssertEqual(scrolls.count, 2)
            for scroll in scrolls {
                let point = panel.convertPoint(toScreen: scroll.convert(NSPoint(x: scroll.bounds.midX, y: scroll.bounds.midY), to: nil))
                let flipped = CGPoint(x: point.x, y: (NSScreen.screens.first?.frame.height ?? 0) - point.y)
                for _ in 0..<3 {
                    let event = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -40, wheel2: 0, wheel3: 0))
                    event.location = flipped
                    panel.sendEvent(try XCTUnwrap(NSEvent(cgEvent: event)))
                    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                }
                RunLoop.main.run(until: Date().addingTimeInterval(0.2))
                XCTAssertGreaterThan(scroll.contentView.bounds.origin.y, 0, "glass: \(glass), \(type(of: scroll))")
            }
            panel.orderOut(nil)
        }
    }
    private func scrollViews(in view: NSView) -> [NSScrollView] {
        (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
    }
}
