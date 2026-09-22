import Foundation
import XCTest
@testable import JevLauncher

final class AppCatalogueTests: XCTestCase {
    private func makeApp(at url: URL, name: String, id: String) throws {
        let contents = url.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info = ["CFBundleName": name, "CFBundleIdentifier": id, "CFBundlePackageType": "APPL"]
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
    }
    func testHiddenAppLinksRemainDiscoverable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let apps = root.appendingPathComponent("Applications")
        try FileManager.default.createDirectory(at: apps, withIntermediateDirectories: true)
        let actual = root.appendingPathComponent("System/Browser.app")
        try makeApp(at: actual, name: "Browser", id: "test.browser")
        let link = apps.appendingPathComponent("Browser.app")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: actual)
        var resource = URLResourceValues(); resource.isHidden = true
        var hidden = link; try hidden.setResourceValues(resource)
        let entries = AppCatalogue.scan(roots: [apps.path])
        XCTAssertEqual(entries.map(\.name), ["Browser"])
        XCTAssertEqual(entries.first?.path, actual.resolvingSymlinksInPath().path)
    }
    func testNestedAppsAreFoundButBundledHelpersAreNot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try makeApp(at: root.appendingPathComponent("Utilities/Tool.app"), name: "Tool", id: "test.tool")
        try makeApp(at: root.appendingPathComponent("Utilities/Tool.app/Contents/Helper.app"), name: "Helper", id: "test.helper")
        XCTAssertEqual(AppCatalogue.scan(roots: [root.path]).map(\.name), ["Tool"])
    }
    func testDirectAppRootsAndDuplicateAliases() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Finder.app")
        try makeApp(at: app, name: "Finder", id: "test.finder")
        XCTAssertEqual(AppCatalogue.scan(roots: [root.path, app.path]).count, 1)
    }
    private func makeExtension(in directory: URL, name: String, id: String, displayName: String?, point: String = "com.apple.Settings.extension.ui", allowsURL: Bool = true) throws {
        let contents = directory.appendingPathComponent(name + ".appex/Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        var info: [String: Any] = [
            "CFBundleIdentifier": id,
            "EXAppExtensionAttributes": [
                "EXExtensionPointIdentifier": point,
                "SettingsExtensionAttributes": ["allowsXAppleSystemPreferencesURLScheme": allowsURL]
            ]
        ]
        if let displayName { info["CFBundleDisplayName"] = displayName }
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
    }
    func testSettingsPanesComeFromSettingsExtensionsWithReadableTitles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try makeExtension(in: root, name: "Wi-Fi", id: "com.apple.wifi-settings-extension", displayName: "WiFiSettings")
        try makeExtension(in: root, name: "Storage", id: "com.apple.settings.Storage", displayName: "Storage")
        try makeExtension(in: root, name: "MouseExtension", id: "test.unknown.mouse", displayName: "MouseExtension")
        try makeExtension(in: root, name: "Widget", id: "test.widget", displayName: "Widget", point: "com.apple.widgetkit-extension")
        try makeExtension(in: root, name: "Home", id: "test.home", displayName: "Home", allowsURL: false)

        let entries = CatalogueSettingsPanes.entries(in: root.path)
        let byName = Dictionary(uniqueKeysWithValues: entries.map { ($0.name, $0) })
        XCTAssertEqual(Set(byName.keys), ["Wi-Fi Settings", "Storage Settings", "General Settings"])
        let wifi = try XCTUnwrap(byName["Wi-Fi Settings"])
        XCTAssertEqual(wifi.launchURL, "x-apple.systempreferences:com.apple.wifi-settings-extension")
        XCTAssertEqual(wifi.path, CatalogueSettingsPanes.systemSettingsPath)
        XCTAssertEqual(wifi.id, "app:x-apple.systempreferences:com.apple.wifi-settings-extension")
        XCTAssertEqual(Set(entries.map(\.id)).count, entries.count)
        XCTAssertNotNil(URL(string: try XCTUnwrap(wifi.launchURL)))
    }
    func testCuratedPanesAreUsedWhenNoExtensionsAreReadable() {
        let entries = CatalogueSettingsPanes.entries(in: "/nonexistent-\(UUID().uuidString)")
        let names = Set(entries.map(\.name))
        for pane in ["Wi-Fi", "Bluetooth", "Network", "Displays", "Sound", "Keyboard", "Trackpad", "Privacy & Security",
                     "Accessibility", "General", "Notifications", "Battery", "Desktop & Dock", "Appearance", "Login Items"] {
            XCTAssertTrue(names.contains(pane + " Settings"), pane)
        }
        XCTAssertTrue(entries.allSatisfy { $0.launchURL?.hasPrefix("x-apple.systempreferences:") == true })
    }
    func testOldCacheWithoutLaunchURLStillDecodes() throws {
        let json = #"[{"path":"/Applications/Safari.app","name":"Safari","bundleID":"com.apple.Safari"}]"#
        let entries = try JSONDecoder().decode([AppEntry].self, from: Data(json.utf8))
        XCTAssertNil(entries.first?.launchURL)
        XCTAssertEqual(entries.first?.id, "app:/Applications/Safari.app")
    }
    func testCancelledScanStopsAndReturnsNothing() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try makeApp(at: root.appendingPathComponent("Tool.app"), name: "Tool", id: "test.tool")
        let path = root.path
        let scan = Task.detached { () -> [AppEntry] in
            withUnsafeCurrentTask { $0?.cancel() }
            return AppCatalogue.scan(roots: [path])
        }
        let cancelled = await scan.value
        XCTAssertEqual(cancelled.count, 0)
        XCTAssertEqual(AppCatalogue.scan(roots: [path]).map(\.name), ["Tool"])
    }
    @MainActor func testDebouncerCollapsesBurstsIntoOneCall() async throws {
        let debouncer = CatalogueDebouncer(delay: .milliseconds(50))
        var calls = 0
        for _ in 0..<5 { debouncer.schedule { calls += 1 } }
        XCTAssertTrue(debouncer.isPending)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(calls, 1)
        XCTAssertFalse(debouncer.isPending)
        debouncer.schedule { calls += 1 }
        debouncer.cancel()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(calls, 1)
    }
}
