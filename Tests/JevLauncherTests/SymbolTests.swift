import AppKit
import XCTest
import LauncherCore

final class SymbolTests: XCTestCase {
    /// A missing SF Symbol draws nothing, so a row loses its icon without any error.
    func testEveryWindowActionSymbolExists() {
        for action in WindowAction.allCases {
            XCTAssertNotNil(NSImage(systemSymbolName: action.symbol, accessibilityDescription: nil), "\(action) uses missing symbol \(action.symbol)")
        }
    }
}
