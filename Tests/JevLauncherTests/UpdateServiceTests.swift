import XCTest
@testable import JevLauncher

final class UpdateServiceTests: XCTestCase {
    private var endpoints: [URL] = []
    override func tearDown() {
        endpoints.forEach(MockURLProtocol.removeHandler)
        super.tearDown()
    }

    func testVersionComparison() {
        XCTAssertTrue(UpdateService.isNewer("1.0.1", than: "1.0.0"))
        XCTAssertTrue(UpdateService.isNewer("1.10.0", than: "1.9.2"), "Parts compare as numbers, not text.")
        XCTAssertTrue(UpdateService.isNewer("2", than: "1.99.99"))
        XCTAssertFalse(UpdateService.isNewer("1.0", than: "1.0.0"))
        XCTAssertFalse(UpdateService.isNewer("1.0.0", than: "1.0.0"))
        XCTAssertFalse(UpdateService.isNewer("0.9.9", than: "1.0.0"))
        XCTAssertFalse(UpdateService.isNewer("1.1.0-beta.2", than: "1.1.0"), "A suffix is ignored.")
    }

    func testParsesTagAndPage() throws {
        let release = try UpdateService.parse(Self.release(tag: "v1.2.0"))
        XCTAssertEqual(release, AppRelease(version: "1.2.0", page: URL(string: "https://github.com/o/r/releases/tag/v1.2.0")!))
        XCTAssertThrowsError(try UpdateService.parse(Data("{}".utf8)))
        XCTAssertThrowsError(try UpdateService.parse(Self.release(tag: "nightly")), "A tag without a version is not a release.")
    }

    func testFindsNewerReleaseWithAPlainRequest() async throws {
        let service = makeService { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "Jevcast/1.0.0")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertNil(request.httpBody)
            XCTAssertNil(request.url?.query, "Nothing about the user rides in the URL.")
            return (Self.http(200), Self.release(tag: "v1.1.0"))
        }
        let release = try await service.newerRelease(than: "1.0.0")
        XCTAssertEqual(release?.version, "1.1.0")
    }

    func testSameVersionAndNoPublishedReleaseAreNotUpdates() async throws {
        let same = makeService { _ in (Self.http(200), Self.release(tag: "v1.0.0")) }
        let none = makeService { _ in (Self.http(404), Data()) }
        let sameResult = try await same.newerRelease(than: "1.0.0")
        let noneResult = try await none.newerRelease(than: "1.0.0")
        XCTAssertNil(sameResult)
        XCTAssertNil(noneResult)
    }

    func testServerErrorThrows() async {
        let service = makeService { _ in (Self.http(503), Data()) }
        do {
            _ = try await service.newerRelease(than: "1.0.0")
            XCTFail("Expected an error")
        } catch {
            XCTAssertEqual(error as? UpdateServiceError, .requestFailed(statusCode: 503))
        }
    }

    @MainActor func testAutomaticCheckRunsOnceADayAndOnlyWhenOn() async {
        let suite = "JevLauncherTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults)
        let requests = RequestCount()
        let service = makeService { _ in requests.add(); return (Self.http(200), Self.release(tag: "v2.0.0")) }
        let checker = UpdateChecker(preferences: preferences, service: service, currentVersion: "1.0.0")

        preferences.checksForUpdates = false
        await checker.checkIfDue()
        XCTAssertEqual(requests.value, 0, "The switch is off.")

        preferences.checksForUpdates = true
        await checker.checkIfDue()
        XCTAssertEqual(requests.value, 1)
        XCTAssertEqual(checker.available?.version, "2.0.0")

        await checker.checkIfDue(now: Date().addingTimeInterval(60 * 60))
        XCTAssertEqual(requests.value, 1, "Checked less than a day ago.")
        await checker.checkIfDue(now: Date().addingTimeInterval(UpdateChecker.interval + 60))
        XCTAssertEqual(requests.value, 2)
    }

    private func makeService(handler: @escaping MockURLProtocol.Handler) -> UpdateService {
        let endpoint = URL(string: "https://mock.local/\(UUID().uuidString)/releases/latest")!
        MockURLProtocol.setHandler(handler, for: endpoint)
        endpoints.append(endpoint)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return UpdateService(session: URLSession(configuration: configuration), endpoint: endpoint)
    }

    private static func release(tag: String) -> Data {
        Data(#"{"tag_name": "\#(tag)", "html_url": "https://github.com/o/r/releases/tag/\#(tag)", "draft": false, "prerelease": false}"#.utf8)
    }

    private static func http(_ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://mock.local/")!, statusCode: status, httpVersion: nil, headerFields: nil)!
    }
}

private final class RequestCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func add() { lock.withLock { count += 1 } }
}
