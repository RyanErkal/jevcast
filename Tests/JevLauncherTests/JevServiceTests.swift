import Foundation
import Security
import XCTest
@testable import JevLauncher

final class JevServiceTests: XCTestCase {
    private var endpoints: [URL] = []
    override func tearDown() {
        endpoints.forEach(MockURLProtocol.removeHandler)
        super.tearDown()
    }

    func testSelectsKnownCandidateAndSendsTypedBoundedRequest() async throws {
        let (service, session) = makeService { request in
            let body = try requestBodyData(from: request)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(object["model"] as? String, "jev-1.13.0")
            XCTAssertEqual((object["state"] as? [String: Any])?["query"] as? String, "open notes")

            let questions = try XCTUnwrap(object["questions"] as? [String: Any])
            let selection = try XCTUnwrap(questions["selection"] as? [String: Any])
            XCTAssertEqual(selection["type"] as? String, "choice")
            let criteria = try XCTUnwrap(selection["criteria"] as? [String: String])
            XCTAssertEqual(Set(criteria.keys), Set(["app.notes", "no_match"]))
            XCTAssertTrue(criteria["app.notes"]?.contains("Notes") == true)

            return jsonResponse(choice: "app.notes", probabilities: ["app.notes": 0.86, "no_match": 0.14], confidence: 0.82)
        }
        defer { session.invalidateAndCancel() }

        let chosen = try await service.choose(
            query: "open notes",
            candidates: [JevCandidate(id: "app.notes", title: "Notes", detail: "Open Apple Notes")],
            apiKey: "test-key"
        )

        XCTAssertEqual(chosen, "app.notes")
    }

    func testNoMatchReturnsNil() async throws {
        let (service, session) = makeService { _ in
            jsonResponse(choice: "no_match", probabilities: ["app.notes": 0.08, "no_match": 0.92], confidence: 0.90)
        }
        defer { session.invalidateAndCancel() }

        let chosen = try await service.choose(
            query: "something unrelated",
            candidates: [JevCandidate(id: "app.notes", title: "Notes", detail: "Open Apple Notes")],
            apiKey: "test-key"
        )

        XCTAssertNil(chosen)
    }

    func testUnknownChoiceIDIsRejected() async throws {
        let (service, session) = makeService { _ in
            jsonResponse(choice: "app.calendar", probabilities: ["app.notes": 0.80, "no_match": 0.20], confidence: 0.80)
        }
        defer { session.invalidateAndCancel() }

        do {
            _ = try await service.choose(
                query: "open notes",
                candidates: [JevCandidate(id: "app.notes", title: "Notes", detail: "Open Apple Notes")],
                apiKey: "test-key"
            )
            XCTFail("An ID outside the supplied candidates must be rejected.")
        } catch let error as JevServiceError {
            guard case .invalidResponse = error else {
                return XCTFail("Unexpected JevServiceError: \(error)")
            }
        }
    }

    func testInvalidProbabilityDistributionIsRejected() async throws {
        let (service, session) = makeService { _ in
            jsonResponse(choice: "app.notes", probabilities: ["app.notes": 0.60, "no_match": 0.10], confidence: 0.80)
        }
        defer { session.invalidateAndCancel() }

        do {
            _ = try await service.choose(
                query: "open notes",
                candidates: [JevCandidate(id: "app.notes", title: "Notes", detail: "Open Apple Notes")],
                apiKey: "test-key"
            )
            XCTFail("A distribution that does not sum to one must be rejected.")
        } catch let error as JevServiceError {
            guard case .invalidResponse = error else {
                return XCTFail("Unexpected JevServiceError: \(error)")
            }
        }
    }

    func testUnexpectedModelIsRejected() async throws {
        let (service, session) = makeService { _ in
            jsonResponse(model: "jev-latest", choice: "app.notes", probabilities: ["app.notes": 0.86, "no_match": 0.14], confidence: 0.82)
        }
        defer { session.invalidateAndCancel() }

        do {
            _ = try await service.choose(
                query: "open notes",
                candidates: [JevCandidate(id: "app.notes", title: "Notes", detail: "Open Apple Notes")],
                apiKey: "test-key"
            )
            XCTFail("An unexpected model must be rejected.")
        } catch let error as JevServiceError {
            guard case .invalidResponse = error else {
                return XCTFail("Unexpected JevServiceError: \(error)")
            }
        }
    }

    func testHTTPErrorReturnsStatusWithoutEchoingResponseBody() async throws {
        let (service, session) = makeService { _ in
            httpResponse(statusCode: 503, body: Data("secret response body".utf8))
        }
        defer { session.invalidateAndCancel() }

        do {
            _ = try await service.choose(
                query: "open notes",
                candidates: [JevCandidate(id: "app.notes", title: "Notes", detail: "Open Apple Notes")],
                apiKey: "test-key"
            )
            XCTFail("The HTTP failure must throw.")
        } catch let error as JevServiceError {
            guard case let .requestFailed(statusCode) = error else {
                return XCTFail("Unexpected JevServiceError: \(error)")
            }
            XCTAssertEqual(statusCode, 503)
        }
    }

    func testCancellationIsPropagatedBeforeRequest() async throws {
        let (service, session) = makeService { _ in
            XCTFail("A cancelled request must not reach the URL protocol.")
            return jsonResponse(choice: "no_match", probabilities: ["no_match": 1], confidence: 1)
        }
        defer { session.invalidateAndCancel() }

        let task = Task {
            try await service.choose(query: "open notes", candidates: [], apiKey: "test-key")
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Cancellation must throw.")
        } catch is CancellationError {
            // Expected.
        }
    }

    func testStatusMessagesMapFailures() {
        XCTAssertEqual(JevService.statusMessage(for: JevServiceError.requestFailed(statusCode: 401)), "Jev key rejected")
        XCTAssertEqual(JevService.statusMessage(for: JevServiceError.requestFailed(statusCode: 403)), "Jev key rejected")
        XCTAssertEqual(JevService.statusMessage(for: JevServiceError.requestFailed(statusCode: 429)), "Jev rate limited")
        XCTAssertEqual(JevService.statusMessage(for: JevServiceError.requestFailed(statusCode: 500)), "Jev unavailable · local results ready")
        XCTAssertEqual(JevService.statusMessage(for: URLError(.timedOut)), "Jev offline · local results ready")
        XCTAssertEqual(JevService.statusMessage(for: URLError(.notConnectedToInternet)), "Jev offline · local results ready")
        XCTAssertEqual(JevService.statusMessage(for: JevServiceError.invalidResponse("x")), "Jev unavailable · local results ready")
        XCTAssertEqual(JevService.statusMessage(for: KeychainStoreError.unreadable(errSecInteractionNotAllowed)), "Re-enter your Jev key in Settings")
    }

    func testValidateSurfacesRejectedKey() async throws {
        let (service, session) = makeService { _ in httpResponse(statusCode: 401, body: Data()) }
        defer { session.invalidateAndCancel() }
        do {
            try await service.validate(apiKey: "bad-key")
            XCTFail("A rejected key must throw.")
        } catch {
            XCTAssertEqual(JevService.statusMessage(for: error), "Jev key rejected")
        }
    }

    func testValidateAcceptsWorkingKey() async throws {
        let (service, session) = makeService { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer good-key")
            return jsonResponse(choice: "no_match", probabilities: ["test": 0.1, "no_match": 0.9], confidence: 0.9)
        }
        defer { session.invalidateAndCancel() }
        try await service.validate(apiKey: "good-key")
    }

    func testKeychainStatusMapping() throws {
        XCTAssertNil(try KeychainStore.value(status: errSecItemNotFound, result: nil))
        XCTAssertEqual(try KeychainStore.value(status: errSecSuccess, result: Data("abc".utf8) as CFData), "abc")
        XCTAssertThrowsError(try KeychainStore.value(status: errSecSuccess, result: Data([0xFF, 0xFE]) as CFData)) {
            XCTAssertEqual($0 as? KeychainStoreError, .invalidStoredValue)
        }
        for status in [errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled] {
            XCTAssertThrowsError(try KeychainStore.value(status: status, result: nil)) {
                XCTAssertEqual($0 as? KeychainStoreError, .unreadable(status))
                XCTAssertEqual($0.localizedDescription, "Re-enter your Jev key in Settings")
            }
        }
        XCTAssertThrowsError(try KeychainStore.value(status: errSecParam, result: nil)) {
            XCTAssertEqual($0 as? KeychainStoreError, .unexpectedStatus(errSecParam))
        }
    }

    @MainActor func testKeyCacheReadsOnceAndFollowsSaveState() async {
        let reads = Counter()
        let cache = JevKeyCache(reader: { reads.increment(); return "stored" })
        async let first = cache.load()
        async let second = cache.load()
        let states = await [first, second]
        XCTAssertEqual(states, [.present("stored"), .present("stored")])
        _ = await cache.load()
        XCTAssertEqual(reads.value, 1)
        let failing = JevKeyCache(reader: { throw KeychainStoreError.unreadable(errSecInteractionNotAllowed) })
        let failed = await failing.load()
        XCTAssertEqual(failed, .failed("Re-enter your Jev key in Settings"))
    }

    /// Each service gets its own endpoint URL so parallel tests never share a handler.
    private func makeService(
        handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> (JevService, URLSession) {
        let endpoint = URL(string: "https://mock.local/\(UUID().uuidString)/v1/systemone")!
        MockURLProtocol.setHandler(handler, for: endpoint)
        endpoints.append(endpoint)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        return (JevService(session: session, endpoint: endpoint), session)
    }
}

private enum RequestBodyError: Error {
    case missing
    case readFailed
}

private func requestBodyData(from request: URLRequest) throws -> Data {
    if let body = request.httpBody {
        return body
    }
    guard let stream = request.httpBodyStream else {
        throw RequestBodyError.missing
    }

    stream.open()
    defer { stream.close() }

    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4_096)
    while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count < 0 {
            throw stream.streamError ?? RequestBodyError.readFailed
        }
        if count == 0 { break }
        data.append(buffer, count: count)
    }
    return data
}

private func jsonResponse(
    model: String = "jev-1.13.0",
    choice: String,
    probabilities: [String: Double],
    confidence: Double,
    type: String = "choice"
) -> (HTTPURLResponse, Data) {
    let object: [String: Any] = [
        "model": model,
        "answers": [
            "selection": [
                "type": type,
                "choice": choice,
                "probabilities": probabilities,
                "confidence": confidence
            ]
        ],
        "usage": ["input_tokens": 1, "output_tokens": 1]
    ]
    let data = try! JSONSerialization.data(withJSONObject: object)
    return httpResponse(statusCode: 200, body: data)
}

private func httpResponse(statusCode: Int, body: Data) -> (HTTPURLResponse, Data) {
    let response = HTTPURLResponse(
        url: URL(string: "https://mock.local/v1/systemone")!,
        statusCode: statusCode,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
    )!
    return (response, body)
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

private final class MockURLProtocol: URLProtocol {
    typealias Handler = (URLRequest) throws -> (HTTPURLResponse, Data)
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers: [URL: Handler] = [:]

    static func setHandler(_ handler: @escaping Handler, for url: URL) { lock.withLock { handlers[url] = handler } }
    static func removeHandler(for url: URL) { _ = lock.withLock { handlers.removeValue(forKey: url) } }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let handler = request.url.flatMap { url in Self.lock.withLock { Self.handlers[url] } }
        guard let requestHandler = handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }

        do {
            let (response, data) = try requestHandler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
