import XCTest
@testable import JevLauncher

final class LibraryFileTests: XCTestCase {
    @MainActor func testImportAddsOnlyNewItemsAndKeepsExistingOnes() throws {
        let suite = "LibraryFileTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults)
        let kept = CustomCommand(id: "a", name: "Mine", command: "echo mine")
        preferences.customCommands = [kept]
        preferences.aliases = ["ff": "firefox"]

        var file = LibraryFile(commands: [CustomCommand(id: "a", name: "Theirs", command: "echo theirs"),
                                          CustomCommand(id: "b", name: "New", command: "echo new")],
                               snippets: [Snippet(name: "Hi", text: "Hello")],
                               aliases: ["ff": "other", "sf": "safari"])
        file = try LibraryFile.decode(file.encoded())

        XCTAssertEqual(file.merge(into: preferences), 3)
        XCTAssertEqual(preferences.customCommands.map(\.name), ["Mine", "New"], "An item with the same ID is not replaced.")
        XCTAssertEqual(preferences.aliases, ["ff": "firefox", "sf": "safari"])
        XCTAssertEqual(file.merge(into: preferences), 0, "A second import adds nothing.")
    }

    @MainActor func testImportSkipsDuplicatesInsideTheFileAndInvalidKeywords() throws {
        let suite = "LibraryFileTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults)
        preferences.quicklinks = []
        let file = LibraryFile(commands: [CustomCommand(id: "x", name: "Deploy", command: "echo 1"),
                                          CustomCommand(id: "y", name: "deploy", command: "echo 2")],
                               keywords: [Quicklink(keyword: "GH", name: "GitHub", template: "https://github.com/search?q={query}"),
                                          Quicklink(keyword: "gh", name: "Other", template: "https://example.com/?q={query}"),
                                          Quicklink(keyword: "two words", name: "Bad", template: "https://example.com/?q={query}"),
                                          Quicklink(keyword: "noq", name: "Bad", template: "https://example.com/")])
        let (additions, skipped) = file.additions(to: preferences)
        XCTAssertEqual(additions.commands.map(\.id), ["x"])
        XCTAssertEqual(additions.keywords.map(\.keyword), ["GH"])
        XCTAssertEqual(skipped, 4)
    }

    func testRejectsUnknownVersion() {
        XCTAssertThrowsError(try LibraryFile.decode(Data(#"{"version":2,"commands":[],"workflows":[],"snippets":[],"keywords":[],"aliases":{}}"#.utf8)))
    }
}
