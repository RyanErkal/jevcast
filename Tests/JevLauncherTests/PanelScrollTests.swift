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
                NativeScrollFixture().frame(height: 300)
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
                let content = try XCTUnwrap(panel.contentView)
                let point = scroll.convert(NSPoint(x: scroll.bounds.midX, y: scroll.bounds.midY), to: content)
                let hit = try XCTUnwrap(content.hitTest(point))
                XCTAssertTrue(hit === scroll || hit.isDescendant(of: scroll), "The panel surface must pass pointer events to the list.")
                let windowPoint = scroll.convert(NSPoint(x: scroll.bounds.midX, y: scroll.bounds.midY), to: nil)
                let screenPoint = panel.convertPoint(toScreen: windowPoint)
                for _ in 0..<3 {
                    let event = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -40, wheel2: 0, wheel3: 0))
                    // CGEvent uses a top-left screen origin; AppKit's screen coordinates use a
                    // bottom-left origin. The event is delivered through the private test panel,
                    // not posted to the user's desktop.
                    event.location = CGPoint(
                        x: screenPoint.x,
                        y: (NSScreen.screens.first?.frame.height ?? 0) - screenPoint.y
                    )
                    panel.sendEvent(try XCTUnwrap(NSEvent(cgEvent: event)))
                    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                }
                RunLoop.main.run(until: Date().addingTimeInterval(0.2))
                XCTAssertGreaterThan(scroll.contentView.bounds.origin.y, 0, "glass: \(glass), \(type(of: scroll))")
            }
            panel.orderOut(nil)
        }
    }

    /// A tall native document gives AppKit a real scroll target. SwiftUI's HostingScrollView ignores
    /// test-created NSEvents on macOS 26 because they cannot carry the window-backed event metadata
    /// that the private SwiftUI scroll behavior expects. The panel contract under test is the native
    /// hit-test and NSWindow dispatch path, so this fixture keeps that path real and deterministic.
    private struct NativeScrollFixture: NSViewRepresentable {
        private static let documentHeight: CGFloat = 7_592

        func makeNSView(context: Context) -> NSScrollView {
            let scroll = NSScrollView()
            scroll.hasVerticalScroller = true
            scroll.autohidesScrollers = true
            scroll.scrollerStyle = .overlay
            scroll.drawsBackground = false
            scroll.documentView = TallDocumentView(frame: NSRect(x: 0, y: 0, width: 1, height: Self.documentHeight))
            return scroll
        }

        func updateNSView(_ scroll: NSScrollView, context: Context) {
            scroll.documentView?.frame.size = NSSize(width: max(1, scroll.contentView.bounds.width), height: Self.documentHeight)
        }
    }

    private final class TallDocumentView: NSView {
        override var isFlipped: Bool { true }
    }

    private func scrollViews(in view: NSView) -> [NSScrollView] {
        (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
    }
}
