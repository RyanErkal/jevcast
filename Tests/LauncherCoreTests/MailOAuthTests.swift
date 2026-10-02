import XCTest
@testable import LauncherCore

final class MailOAuthTests: XCTestCase {
    private let redirect = URL(string: "http://127.0.0.1:54321/oauth/callback")!
    private let authorization = MailOAuthAuthorization(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk", state: "fixture-state")

    func testPKCEAndFixedGoogleAuthorizationParameters() throws {
        XCTAssertEqual(authorization.challenge, "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        let client = try MailOAuthClient(provider: .google, clientID: "fixture.apps.googleusercontent.com")
        let url = try authorization.url(client: client, redirect: redirect, email: "me@example.com")
        XCTAssertEqual(url.host, "accounts.google.com")
        let query = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(query["code_challenge_method"], "S256")
        XCTAssertEqual(query["state"], "fixture-state")
        XCTAssertEqual(query["redirect_uri"], redirect.absoluteString)
        XCTAssertEqual(query["scope"], "https://mail.google.com/")
        XCTAssertEqual(query["access_type"], "offline")
        XCTAssertNil(query["client_secret"])
    }

    func testCallbackNeedsExactStateHostPortPathAndUniqueParameters() throws {
        XCTAssertEqual(try authorization.code(from: URL(string: redirect.absoluteString + "?code=good&state=fixture-state")!, redirect: redirect), "good")
        for value in [
            redirect.absoluteString + "?code=x&state=wrong",
            redirect.absoluteString + "?code=x&state=fixture-state&code=y",
            "http://127.0.0.1:54322/oauth/callback?code=x&state=fixture-state",
            "http://example.com:54321/oauth/callback?code=x&state=fixture-state",
            "http://127.0.0.1:54321/other?code=x&state=fixture-state",
            "http://user@127.0.0.1:54321/oauth/callback?code=x&state=fixture-state",
            redirect.absoluteString + "?code=x&state=fixture-state#fragment"
        ] { XCTAssertThrowsError(try authorization.code(from: URL(string: value)!, redirect: redirect)) }
        XCTAssertThrowsError(try authorization.code(from: URL(string: redirect.absoluteString + "?error=access_denied&state=fixture-state")!, redirect: redirect)) {
            XCTAssertEqual($0 as? MailOAuthError, .cancelled)
        }
    }

    func testTokenExchangeAndRefreshUseFixedEndpointAndRetainRefreshToken() async throws {
        let client = try MailOAuthClient(provider: .google, clientID: "fixture.apps.googleusercontent.com")
        let http = MailOAuthHTTP { request in
            XCTAssertEqual(request.url, MailOAuthProvider.google.tokenURL)
            XCTAssertEqual(request.httpMethod, "POST")
            let form = String(decoding: request.httpBody!, as: UTF8.self)
            XCTAssertTrue(form.contains("client_id=fixture.apps.googleusercontent.com"))
            let payload: String
            if form.contains("grant_type=authorization_code") {
                XCTAssertTrue(form.contains("code_verifier=")); XCTAssertTrue(form.contains("redirect_uri="))
                payload = #"{"access_token":"fixture-access","refresh_token":"fixture-refresh","expires_in":3600,"token_type":"Bearer","scope":"https://mail.google.com/"}"#
            } else {
                XCTAssertTrue(form.contains("refresh_token=fixture-refresh"))
                payload = #"{"access_token":"fixture-fresh","expires_in":3600,"token_type":"Bearer"}"#
            }
            return (Data(payload.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let token = try await http.exchange(code: "fixture-code", authorization: authorization, redirect: redirect, client: client)
        let fresh = try await http.refresh(token, client: client)
        XCTAssertEqual(fresh.accessToken, "fixture-fresh")
        XCTAssertEqual(fresh.refreshToken, "fixture-refresh")
        XCTAssertFalse(fresh.needsRefresh)
    }

    func testTokenResponseCannotRedirectOrExposeProviderError() async throws {
        let client = try MailOAuthClient(provider: .google, clientID: "fixture.apps.googleusercontent.com")
        for status in [302, 400, 500] {
            let http = MailOAuthHTTP { request in
                (Data(#"{"error_description":"fixture secret must never be reported"}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
            }
            do { _ = try await http.exchange(code: "code", authorization: authorization, redirect: redirect, client: client); XCTFail() }
            catch { XCTAssertFalse(error.localizedDescription.contains("fixture secret")) }
        }
    }

    func testBadClientAndRedirectAreRefused() {
        XCTAssertThrowsError(try MailOAuthClient(provider: .google, clientID: "wrong-client"))
        XCTAssertThrowsError(try MailOAuthClient(provider: .microsoft, clientID: "not-a-uuid"))
        for value in ["https://127.0.0.1:54321/oauth/callback", "http://0.0.0.0:54321/oauth/callback", "http://localhost:80/oauth/callback"] {
            XCTAssertThrowsError(try MailOAuthAuthorization.validateRedirect(URL(string: value)!))
        }
    }
}
