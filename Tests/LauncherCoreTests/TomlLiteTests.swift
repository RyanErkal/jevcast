import XCTest
@testable import LauncherCore

final class TomlLiteTests: XCTestCase {
    func testValuesAndEscapes() throws {
        let t = try TomlLite.parse("""
        # comment
        version = 1
        a = "x\\ny\\t\\"q\\" \\\\ \\u00e9" # trailing
        b = 'C:\\raw'
        c = true
        d = -42
        e = 1_000
        """)
        XCTAssertEqual(t["version"], .integer(1))
        XCTAssertEqual(t["a"], .string("x\ny\t\"q\" \\ é"))
        XCTAssertEqual(t["b"], .string("C:\\raw"))
        XCTAssertEqual(t["c"], .bool(true))
        XCTAssertEqual(t["d"], .integer(-42))
        XCTAssertEqual(t["e"], .integer(1000))
    }

    func testMultilineBasic() throws {
        let t = try TomlLite.parse("p = \"\"\"\nline one\nline \\\n    two \\\"x\\\"\"\"\"\n")
        XCTAssertEqual(t["p"], .string("line one\nline two \"x\""))
    }

    func testRejectsUnsupportedAndDuplicates() {
        for text in ["a = 1\na = 2", "[table]\na = 1", "a = [1, 2]", "a = { b = 1 }", "a = 1.5", "a = \"open",
                     "a = 1 junk", "a.b = 1", "a = \"\\q\"", "a = 01"] {
            XCTAssertThrowsError(try TomlLite.parse(text), text)
        }
    }
}
