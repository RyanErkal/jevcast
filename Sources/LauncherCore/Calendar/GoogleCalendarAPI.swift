import Foundation

public struct GoogleCalendarAPI: Sendable {
    public static let scopes = ["https://www.googleapis.com/auth/calendar.readonly"]
    public typealias Request = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    private let request: Request
    public init(request: @escaping Request = GoogleCalendarAPI.network) { self.request = request }

    public static func requireOnline() throws {
        guard ProcessInfo.processInfo.environment["JEVCAST_CALENDAR_OFFLINE"] != "1",
              ProcessInfo.processInfo.environment["JEVCAST_MAIL_OFFLINE"] != "1",
              !CommandLine.arguments.contains("--snapshot-ui") else { throw GoogleCalendarError.offline }
    }

    public static let network: Request = { request in
        try requireOnline()
        guard let url = request.url, url.scheme == "https", url.host == "www.googleapis.com", url.port == nil,
              url.path.hasPrefix("/calendar/v3/"), url.user == nil, url.password == nil, request.httpMethod == "GET" else { throw GoogleCalendarError.invalidResponse }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 25; config.timeoutIntervalForResource = 40
        let session = URLSession(configuration: config, delegate: CalendarNoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw GoogleCalendarError.invalidResponse }
            return (data, response)
        } catch is CancellationError { throw CancellationError() }
        catch let error as GoogleCalendarError { throw error }
        catch { if Task.isCancelled { throw CancellationError() }; throw GoogleCalendarError.unavailable }
    }

    public func calendars(token: String) async throws -> [GoogleCalendarInfo] {
        struct Page: Decodable { let items: [GoogleCalendarInfo]?; let nextPageToken: String? }
        var result: [GoogleCalendarInfo] = [], next: String?, seen = Set<String>(), pages = 0
        repeat {
            let page: Page = try await get(path: "users/me/calendarList", query: [.init(name: "maxResults", value: "250"), .init(name: "showHidden", value: "false")], page: next, token: token)
            result += page.items ?? []
            pages += 1
            guard result.count <= 250, pages <= 50 else { throw GoogleCalendarError.tooManyEvents }
            next = page.nextPageToken
            if let next, !seen.insert(next).inserted { throw GoogleCalendarError.invalidResponse }
        } while next != nil
        guard Set(result.map(\.id)).count == result.count, result.allSatisfy({ !$0.id.isEmpty }) else { throw GoogleCalendarError.invalidResponse }
        return result.filter { $0.hidden != true }
    }

    public func events(in range: DateInterval, calendars: [GoogleCalendarInfo], token: String, displayCalendar: Calendar = .current) async throws -> [GoogleCalendarEvent] {
        struct Page: Decodable { let items: [GoogleEventPayload]?; let nextPageToken: String? }
        guard range.end > range.start, calendars.count <= 100 else { throw GoogleCalendarError.tooManyEvents }
        let formatter = ISO8601DateFormatter()
        var result: [GoogleCalendarEvent] = []
        let query: [URLQueryItem] = [
            .init(name: "timeMin", value: formatter.string(from: range.start)), .init(name: "timeMax", value: formatter.string(from: range.end)),
            .init(name: "singleEvents", value: "true"), .init(name: "orderBy", value: "startTime"), .init(name: "showDeleted", value: "false"),
            .init(name: "maxResults", value: "2500"), .init(name: "timeZone", value: displayCalendar.timeZone.identifier)
        ]
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        for calendar in calendars {
            guard !calendar.id.isEmpty, let encoded = calendar.id.addingPercentEncoding(withAllowedCharacters: allowed) else { throw GoogleCalendarError.invalidResponse }
            var next: String?, seen = Set<String>(), pages = 0
            repeat {
                try Task.checkCancellation()
                let page: Page = try await get(path: "calendars/" + encoded + "/events", query: query, page: next, token: token)
                for payload in page.items ?? [] {
                    if let event = try payload.event(calendar: calendar, displayCalendar: displayCalendar), event.start < range.end, event.end > range.start { result.append(event) }
                }
                pages += 1
                guard result.count <= 20_000, pages <= 50 else { throw GoogleCalendarError.tooManyEvents }
                next = page.nextPageToken
                if let next, !seen.insert(next).inserted { throw GoogleCalendarError.invalidResponse }
            } while next != nil
        }
        // A recurring instance has its own Google ID. A duplicate page is not another event.
        var unique: [String: GoogleCalendarEvent] = [:]
        for event in result { unique[event.id] = event }
        return unique.values.sorted { ($0.start, $0.id) < ($1.start, $1.id) }
    }

    private func get<T: Decodable>(path: String, query: [URLQueryItem], page: String?, token: String) async throws -> T {
        guard !token.isEmpty, token.count < 32_768, token.unicodeScalars.allSatisfy({ $0.value > 32 && $0.value != 127 }),
              page.map({ !$0.isEmpty && $0.count <= 8192 }) ?? true else { throw GoogleCalendarError.invalidResponse }
        var components = URLComponents(string: "https://www.googleapis.com/calendar/v3/" + path)!
        components.queryItems = query + (page.map { [.init(name: "pageToken", value: $0)] } ?? [])
        guard let url = components.url else { throw GoogleCalendarError.invalidResponse }
        var req = URLRequest(url: url); req.httpMethod = "GET"
        req.setValue("Bearer " + token, forHTTPHeaderField: "Authorization"); req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await request(req)
        try Task.checkCancellation()
        guard response.url == url, data.count <= 16 * 1024 * 1024 else { throw GoogleCalendarError.invalidResponse }
        switch response.statusCode {
        case 200: break
        case 401: throw GoogleCalendarError.signInRequired
        case 403: throw GoogleCalendarError.permissionDenied
        default: throw GoogleCalendarError.unavailable
        }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw GoogleCalendarError.invalidResponse }
    }
}

private final class CalendarNoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
