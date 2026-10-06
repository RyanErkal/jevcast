import LauncherCore
import SwiftUI
import XCTest
@testable import JevLauncher

final class GoogleCalendarAccountTests: XCTestCase {
    @MainActor func testDisconnectDuringSignInCannotReconnect() async throws {
        let suite = "CalendarTests." + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "calendarGoogleConnected")
        let started = expectation(description: "Sign-in pending")
        let token = MailOAuthToken(accessToken: "fixture", refreshToken: "fixture", expiresAt: .distantFuture, clientID: "fixture.apps.googleusercontent.com")
        let api = GoogleCalendarAPI { _ in XCTFail("Disconnected sign-in cannot fetch or persist data."); throw GoogleCalendarError.invalidResponse }
        let account = GoogleCalendarAccount(defaults: defaults, api: api, readToken: { nil }, saveToken: { _ in XCTFail() }, deleteToken: {}, readSecret: { nil }, writeSecret: { _ in XCTFail() }, authenticate: { _, _ in
            started.fulfill(); try await Task.sleep(nanoseconds: 60_000_000); return token
        })
        let signIn = Task { try await account.signIn(clientID: token.clientID, secret: "fixture") }
        await fulfillment(of: [started], timeout: 2)
        try account.disconnect()
        do { try await signIn.value; XCTFail() } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(account.connected); XCTAssertFalse(defaults.bool(forKey: "calendarGoogleConnected"))
    }

    @MainActor func testSignInHandoffClosesLauncherBeforeOpeningIndependentWindow() {
        let suite = "CalendarTests." + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let account = GoogleCalendarAccount(defaults: defaults, readToken: { nil }, saveToken: { _ in }, deleteToken: {}, readSecret: { nil })
        let preferences = Preferences(defaults: defaults); preferences.voiceEnabled = false; preferences.jevEnabled = false
        let model = LauncherModel(preferences: preferences, catalogue: AppCatalogue(loadCache: false), keys: JevKeyCache(key: nil), clipboard: ClipboardHistory(pasteboard: CalendarTestPasteboard()))
        let list = SourcePage(.calendar, source: nil, model: model, hasDetail: true, emptyText: "")
        var sequence: [String] = []
        let page = CalendarPage(list: list, readsEvents: false, google: account, defaults: defaults, hideLauncher: { sequence.append("hide") }, openSignIn: { shown in
            XCTAssertTrue(shown === account); sequence.append("show")
        })
        page.signIn()
        XCTAssertEqual(sequence, ["hide", "show"])
    }

    @MainActor func testSignInCompletesAfterLauncherPageClosesAndSelectsGoogle() async throws {
        let suite = "CalendarTests." + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let started = expectation(description: "Browser sign-in starts")
        let token = MailOAuthToken(accessToken: "fixture", refreshToken: "fixture", expiresAt: .distantFuture, clientID: "fixture.apps.googleusercontent.com")
        var saved: MailOAuthToken?, secretWritten: String?
        let api = GoogleCalendarAPI { request in
            (Data(#"{"items":[{"id":"work","summary":"Work","selected":true}]}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let account = GoogleCalendarAccount(defaults: defaults, api: api, readToken: { nil }, saveToken: { saved = $0 }, deleteToken: {}, readSecret: { nil }, writeSecret: { secretWritten = $0 }, authenticate: { client, secret in
            XCTAssertEqual(client.provider, .google); XCTAssertEqual(secret, "fixture-secret")
            started.fulfill(); try await Task.sleep(nanoseconds: 60_000_000); return token
        })
        let preferences = Preferences(defaults: defaults); preferences.voiceEnabled = false; preferences.jevEnabled = false
        let model = LauncherModel(preferences: preferences, catalogue: AppCatalogue(loadCache: false), keys: JevKeyCache(key: nil), clipboard: ClipboardHistory(pasteboard: CalendarTestPasteboard()))
        let list = SourcePage(.calendar, source: nil, model: model, hasDetail: true, emptyText: "")
        let page = CalendarPage(list: list, readsEvents: false, google: account, defaults: defaults)
        page.opened()
        let signIn = Task { try await account.signIn(clientID: token.clientID, secret: "fixture-secret") }
        await fulfillment(of: [started], timeout: 2)
        page.closed(handingOff: false)
        try await signIn.value
        XCTAssertTrue(account.connected); XCTAssertEqual(saved, token); XCTAssertEqual(secretWritten, "fixture-secret")
        XCTAssertEqual(defaults.string(forKey: "calendarSource"), CalendarPage.Source.google.rawValue)
        XCTAssertEqual(account.enabledIDs, ["work"])
        let reopened = CalendarPage(list: list, readsEvents: false, google: account, defaults: defaults)
        XCTAssertEqual(reopened.source, .google)
    }

    @MainActor func testDeniedCalendarAccessPreservesExistingConnection() async throws {
        let suite = "CalendarTests." + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "calendarGoogleConnected"); defaults.set("existing.apps.googleusercontent.com", forKey: GoogleCalendarAccount.clientKey)
        let token = MailOAuthToken(accessToken: "fixture", refreshToken: "fixture", expiresAt: .distantFuture, clientID: "new.apps.googleusercontent.com")
        let api = GoogleCalendarAPI { request in
            (Data(#"{"error":"private provider details"}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!)
        }
        let account = GoogleCalendarAccount(defaults: defaults, api: api, readToken: { nil }, saveToken: { _ in XCTFail("Do not replace the token after refusal.") }, deleteToken: {}, readSecret: { nil }, writeSecret: { _ in XCTFail("Do not replace the secret after refusal.") }, authenticate: { _, _ in token })
        do { try await account.signIn(clientID: token.clientID, secret: "fixture"); XCTFail() } catch { XCTAssertEqual(error as? GoogleCalendarError, .permissionDenied) }
        XCTAssertTrue(account.connected); XCTAssertEqual(account.clientID, "existing.apps.googleusercontent.com")
    }

    func testOfflineGateBlocksCalendarBeforeNetworkOrBrowserAccess() throws {
        guard ProcessInfo.processInfo.environment["JEVCAST_CALENDAR_OFFLINE"] == "1" || ProcessInfo.processInfo.environment["JEVCAST_MAIL_OFFLINE"] == "1" else {
            throw XCTSkip("Run with JEVCAST_CALENDAR_OFFLINE=1")
        }
        XCTAssertThrowsError(try GoogleCalendarAPI.requireOnline()) { XCTAssertEqual($0 as? GoogleCalendarError, .offline) }
    }

    @MainActor func testOptInSelectionAndDisconnectUseSeparateCalendarCredentials() async throws {
        let suite = "CalendarTests." + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "calendarGoogleConnected")
        defaults.set("fixture.apps.googleusercontent.com", forKey: GoogleCalendarAccount.clientKey)
        let token = MailOAuthToken(accessToken: "fixture", refreshToken: "fixture", expiresAt: Date().addingTimeInterval(3600), clientID: "fixture.apps.googleusercontent.com")
        var deleted = false, reads = 0
        let api = GoogleCalendarAPI { request in
            let list = request.url!.path.hasSuffix("calendarList")
            let json = list ? #"{"items":[{"id":"work","summary":"Work","selected":true},{"id":"home","summary":"Home","selected":false}]}"# : #"{"items":[]}"#
            if !list { XCTAssertTrue(request.url!.path.contains("/work/"), "The unselected calendar is not fetched.") }
            return (Data(json.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let account = GoogleCalendarAccount(defaults: defaults, api: api, readToken: { reads += 1; return token }, saveToken: { _ in XCTFail("Fresh tokens are not rewritten.") }, deleteToken: { deleted = true }, readSecret: { XCTFail("Fresh token needs no secret."); return nil })
        let range = DateInterval(start: Date(), duration: 86400)
        _ = try await account.load(range)
        XCTAssertEqual(reads, 1); XCTAssertEqual(account.enabledIDs, ["work"])
        account.setEnabled("home", enabled: true); account.setEnabled("work", enabled: false)
        XCTAssertEqual(defaults.stringArray(forKey: "calendarGoogleEnabledIDs"), ["home"])
        try account.disconnect()
        XCTAssertTrue(deleted); XCTAssertFalse(account.connected); XCTAssertTrue(account.calendars.isEmpty)
        do { _ = try await account.load(range); XCTFail() } catch { XCTAssertEqual(error as? GoogleCalendarError, .signInRequired) }
        XCTAssertEqual(reads, 1, "Disconnected accounts do not read credentials or make requests.")
        XCTAssertNotEqual(GoogleCalendarAccount.tokenKey, MailOAuthCredentials.key("google"))
    }

    @MainActor func testCalendarRefreshPersistsNewTokenAndRetainsRefreshToken() async throws {
        let suite = "CalendarTests." + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "calendarGoogleConnected")
        defaults.set("fixture.apps.googleusercontent.com", forKey: GoogleCalendarAccount.clientKey)
        let old = MailOAuthToken(accessToken: "expired", refreshToken: "fixture-refresh", expiresAt: .distantPast, clientID: "fixture.apps.googleusercontent.com")
        var saved: MailOAuthToken?
        let http = MailOAuthHTTP { request in
            XCTAssertEqual(request.url, MailOAuthProvider.google.tokenURL)
            return (Data(#"{"access_token":"fresh","expires_in":3600,"token_type":"Bearer","scope":"https://www.googleapis.com/auth/calendar.readonly"}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let api = GoogleCalendarAPI { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fresh")
            return (Data(#"{"items":[]}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let account = GoogleCalendarAccount(defaults: defaults, api: api, http: http, readToken: { old }, saveToken: { saved = $0 }, deleteToken: {}, readSecret: { nil })
        _ = try await account.load(.init(start: Date(), duration: 86400))
        XCTAssertEqual(saved?.accessToken, "fresh"); XCTAssertEqual(saved?.refreshToken, "fixture-refresh")
    }

    @MainActor func testChangedClientRequiresSignInWithoutSendingSavedToken() async throws {
        let suite = "CalendarTests." + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "calendarGoogleConnected"); defaults.set("new.apps.googleusercontent.com", forKey: GoogleCalendarAccount.clientKey)
        let token = MailOAuthToken(accessToken: "fixture", refreshToken: "fixture", expiresAt: .distantFuture, clientID: "old.apps.googleusercontent.com")
        let api = GoogleCalendarAPI { _ in XCTFail("A token for another client is never sent."); throw GoogleCalendarError.invalidResponse }
        let account = GoogleCalendarAccount(defaults: defaults, api: api, readToken: { token }, saveToken: { _ in }, deleteToken: {}, readSecret: { nil })
        do { _ = try await account.load(.init(start: Date(), duration: 86400)); XCTFail() } catch { XCTAssertEqual(error as? GoogleCalendarError, .signInRequired) }
    }

    @MainActor func testDisconnectDuringLoadCannotRestoreCalendarState() async throws {
        let suite = "CalendarTests." + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "calendarGoogleConnected"); defaults.set("fixture.apps.googleusercontent.com", forKey: GoogleCalendarAccount.clientKey)
        let token = MailOAuthToken(accessToken: "fixture", refreshToken: "fixture", expiresAt: .distantFuture, clientID: "fixture.apps.googleusercontent.com")
        let started = expectation(description: "Request started")
        let api = GoogleCalendarAPI { request in
            started.fulfill()
            try await Task.sleep(nanoseconds: 100_000_000)
            return (Data(#"{"items":[{"id":"work","summary":"Work"}]}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let account = GoogleCalendarAccount(defaults: defaults, api: api, readToken: { token }, saveToken: { _ in }, deleteToken: {}, readSecret: { nil })
        let work = Task { try await account.load(.init(start: Date(), duration: 86400)) }
        await fulfillment(of: [started], timeout: 2)
        try account.disconnect()
        do { _ = try await work.value; XCTFail() } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(account.connected); XCTAssertTrue(account.calendars.isEmpty)
    }

    @MainActor func testDemoEventDetailsAndBackNeverOpenAppsOrReadAccounts() {
        let suite = "CalendarTests." + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults); preferences.voiceEnabled = false; preferences.jevEnabled = false
        let model = LauncherModel(preferences: preferences, catalogue: AppCatalogue(loadCache: false), keys: JevKeyCache(key: nil), clipboard: ClipboardHistory(pasteboard: CalendarTestPasteboard()))
        let list = SourcePage(.calendar, source: nil, model: model, hasDetail: true, emptyText: "")
        let page = CalendarPage(list: list, readsEvents: false)
        page.opened(); defer { page.closed(handingOff: false) }
        let event = page.displayedEvents.first(where: { $0.id == "demo0" })!
        page.select(event)
        XCTAssertTrue(page.selectedEvent?.notes.contains("launch checklist") == true)
        XCTAssertEqual(page.selectedEvent?.meetingURL?.host, "meet.google.com")
        XCTAssertTrue(page.back()); XCTAssertNil(page.selectedEvent); XCTAssertFalse(page.back())
        page.showDay(event.start); XCTAssertEqual(page.days.count, 1)
        XCTAssertTrue(page.handle(.open(shift: false))); XCTAssertEqual(page.selectedEvent?.id, event.id)
    }

    @MainActor func testGooglePageLoadsWithoutMacCalendarPermissionAndFiltersDetails() async throws {
        let suite = "CalendarTests." + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "calendarGoogleConnected"); defaults.set("Google", forKey: "calendarSource")
        defaults.set("fixture.apps.googleusercontent.com", forKey: GoogleCalendarAccount.clientKey)
        let token = MailOAuthToken(accessToken: "fixture", refreshToken: "fixture", expiresAt: .distantFuture, clientID: "fixture.apps.googleusercontent.com")
        let start = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date())!
        let formatter = ISO8601DateFormatter(), first = formatter.string(from: start), last = formatter.string(from: start.addingTimeInterval(3600))
        let api = GoogleCalendarAPI { request in
            let json = request.url!.path.hasSuffix("calendarList") ? #"{"items":[{"id":"work","summary":"Work","selected":true}]}"#
                : "{\"items\":[{\"id\":\"meeting\",\"summary\":\"Planning\",\"start\":{\"dateTime\":\"\(first)\"},\"end\":{\"dateTime\":\"\(last)\"},\"description\":\"Meeting notes\",\"hangoutLink\":\"https://meet.google.com/abc-defg-hij\"}]}"
            return (Data(json.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let account = GoogleCalendarAccount(defaults: defaults, api: api, readToken: { token }, saveToken: { _ in }, deleteToken: {}, readSecret: { nil })
        let preferences = Preferences(defaults: defaults); preferences.voiceEnabled = false; preferences.jevEnabled = false
        let model = LauncherModel(preferences: preferences, catalogue: AppCatalogue(loadCache: false), keys: JevKeyCache(key: nil), clipboard: ClipboardHistory(pasteboard: CalendarTestPasteboard()))
        let list = SourcePage(.calendar, source: nil, model: model, hasDetail: true, emptyText: "")
        let page = CalendarPage(list: list, readsEvents: true, google: account, defaults: defaults)
        page.opened(); defer { page.closed(handingOff: false) }
        for _ in 0..<100 where page.loading { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(page.loading); XCTAssertNil(page.problem); XCTAssertNil(page.errorMessage)
        XCTAssertEqual(page.source, .google); XCTAssertEqual(page.displayedEvents.map(\.title), ["Planning"])
        let event = try XCTUnwrap(page.displayedEvents.first)
        page.select(event); XCTAssertEqual(page.selectedEvent?.notes, "Meeting notes")
        XCTAssertEqual(page.openTitle, "Join Call")
        page.filter("unmatched"); XCTAssertTrue(page.displayedEvents.isEmpty)
        page.filter("planning"); XCTAssertEqual(page.displayedEvents.count, 1)
    }
}

@MainActor private final class CalendarTestPasteboard: PasteboardReading {
    var changeCount = 0
    var types: [String] = []
    func string() -> String? { nil }
    func write(_ text: String) -> Int { changeCount += 1; return changeCount }
}
