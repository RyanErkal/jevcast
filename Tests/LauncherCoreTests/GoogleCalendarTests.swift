import XCTest
@testable import LauncherCore

final class GoogleCalendarTests: XCTestCase {
    private var calendar: Calendar { var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "Europe/London")!; return cal }
    private func info(_ id: String = "work@example.com") throws -> GoogleCalendarInfo {
        try JSONDecoder().decode(GoogleCalendarInfo.self, from: Data("{\"id\":\"\(id)\",\"summary\":\"Work\",\"timeZone\":\"Europe/London\",\"selected\":true}".utf8))
    }
    private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
    private func response(_ request: URLRequest, _ json: String, status: Int = 200) -> (Data, HTTPURLResponse) {
        (Data(json.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }

    func testCalendarAuthorizationRequestsReadOnlyScopeAndPKCE() throws {
        let authorization = MailOAuthAuthorization(verifier: "fixture-verifier", state: "fixture-state")
        let url = try authorization.url(client: MailOAuthClient(provider: .google, clientID: "fixture.apps.googleusercontent.com"),
            redirect: URL(string: "http://127.0.0.1:55555/oauth/callback")!, email: "", scopes: GoogleCalendarAPI.scopes)
        let values = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(url.host, "accounts.google.com")
        XCTAssertEqual(values["scope"], "https://www.googleapis.com/auth/calendar.readonly")
        XCTAssertEqual(values["state"], "fixture-state"); XCTAssertEqual(values["code_challenge"], authorization.challenge)
        XCTAssertEqual(values["access_type"], "offline"); XCTAssertEqual(values["prompt"], "consent")
        XCTAssertFalse(url.absoluteString.contains("mail.google.com"))
    }

    func testCalendarTokenExchangeAndRefreshValidateCalendarScope() async throws {
        let client = try MailOAuthClient(provider: .google, clientID: "fixture.apps.googleusercontent.com")
        let http = MailOAuthHTTP { request in
            let refresh = String(decoding: request.httpBody!, as: UTF8.self).contains("grant_type=refresh_token")
            let json = "{\"access_token\":\"fixture-access\",\"expires_in\":3600,\"token_type\":\"Bearer\",\"scope\":\"https://www.googleapis.com/auth/calendar.readonly\"" + (refresh ? "}" : ",\"refresh_token\":\"fixture-refresh\"}")
            return (Data(json.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let token = try await http.exchange(code: "fixture", authorization: .init(verifier: "fixture", state: "fixture"), redirect: URL(string: "http://127.0.0.1:55555/oauth/callback")!, client: client, scopes: GoogleCalendarAPI.scopes)
        let fresh = try await http.refresh(token, client: client, scopes: GoogleCalendarAPI.scopes)
        XCTAssertEqual(fresh.refreshToken, "fixture-refresh")
        do { _ = try await http.refresh(token, client: client); XCTFail("Calendar scope cannot authorize Mail.") }
        catch { XCTAssertEqual(error as? MailOAuthError, .invalidToken) }
    }

    func testGoogleDetailsNotesGuestsMeetAndSafeAttachments() throws {
        let json = #"{"id":"recurring_20261006","summary":"Planning","start":{"dateTime":"2026-10-06T09:30:00+01:00","timeZone":"Europe/London"},"end":{"dateTime":"2026-10-06T10:30:00+01:00"},"description":"<p>Meeting notes</p>Review &amp; agree<br>Next steps","location":"Online","organizer":{"displayName":"Sam"},"attendees":[{"email":"alex@example.com","responseStatus":"accepted"}],"conferenceData":{"entryPoints":[{"entryPointType":"video","uri":"https://meet.google.com/abc-defg-hij"}]},"htmlLink":"https://calendar.google.com/calendar/event?eid=fixture","attachments":[{"title":"Notes","fileUrl":"https://docs.google.com/document/d/fixture"},{"title":"Unsafe","fileUrl":"file:///etc/passwd"},{"title":"Unsafe script","fileUrl":"javascript:alert(1)"}]}"#
        let payload = try JSONDecoder().decode(GoogleEventPayload.self, from: Data(json.utf8))
        let event = try XCTUnwrap(payload.event(calendar: info(), displayCalendar: calendar))
        XCTAssertEqual(event.start, date("2026-10-06T08:30:00Z"))
        XCTAssertEqual(event.notes, "Meeting notes\nReview & agree\nNext steps")
        XCTAssertEqual(event.meetingURL?.host, "meet.google.com"); XCTAssertEqual(event.organizer, "Sam")
        XCTAssertEqual(event.guests, [.init(name: "alex@example.com", response: "accepted")])
        XCTAssertEqual(event.attachments.count, 1); XCTAssertEqual(event.id, "work@example.com:recurring_20261006")
    }

    func testAllDayDatesUseDisplayedDaysAndExclusiveEnd() throws {
        let payload = try JSONDecoder().decode(GoogleEventPayload.self, from: Data(#"{"id":"holiday","start":{"date":"2026-10-06"},"end":{"date":"2026-10-08"}}"#.utf8))
        let event = try XCTUnwrap(payload.event(calendar: info(), displayCalendar: calendar))
        XCTAssertTrue(event.allDay)
        XCTAssertEqual(event.start, date("2026-10-05T23:00:00Z")); XCTAssertEqual(event.end, date("2026-10-07T23:00:00Z"))
    }

    func testCancelledDeclinedAndMalformedEvents() throws {
        for json in [#"{"id":"cancelled","status":"cancelled"}"#, #"{"id":"declined","attendees":[{"self":true,"responseStatus":"declined"}]}"#] {
            let payload = try JSONDecoder().decode(GoogleEventPayload.self, from: Data(json.utf8))
            XCTAssertNil(try payload.event(calendar: info(), displayCalendar: calendar))
        }
        for json in [
            #"{"id":"invalid","start":{"date":"2026-02-30"},"end":{"date":"2026-03-02"}}"#,
            #"{"id":"invalid","start":{"dateTime":"2026-10-06T09:00:00Z"},"end":{"dateTime":"2026-10-06T08:00:00Z"}}"#,
            #"{"id":"invalid","start":{"dateTime":"bad"},"end":{"dateTime":"bad"}}"#
        ] { let payload = try JSONDecoder().decode(GoogleEventPayload.self, from: Data(json.utf8)); XCTAssertThrowsError(try payload.event(calendar: info(), displayCalendar: calendar)) }
        XCTAssertNil(CalendarLinks.web("https://user:secret@example.com/notes"))
    }

    func testLocalDateTimeWithNamedZone() throws {
        let payload = try JSONDecoder().decode(GoogleEventPayload.self, from: Data(#"{"id":"local","start":{"dateTime":"2026-10-06T09:00:00","timeZone":"America/New_York"},"end":{"dateTime":"2026-10-06T10:00:00","timeZone":"America/New_York"}}"#.utf8))
        XCTAssertEqual(try payload.event(calendar: info(), displayCalendar: calendar)?.start, date("2026-10-06T13:00:00Z"))
    }

    func testLinkedMeetingNotesKeepSafeURLsWithoutRenderingHTML() {
        let links = CalendarLinks.noteLinks(#"<a href="https://docs.google.com/document/d/fixture?x=1&amp;y=2"><b>Meeting notes</b></a><a href='javascript:alert(1)'>Unsafe</a><a href='file:///tmp/private'>Local</a>"#)
        XCTAssertEqual(links.count, 1); XCTAssertEqual(links[0].title, "Meeting notes")
        XCTAssertEqual(links[0].url.absoluteString, "https://docs.google.com/document/d/fixture?x=1&y=2")
    }

    func testPaginatedCalendarListAndHiddenCalendars() async throws {
        let api = GoogleCalendarAPI { request in
            XCTAssertEqual(request.url?.host, "www.googleapis.com"); XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture")
            let second = request.url!.query!.contains("pageToken=next")
            let json = second ? #"{"items":[{"id":"hidden","summary":"Hidden","hidden":true},{"id":"second","summary":"Second"}]}"# : #"{"items":[{"id":"first","summary":"First"}],"nextPageToken":"next"}"#
            return self.response(request, json)
        }
        let found = try await api.calendars(token: "fixture")
        XCTAssertEqual(found.map(\.id), ["first", "second"])
    }

    func testPaginatedEventsEncodeCalendarIDAndExpandRecurringInstances() async throws {
        let api = GoogleCalendarAPI { request in
            XCTAssertTrue(request.url!.absoluteString.contains("work%40example.com"))
            let query = Dictionary(uniqueKeysWithValues: URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value ?? "") })
            XCTAssertEqual(query["singleEvents"], "true"); XCTAssertEqual(query["orderBy"], "startTime"); XCTAssertEqual(query["showDeleted"], "false")
            let id = query["pageToken"] == nil ? "instance1" : "instance2"
            let next = query["pageToken"] == nil ? ",\"nextPageToken\":\"next\"" : ""
            return self.response(request, "{\"items\":[{\"id\":\"\(id)\",\"start\":{\"dateTime\":\"2026-10-06T09:00:00Z\"},\"end\":{\"dateTime\":\"2026-10-06T10:00:00Z\"}}]\(next)}")
        }
        let found = try await api.events(in: .init(start: date("2026-10-06T00:00:00Z"), end: date("2026-10-07T00:00:00Z")), calendars: [info()], token: "fixture", displayCalendar: calendar)
        XCTAssertEqual(found.count, 2); XCTAssertNotEqual(found[0].id, found[1].id)
    }

    func testRefusalRedirectMalformedResponseAndRepeatedPageAreSafeErrors() async throws {
        for status in [401, 403, 302, 500] {
            let api = GoogleCalendarAPI { self.response($0, #"{"error":"private response"}"#, status: status) }
            do { _ = try await api.calendars(token: "fixture"); XCTFail() }
            catch { XCTAssertFalse(error.localizedDescription.contains("private response")); XCTAssertTrue(error is GoogleCalendarError) }
        }
        let redirected = GoogleCalendarAPI { request in
            (Data(#"{"items":[]}"#.utf8), HTTPURLResponse(url: URL(string: "https://example.com/")!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        do { _ = try await redirected.calendars(token: "fixture"); XCTFail() } catch { XCTAssertEqual(error as? GoogleCalendarError, .invalidResponse) }
        let repeated = GoogleCalendarAPI { self.response($0, #"{"items":[],"nextPageToken":"same"}"#) }
        do { _ = try await repeated.calendars(token: "fixture"); XCTFail() } catch { XCTAssertEqual(error as? GoogleCalendarError, .invalidResponse) }
        let invalid = GoogleCalendarAPI { self.response($0, "not JSON") }
        do { _ = try await invalid.calendars(token: "fixture"); XCTFail() } catch { XCTAssertEqual(error as? GoogleCalendarError, .invalidResponse) }
    }
}
