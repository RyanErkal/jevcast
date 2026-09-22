import Foundation

/// Names, identifiers, and links. `scripts/build.sh` repeats the name and the
/// bundle ID, and a test checks that the two agree, so a rename touches this
/// file, that script, and user-facing strings found by searching for the name.
enum AppIdentity {
    static let name = "Jevcast"
    /// Also the preferences domain, the Keychain service, and the log subsystem.
    static let bundleID = "com.ryanerkal.jevlauncher"
    static let repository = URL(string: "https://github.com/RyanErkal/jevcast")!
    static let website = URL(string: "https://jevcast.vercel.app")!
    static let issues = URL(string: "https://github.com/RyanErkal/jevcast/issues")!
    static let releases = URL(string: "https://github.com/RyanErkal/jevcast/releases")!
    static let latestReleaseAPI = URL(string: "https://api.github.com/repos/RyanErkal/jevcast/releases/latest")!
    static let typeSafe = URL(string: "https://typesafe.ai")!

    /// The app's marketing version, or "0.0.0" when this code runs outside the
    /// app bundle (tests, `swift run`), whose main bundle is another program's.
    static var version: String {
        guard Bundle.main.bundleIdentifier == bundleID else { return "0.0.0" }
        return Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }
}
