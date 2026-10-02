import Foundation
import LauncherCore
import XCTest
@testable import JevLauncher

final class MailOAuthAppTests: XCTestCase {
    private actor Requests {
        private(set) var count = 0
        func add() { count += 1 }
    }

    func testConcurrentRefreshSharesOneRequestAndPersistsRotatedToken() async throws {
        let client = try MailOAuthClient(provider: .google, clientID: "fixture.apps.googleusercontent.com")
        let original = MailOAuthToken(accessToken: "old-access", refreshToken: "old-refresh", expiresAt: .distantPast, clientID: client.clientID)
        let encoded = String(decoding: try JSONEncoder().encode(original), as: UTF8.self)
        let requests = Requests(), saved = SavedTokens()
        let http = MailOAuthHTTP { request in
            await requests.add()
            try await Task.sleep(nanoseconds: 60_000_000)
            let bytes = Data(#"{"access_token":"new-access","refresh_token":"new-refresh","expires_in":3600,"token_type":"Bearer"}"#.utf8)
            return (bytes, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let credentials = MailOAuthCredentials(read: { _ in encoded }, persist: { token, id in saved.save(token, id) },
                                              client: { _ in client }, secret: { nil }, http: http)
        var account = NativeMailAccount.preset(.gmail, name: "Fixture", email: "me@example.com")!; account.authentication = .oauth
        let result = try await withThrowingTaskGroup(of: MailCredential.self) { group in
            for _ in 0..<6 { group.addTask { try await credentials.credential(for: account) } }
            var values: [MailCredential] = []
            for try await value in group { values.append(value) }
            return values
        }
        XCTAssertTrue(result.allSatisfy { $0 == .oauth2(accessToken: "new-access") })
        let count = await requests.count
        XCTAssertEqual(count, 1)
        XCTAssertEqual(saved.tokens.count, 1)
        XCTAssertEqual(saved.tokens[0].refreshToken, "new-refresh")
    }

    func testCallbackParserRejectsOtherHostDuplicateHostAndNonGet() throws {
        let redirect = URL(string: "http://127.0.0.1:54321/oauth/callback")!
        func parse(_ method: String = "GET", _ host: String = "127.0.0.1:54321", extra: String = "") -> URL? {
            MailOAuthCallbackServer.callback(request: Data("\(method) /oauth/callback?code=fixture&state=s HTTP/1.1\r\nHost: \(host)\r\n\(extra)\r\n".utf8), redirect: redirect)
        }
        XCTAssertNotNil(parse())
        XCTAssertNil(parse("POST"))
        XCTAssertNil(parse("GET", "example.com:54321"))
        XCTAssertNil(parse(extra: "Host: 127.0.0.1:54321\r\n"))
    }

    func testCancelledRefreshCannotRemoveItsReplacementOrPersistOldToken() async throws {
        let client = try MailOAuthClient(provider: .google, clientID: "fixture.apps.googleusercontent.com")
        let original = MailOAuthToken(accessToken: "old-access", refreshToken: "old-refresh", expiresAt: .distantPast, clientID: client.clientID)
        let encoded = String(decoding: try JSONEncoder().encode(original), as: UTF8.self)
        let requests = RefreshGate(), saved = SavedTokens()
        let http = MailOAuthHTTP { request in
            await requests.enter()
            let bytes = Data(#"{"access_token":"new-access","refresh_token":"new-refresh","expires_in":3600,"token_type":"Bearer"}"#.utf8)
            return (bytes, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let credentials = MailOAuthCredentials(read: { _ in encoded }, persist: { token, id in saved.save(token, id) },
                                              client: { _ in client }, secret: { nil }, http: http)
        var account = NativeMailAccount.preset(.gmail, name: "Fixture", email: "me@example.com")!; account.authentication = .oauth
        let old = Task { try await credentials.credential(for: account) }
        try await requests.waitFor(1)
        await credentials.cancelRefresh(account.id)
        let replacement = Task { try await credentials.credential(for: account) }
        try await requests.waitFor(2)
        await requests.release(1)
        do { _ = try await old.value; XCTFail("The cancelled refresh must not supply a token") }
        catch is CancellationError {}
        XCTAssertTrue(saved.tokens.isEmpty)
        let joined = Task { try await credentials.credential(for: account) }
        try await Task.sleep(nanoseconds: 60_000_000)
        let count = await requests.count
        XCTAssertEqual(count, 2, "A later connection must join the replacement refresh")
        await requests.releaseAll()
        let fresh = try await replacement.value, alsoFresh = try await joined.value
        XCTAssertEqual(fresh, .oauth2(accessToken: "new-access"))
        XCTAssertEqual(alsoFresh, fresh)
        XCTAssertEqual(saved.tokens.count, 1)
    }

    func testOfflineGateBlocksRealMailIOBeforeAnyAppleEvent() async throws {
        try XCTSkipUnless(MailIOPolicy.isOffline, "Run with JEVCAST_MAIL_OFFLINE=1")
        do { _ = try await AppleScript.run(MailScripts.send, app: "com.apple.mail", name: "Mail"); XCTFail() }
        catch { XCTAssertTrue(error.localizedDescription.contains("offline")) }
        let imap = IMAPClient(settings: .init(server: .init(host: "imap.example.com", port: 993, security: .tls), username: "fixture"), credential: { .password("fixture") })
        do { try await imap.verify(); XCTFail() } catch { XCTAssertTrue(error.localizedDescription.contains("disabled")) }
        XCTAssertNil(MailDraftStore.standard)
        XCTAssertEqual(MailStore.status(), .noMail)
    }
}

private actor RefreshGate {
    private(set) var count = 0
    private var waiting: [Int: CheckedContinuation<Void, Never>] = [:]
    func enter() async {
        count += 1
        let index = count
        await withCheckedContinuation { waiting[index] = $0 }
    }
    func release(_ index: Int) { waiting.removeValue(forKey: index)?.resume() }
    func releaseAll() { let values = waiting.values; waiting = [:]; values.forEach { $0.resume() } }
    func waitFor(_ expected: Int) async throws {
        let deadline = Date().addingTimeInterval(5)
        while count < expected && Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertGreaterThanOrEqual(count, expected)
    }
}

private final class SavedTokens: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [MailOAuthToken] = []
    func save(_ token: MailOAuthToken, _ id: String) { lock.withLock { values.append(token) } }
    var tokens: [MailOAuthToken] { lock.withLock { values } }
}
