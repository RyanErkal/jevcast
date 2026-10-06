import Foundation

public enum GoogleCalendarError: Error, LocalizedError, Equatable {
    case signInRequired, setupRequired, permissionDenied, invalidResponse, tooManyEvents, offline, unavailable
    public var errorDescription: String? {
        switch self {
        case .signInRequired: return "Sign in to Google Calendar again."
        case .setupRequired: return "Add a Google Desktop app client ID in Calendar › Connect Google."
        case .permissionDenied: return "Google Calendar access was refused. Enable the Calendar API in your Google project and allow read-only Calendar access when you sign in."
        case .invalidResponse: return "Google Calendar returned an invalid response. Try Refresh."
        case .tooManyEvents: return "This calendar has too many results to show safely. Select fewer calendars or a shorter date range."
        case .offline: return "Google Calendar is offline for this check."
        case .unavailable: return "Google Calendar could not be reached. Try Refresh."
        }
    }
}

public struct GoogleCalendarInfo: Decodable, Equatable, Identifiable, Sendable {
    public let id: String
    public let summary: String
    public let backgroundColor: String?
    public let timeZone: String?
    public let selected: Bool?
    public let hidden: Bool?
    public let primary: Bool?
}

public struct CalendarGuest: Equatable, Sendable {
    public let name: String
    public let response: String
    public init(name: String, response: String) { self.name = name; self.response = response }
}

public struct CalendarAttachment: Equatable, Sendable {
    public let title: String
    public let url: URL
    public init(title: String, url: URL) { self.title = title; self.url = url }
}

public struct GoogleCalendarEvent: Equatable, Identifiable, Sendable {
    public let id: String
    public let calendarID: String
    public let title: String
    public let start: Date
    public let end: Date
    public let allDay: Bool
    public let notes: String
    public let location: String
    public let organizer: String
    public let guests: [CalendarGuest]
    public let attachments: [CalendarAttachment]
    public let meetingURL: URL?
    public let webURL: URL?
    public let timeZone: String?
}

public enum CalendarLinks {
    public static func web(_ value: String?) -> URL? {
        guard let value, let url = URL(string: value), ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              url.host?.isEmpty == false, url.user == nil, url.password == nil else { return nil }
        return url
    }

    /// Descriptions are displayed as text. No HTML or remote resources are rendered.
    public static func plainNotes(_ html: String) -> String {
        var text = html.replacingOccurrences(of: #"(?i)<br\s*/?>|</p>|</div>|</li>"#, with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: #"<[^>]*>"#, with: "", options: .regularExpression)
        for (entity, value) in [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&amp;", "&")] {
            text = text.replacingOccurrences(of: entity, with: value)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func noteLinks(_ html: String) -> [CalendarAttachment] {
        guard let expression = try? NSRegularExpression(pattern: #"(?is)<a\b[^>]*\bhref\s*=\s*["']([^"']+)["'][^>]*>(.*?)</a>"#) else { return [] }
        return expression.matches(in: html, range: NSRange(html.startIndex..., in: html)).compactMap { match in
            guard let address = Range(match.range(at: 1), in: html), let title = Range(match.range(at: 2), in: html),
                  let url = web(plainNotes(String(html[address]))) else { return nil }
            let label = plainNotes(String(html[title]))
            return CalendarAttachment(title: label.isEmpty ? url.host ?? "Link" : label, url: url)
        }
    }
}

struct GoogleEventPayload: Decodable {
    struct Moment: Decodable { let dateTime: String?; let date: String?; let timeZone: String? }
    struct Person: Decodable {
        let displayName: String?; let email: String?; let responseStatus: String?; let isCurrentUser: Bool?
        enum CodingKeys: String, CodingKey { case displayName, email, responseStatus; case isCurrentUser = "self" }
    }
    struct Attachment: Decodable { let title: String?; let fileUrl: String? }
    struct Conference: Decodable {
        struct Entry: Decodable { let entryPointType: String?; let uri: String? }
        let entryPoints: [Entry]?
    }
    let id: String
    let summary: String?
    let status: String?
    let start: Moment?
    let end: Moment?
    let description: String?
    let location: String?
    let organizer: Person?
    let attendees: [Person]?
    let attachments: [Attachment]?
    let hangoutLink: String?
    let htmlLink: String?
    let conferenceData: Conference?

    func event(calendar: GoogleCalendarInfo, displayCalendar: Calendar) throws -> GoogleCalendarEvent? {
        guard status != "cancelled", !(attendees ?? []).contains(where: { $0.isCurrentUser == true && $0.responseStatus == "declined" }) else { return nil }
        guard !id.isEmpty, let start, let end, (start.date != nil) == (end.date != nil) else { throw GoogleCalendarError.invalidResponse }
        let allDay = start.date != nil
        guard let first = Self.date(start, allDay: allDay, calendar: displayCalendar, zone: calendar.timeZone),
              let last = Self.date(end, allDay: allDay, calendar: displayCalendar, zone: calendar.timeZone), last > first else { throw GoogleCalendarError.invalidResponse }
        let meeting = MeetingLink.find(in: [hangoutLink] + (conferenceData?.entryPoints ?? []).filter { $0.entryPointType == "video" }.map(\.uri) + [location, description])
        var links = (attachments ?? []).compactMap { item in CalendarLinks.web(item.fileUrl).map { CalendarAttachment(title: item.title ?? "Attachment", url: $0) } }
        for link in CalendarLinks.noteLinks(description ?? "") where !links.contains(where: { $0.url == link.url }) { links.append(link) }
        return GoogleCalendarEvent(id: calendar.id + ":" + id, calendarID: calendar.id, title: summary ?? "Untitled event",
            start: first, end: last, allDay: allDay, notes: CalendarLinks.plainNotes(description ?? ""), location: location ?? "",
            organizer: organizer?.displayName ?? organizer?.email ?? "",
            guests: (attendees ?? []).map { CalendarGuest(name: $0.displayName ?? $0.email ?? "Guest", response: $0.responseStatus ?? "needsAction") },
            attachments: links,
            meetingURL: meeting.flatMap { CalendarLinks.web($0.absoluteString) }, webURL: CalendarLinks.web(htmlLink), timeZone: start.timeZone ?? calendar.timeZone)
    }

    private static func date(_ moment: Moment, allDay: Bool, calendar: Calendar, zone: String?) -> Date? {
        if allDay {
            guard let value = moment.date, value.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else { return nil }
            let parts = value.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 3 else { return nil }
            let components = DateComponents(year: parts[0], month: parts[1], day: parts[2])
            guard let date = calendar.date(from: components), calendar.dateComponents([.year, .month, .day], from: date) == components else { return nil }
            return date
        }
        guard let value = moment.dateTime else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: value) { return date }
        // Google permits a dateTime without an offset when timeZone is supplied.
        guard let name = moment.timeZone ?? zone, let timeZone = TimeZone(identifier: name) else { return nil }
        let local = DateFormatter(); local.locale = Locale(identifier: "en_US_POSIX"); local.calendar = Calendar(identifier: .gregorian)
        local.timeZone = timeZone; local.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"; local.isLenient = false
        return local.date(from: value)
    }
}
