import XCTest
@testable import LauncherCore

final class ClientMetricsTests: XCTestCase {
    private func fixture(version: Int, kpis: String, sources: String? = nil) -> Data {
        let src = sources ?? """
        [{"source":"meta","last_attempt_at":"2026-09-26T01:00:00.000Z","last_success_at":"2026-09-26T01:00:00.000Z",
          "last_status":"success","last_error":null,"row_count":3,"closed_day_through":"2026-09-25"}]
        """
        return Data("""
        {"schemaVersion":\(version),"generatedAt":"2026-09-26T01:00:01.000Z","reportingTimezone":"America/Los_Angeles",
         "campaign":{"accountId":"a"},"reportRange":{"from":"2026-08-01","to":"2026-09-25"},
         "sourceFreshness":\(src),"metaDaily":[],"derivedKpis":\(kpis)}
        """.utf8)
    }

    func testSteinContract() throws {
        let s = try ClientMetricsReader.decode(fixture(version: 4, kpis: #"{"spend":10.5,"formQualified":3,"costPerFormQualified":3.5,"metaFormQualified":1}"#), profile: .stein)
        XCTAssertEqual(s.problems, [])
        XCTAssertEqual(s.kpis.map(\.id), ["spend", "formQualified", "costPerFormQualified", "metaFormQualified"])
        XCTAssertFalse(s.kpis.contains { $0.label.lowercased().contains("lead") })
        XCTAssertEqual(s.rangeStart, "2026-08-01")
        XCTAssertEqual(s.reportingTimeZone, "America/Los_Angeles")
        XCTAssertEqual(s.sources.first?.closedDayThrough, "2026-09-25")
    }

    func testRobertOmitsMoney() throws {
        let s = try ClientMetricsReader.decode(fixture(version: 5, kpis: #"{"spend":99,"paidSignupCount":2,"costPerPaidSignup":49.5,"homesClicked":0}"#), profile: .robertParish)
        XCTAssertEqual(s.problems, [])
        XCTAssertEqual(s.kpis.map(\.id), ["paidSignupCount", "homesClicked"])
        XCTAssertFalse(s.kpis.contains { $0.format == .currency })
    }

    func testRedesignNullIsNotZero() throws {
        let s = try ClientMetricsReader.decode(fixture(version: 4, kpis: #"{"spend":1,"paidTaggedForms":2,"costPerForm":0.5,"qualifiedMeetings":null}"#), profile: .redesign)
        XCTAssertEqual(s.problems, [])
        XCTAssertNil(s.kpis.last?.value)
    }

    func testProblems() throws {
        let unsupported = try ClientMetricsReader.decode(fixture(version: 9, kpis: "{}"), profile: .stein)
        XCTAssertEqual(unsupported.problems, ["Unsupported schema version 9"])
        XCTAssertTrue(unsupported.kpis.isEmpty)
        let bad = try ClientMetricsReader.decode(fixture(version: 4, kpis: #"{"spend":true,"formQualified":"3","costPerFormQualified":null}"#), profile: .stein)
        XCTAssertEqual(bad.problems.count, 4)
        XCTAssertThrowsError(try ClientMetricsReader.decode(Data("[]".utf8), profile: .stein))
    }

    func testFreshness() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        func f(_ age: TimeInterval?, status: String = "success", error: String? = nil) -> MetricsFreshness {
            ClientMetricsSnapshot.SourceStatus(name: "m", lastSuccess: age.map { now.addingTimeInterval(-$0) }, status: status, error: error).freshness(now: now)
        }
        XCTAssertEqual(f(3600), .fresh)
        XCTAssertEqual(f(7 * 3600), .aging)
        XCTAssertEqual(f(25 * 3600), .stale)
        XCTAssertEqual(f(nil), .unknown)
        XCTAssertEqual(f(-60), .unknown)
        XCTAssertEqual(f(60, status: "error"), .failed)
        XCTAssertEqual(f(60, error: "boom"), .failed)
    }

    func testReadBoundsSize() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("metrics-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(count: ClientMetricsReader.maxBytes + 1).write(to: url)
        XCTAssertThrowsError(try ClientMetricsReader.read(url: url, profile: .stein)) { XCTAssertEqual($0 as? ClientMetricsError, .tooLarge) }
    }

    /// Decodes the real sidecars when present. Prints nothing from them.
    func testRealFiles() throws {
        let docs = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Dev/docs")
        let files: [(String, ClientMetricsProfile)] = [
            ("4-delivery/clients/robert-parish/meta-ads/robert-parish-dashboard.metrics.json", .robertParish),
            ("4-delivery/clients/shantyl-stevens/meta-ads/stein-firm-dashboard.metrics.json", .stein),
            ("2-marketing/paid-ads/meta-ads/redesign-pi-firm-ads/2026-08-01-redesign-meta-ads-dashboard.metrics.json", .redesign),
        ]
        var found = 0
        for (path, profile) in files {
            let url = docs.appendingPathComponent(path)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            found += 1
            let s = try ClientMetricsReader.read(url: url, profile: profile)
            XCTAssertEqual(s.problems, [], profile.rawValue)
            XCTAssertFalse(s.sources.isEmpty, profile.rawValue)
        }
        try XCTSkipIf(found == 0, "No real metrics files")
    }
}
