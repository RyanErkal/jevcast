import XCTest
@testable import JevLauncher

final class AppIdentityTests: XCTestCase {
    /// scripts/build.sh writes Info.plist. Its name and bundle ID must match the code,
    /// or preferences, the Keychain item, and logs split across two identities.
    func testBuildScriptMatchesAppIdentity() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let script = try String(contentsOf: root.appendingPathComponent("scripts/build.sh"), encoding: .utf8)
        XCTAssertTrue(script.contains("APP_NAME=\"\(AppIdentity.name)\""), "build.sh APP_NAME differs from AppIdentity.name")
        XCTAssertTrue(script.contains("BUNDLE_ID=\"\(AppIdentity.bundleID)\""), "build.sh BUNDLE_ID differs from AppIdentity.bundleID")
    }

    func testVersionOutsideTheAppBundleIsZero() {
        XCTAssertEqual(AppIdentity.version, "0.0.0", "Tests run inside another program's bundle.")
    }
}
