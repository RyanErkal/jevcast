import Foundation

/// Permissions and Open at Login belong to the copy in Applications. A copy that
/// runs from a disk image, Downloads, or a translocated quarantine path loses them.
enum InstallLocation {
    /// Why this copy should move to Applications, or nil when it is already there.
    static func warning(for bundle: URL = Bundle.main.bundleURL, home: String = NSHomeDirectory()) -> String? {
        let path = bundle.standardizedFileURL.path
        if path.contains("/AppTranslocation/") || path.hasPrefix("/Volumes/") {
            return "Drag \(AppIdentity.name) to the Applications folder, then open it from there. This copy runs from a temporary place, so permissions and Open at Login do not stay."
        }
        let folders = ["/Applications/", (home.hasSuffix("/") ? home : home + "/") + "Applications/"]
        guard !folders.contains(where: path.hasPrefix) else { return nil }
        return "Move \(AppIdentity.name) to the Applications folder, then open it from there. Permissions and Open at Login work best from Applications."
    }
}
