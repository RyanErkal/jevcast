import XCTest
@testable import LauncherCore

final class DashboardTests: XCTestCase {
    private let json = #"{"totals":{"spend":1234.5,"orders":12,"rate":3.25,"label":"ok","flag":true,"none":null},"list":[{"x":1},{"x":2}],"a.b":5,"at":"2026-09-27T08:00:00Z"}"#

    private func root() throws -> Any { try DashboardReader.parse(Data(json.utf8)) }

    func testLookupFollowsKeysAndIndexes() throws {
        let r = try root()
        XCTAssertEqual(DashboardReader.lookup("totals.spend", in: r).flatMap(DashboardReader.leaf), .number(1234.5))
        XCTAssertEqual(DashboardReader.lookup("list.1.x", in: r).flatMap(DashboardReader.leaf), .number(2))
        XCTAssertNil(DashboardReader.lookup("list.5.x", in: r))
        XCTAssertNil(DashboardReader.lookup("totals..spend", in: r))
        XCTAssertNil(DashboardReader.lookup("", in: r))
        XCTAssertEqual(DashboardReader.lookup("totals.flag", in: r).flatMap(DashboardReader.leaf), .bool(true))
    }

    func testLeafPathsAreBoundedAndSkipDottedKeys() throws {
        let paths = DashboardReader.leafPaths(in: try root()).map(\.path)
        XCTAssertTrue(paths.contains("totals.orders"))
        XCTAssertTrue(paths.contains("list.0.x"))
        XCTAssertFalse(paths.contains("a.b"))
        XCTAssertFalse(paths.contains("totals.none"))
        let big = (0..<1000).reduce(into: [String: Any]()) { $0["k\($1)"] = $1 }
        XCTAssertEqual(DashboardReader.leafPaths(in: big, limit: 50).count, 50)
        let longList: [Any] = Array(repeating: ["v": 1], count: 100)
        XCTAssertEqual(DashboardReader.leafPaths(in: ["l": longList], maxArrayItems: 5).count, 5)
    }

    func testSnapshotReportsMissingPathsAndDate() throws {
        let config = DashboardConfig(id: "d", name: "D", filePath: "/x", metrics: [
            DashboardMetric(id: "1", label: "Spend", keyPath: "totals.spend", format: .currency),
            DashboardMetric(id: "2", label: "Gone", keyPath: "totals.gone", format: .number),
            DashboardMetric(id: "3", label: "Empty", keyPath: "totals.none", format: .number)
        ], updatedAtKeyPath: "at")
        let snap = DashboardReader.snapshot(try root(), config: config)
        XCTAssertEqual(snap.readings.map(\.value), [.number(1234.5), nil, nil])
        XCTAssertEqual(snap.problems, ["totals.gone is not in the file"])
        XCTAssertNotNil(snap.updatedAt)
    }

    func testFormats() {
        func f(_ v: DashboardValue?, _ format: DashboardFormat, _ symbol: String? = nil) -> String {
            DashboardText.value(v, metric: DashboardMetric(label: "x", keyPath: "x", format: format, currencySymbol: symbol))
        }
        XCTAssertEqual(f(.number(12), .number), "12")
        XCTAssertEqual(f(.number(1234.5), .currency, "€"), "€1,234") // rounds to whole units at 100 and above
        XCTAssertEqual(f(.number(-5.5), .currency), "-$5.50")
        XCTAssertEqual(f(.number(3.26), .percent), "3.3%")
        XCTAssertEqual(f(.number(3725), .duration), "1h 2m")
        XCTAssertEqual(f(.number(45), .duration), "45s")
        XCTAssertEqual(f(.text("ok"), .text), "ok")
        XCTAssertEqual(f(nil, .number), "Not set")
    }

    func testFreshness() {
        let now = Date()
        XCTAssertEqual(DashboardFreshness.of(now.addingTimeInterval(-60), now: now), .fresh)
        XCTAssertEqual(DashboardFreshness.of(now.addingTimeInterval(-8 * 3600), now: now), .aging)
        XCTAssertEqual(DashboardFreshness.of(now.addingTimeInterval(-30 * 3600), now: now), .stale)
        XCTAssertEqual(DashboardFreshness.of(nil, now: now), .unknown)
    }

    func testDatesFromTextDaysAndEpochs() {
        XCTAssertNotNil(DashboardReader.date("2026-09-27T08:00:00.123Z"))
        XCTAssertNotNil(DashboardReader.date("2026-09-27"))
        XCTAssertEqual(DashboardReader.date(NSNumber(value: 1_790_000_000_000))?.timeIntervalSince1970, 1_790_000_000)
        XCTAssertNil(DashboardReader.date("soon"))
    }

    func testLegacyMigrationMapsKnownProfiles() throws {
        let legacy = #"[{"id":"s","name":"S","profile":"stein","metricsPath":"/m.json"},{"id":"g","name":"G","profile":"generic","metricsPath":"/g.json"},{"bad":1}]"#
        let out = try XCTUnwrap(DashboardMigration.migrate(legacy: Data(legacy.utf8)))
        XCTAssertEqual(out.map(\.id), ["s", "g"])
        XCTAssertEqual(out[0].metrics.map(\.label), ["Spend", "Form qualified", "Cost per form qualified", "Meta form qualified"])
        XCTAssertEqual(out[0].metrics.first?.format, .currency)
        XCTAssertEqual(out[0].updatedAtKeyPath, "generatedAt")
        XCTAssertNil(out[0].note)
        XCTAssertTrue(out[1].metrics.isEmpty)
        XCTAssertEqual(out[1].note, DashboardMigration.unknownNote)
        XCTAssertNil(DashboardMigration.migrate(legacy: Data("{}".utf8)))
    }

    func testConfigRoundTrips() throws {
        let c = DashboardConfig(id: "d", name: "D", filePath: "/x", metrics: [DashboardMetric(id: "1", label: "L", keyPath: "a.b", format: .percent)],
                                updatedAtKeyPath: "at", automationID: "r", openPath: "/y.html")
        XCTAssertEqual(try JSONDecoder().decode(DashboardConfig.self, from: JSONEncoder().encode(c)), c)
    }
}
