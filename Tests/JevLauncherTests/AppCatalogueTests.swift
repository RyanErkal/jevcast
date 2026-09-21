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
}
