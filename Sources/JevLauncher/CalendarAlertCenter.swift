import AppKit
import EventKit
import LauncherCore

/// A mark in the notch a few minutes before a meeting starts, with Join when the event has a call
/// link. It reads this Mac's calendars and the Google accounts connected in Calendar. It never
/// opens a window, and it shows as the small mark until clicked.
@MainActor
final class CalendarAlertCenter {
    static let shared = CalendarAlertCenter()
    static let alertPrefix = "calendar-meeting:"
    static let enabledKey = "calendarMeetingAlerts"
    private static let joinAction = "calendar-join", openAction = "calendar-open"

    var openCalendar: (() -> Void)?
    private let defaults: UserDefaults
    private let show: @MainActor (NotchAlert) -> Void
    private let open: @MainActor (URL) -> Void
    private var loop: Task<Void, Never>?
    private var announced: Set<String> = []
    private var links: [String: URL] = [:]
    private var google: [CalendarPage.Event] = []
    private var googleReadAt = Date.distantPast

    init(defaults: UserDefaults = .standard, show: @escaping @MainActor (NotchAlert) -> Void = { NotchAlertController.shared.show($0) },
         open: @escaping @MainActor (URL) -> Void = { Frontmost.open($0) }) {
        self.defaults = defaults; self.show = show; self.open = open
    }

    /// On unless turned off in the Calendar menu.
    var enabled: Bool {
        get { defaults.object(forKey: Self.enabledKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Self.enabledKey) }
    }

    func start() {
        guard loop == nil else { return }
        loop = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await self?.check()
                try? await Task.sleep(nanoseconds: 60_000_000_000)
            }
        }
    }

    private func check(now: Date = Date()) async {
        guard enabled else { return }
        var events: [CalendarPage.Event] = []
        if EKEventStore.authorizationStatus(for: .event) == .fullAccess {
            nonisolated(unsafe) let store = Permissions.events
            let range = DateInterval(start: now.addingTimeInterval(-120), end: now.addingTimeInterval(900))
            events += await Task.detached(priority: .utility) { CalendarPage.fetch(store, range) }.value
        }
        // Google is read at most every ten minutes, for the next twelve hours.
        let accounts = GoogleCalendarAccounts.shared.connected
        if !accounts.isEmpty, now.timeIntervalSince(googleReadAt) > 600 {
            googleReadAt = now
            var found: [CalendarPage.Event] = []
            for account in accounts {
                found += (try? await CalendarPage.googleEvents(account, DateInterval(start: now.addingTimeInterval(-120), duration: 12 * 3600), refreshCalendars: false)) ?? []
            }
            google = found
        }
        if accounts.isEmpty { google = [] }
        let local = Set(events.map { $0.title + "|\($0.start.timeIntervalSince1970)" })
        events += google.filter { !local.contains($0.title + "|\($0.start.timeIntervalSince1970)") }
        announce(events, now: now)
    }

    func announce(_ events: [CalendarPage.Event], now: Date) {
        let due = MeetingAlert.due(events.map { .init(id: $0.id, start: $0.start, allDay: $0.allDay) }, now: now, announced: announced)
        for candidate in due {
            guard let event = events.first(where: { $0.id == candidate.id && $0.start == candidate.start }) else { continue }
            announced.insert(candidate.key)
            let id = Self.alertPrefix + candidate.key
            var actions: [NotchAlert.Action] = []
            if let link = event.meetingURL {
                links[id] = link
                actions.append(.init(link.host == "meet.google.com" ? "Join Google Meet" : "Join Call", id: Self.joinAction, primary: true))
            }
            actions.append(.init("Open Calendar", id: Self.openAction, primary: event.meetingURL == nil))
            actions.append(.init("Dismiss", id: NotchAlert.dismissAction))
            let place = event.location.isEmpty || event.meetingURL != nil ? "" : " · " + event.location
            var alert = NotchAlert(id: id, kind: .info, symbol: event.meetingURL == nil ? "calendar" : "video.fill", title: event.title,
                                   message: MeetingAlert.when(event.start, now: now) + " · " + event.start.formatted(date: .omitted, time: .shortened) + place,
                                   actions: actions)
            alert.minimized = true
            show(alert)
        }
        // Old keys leave after a day, so the set stays small.
        if announced.count > 500 { announced.removeAll(); links.removeAll() }
    }

    /// True when the action belongs to a meeting notice.
    @discardableResult func handle(alert: NotchAlert, action: String) -> Bool {
        guard alert.id.hasPrefix(Self.alertPrefix) else { return false }
        if action == Self.joinAction, let link = links[alert.id] { open(link) }
        else if action == Self.openAction { openCalendar?() }
        return true
    }
}
