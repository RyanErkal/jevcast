import Foundation

/// How long each kind stays up when the pointer is not over it. Nil means it stays until handled.
enum NotchTiming {
    static let infoSeconds: TimeInterval = 6
    /// The result of Approve all, with Undo.
    static let resultSeconds: TimeInterval = 10
    static let defaultFailureSeconds: TimeInterval = 8

    static func seconds(for kind: NotchAlert.Kind, failureSeconds: TimeInterval) -> TimeInterval? {
        switch kind {
        case .running, .question, .approval: return nil
        case .failure: return failureSeconds
        case .success: return resultSeconds
        case .info: return infoSeconds
        }
    }
}

/// The alerts waiting for the notch, and what shows now. Pure: the controller owns windows and clocks.
///
/// Rules:
/// - Priority: question and approval, then failure, then success and info, then running.
/// - One alert per ID and per run: a newer alert for the same run replaces the older one.
/// - Everything that is not a running indicator shows together. Two or more become one stack.
/// - Running indicators show only when nothing else waits.
/// - Timed alerts count down only while they are visible, and not while the pointer is over them.
struct NotchQueue {
    struct Entry: Equatable {
        var alert: NotchAlert
        var order: Int
        /// When a visible, timed alert closes. Nil while hidden, paused, or persistent.
        var deadline: Date?
    }

    static let stackID = "stack"

    private(set) var entries: [Entry] = []
    private var counter = 0
    var failureSeconds = NotchTiming.defaultFailureSeconds

    static func priority(_ kind: NotchAlert.Kind) -> Int {
        switch kind {
        case .question, .approval: return 3
        case .failure: return 2
        case .success, .info: return 1
        case .running: return 0
        }
    }

    var isEmpty: Bool { entries.isEmpty }
    func contains(_ id: String) -> Bool { entries.contains { $0.alert.id == id } }
    func alert(_ id: String) -> NotchAlert? { entries.first { $0.alert.id == id }?.alert }

    func containsRunOrID(_ alert: NotchAlert) -> Bool {
        entries.contains { entry in
            entry.alert.id == alert.id || (alert.runID != nil && entry.alert.runID == alert.runID
                                          && entry.alert.automationID == alert.automationID)
        }
    }

    /// Adds an alert, or replaces the one with the same ID or run. Returns false when nothing changed.
    @discardableResult mutating func add(_ alert: NotchAlert) -> Bool {
        if let index = entries.firstIndex(where: { $0.alert.id == alert.id }) {
            guard entries[index].alert != alert else { return false }
            if entries[index].alert.kind != alert.kind { entries[index].deadline = nil }
            entries[index].alert = alert
            return true
        }
        if let runID = alert.runID, let index = entries.firstIndex(where: { $0.alert.runID == runID && $0.alert.automationID == alert.automationID }) {
            counter += 1
            entries[index] = Entry(alert: alert, order: counter, deadline: nil)
            return true
        }
        counter += 1
        entries.append(Entry(alert: alert, order: counter, deadline: nil))
        return true
    }

    @discardableResult mutating func remove(_ id: String) -> NotchAlert? {
        guard let index = entries.firstIndex(where: { $0.alert.id == id }) else { return nil }
        return entries.remove(at: index).alert
    }

    mutating func removeAll(where match: (NotchAlert) -> Bool) -> [NotchAlert] {
        let gone = entries.filter { match($0.alert) }.map(\.alert)
        entries.removeAll { match($0.alert) }
        return gone
    }

    /// The entries on screen now, highest priority first.
    var visible: [Entry] {
        let sorted = entries.sorted {
            let a = Self.priority($0.alert.kind), b = Self.priority($1.alert.kind)
            return a != b ? a > b : $0.order < $1.order
        }
        let actionable = sorted.filter { $0.alert.kind != .running }
        return actionable.isEmpty ? sorted : actionable
    }

    /// What the notch shows: one alert, a stack, or nothing.
    var presentation: NotchAlert? {
        let shown = visible.map(\.alert)
        guard let first = shown.first else { return nil }
        guard shown.count > 1 else { return first }
        return Self.stack(shown)
    }

    static func stack(_ alerts: [NotchAlert]) -> NotchAlert {
        let n = alerts.count
        let title: String
        let symbol: String
        if alerts.allSatisfy({ $0.kind == .running }) {
            title = "\(n) automations running"; symbol = "gearshape.2"
        } else if alerts.contains(where: { $0.kind == .question || $0.kind == .approval }) {
            title = "\(n) automations need you"; symbol = "bell.badge"
        } else if alerts.allSatisfy({ $0.kind == .failure }) {
            title = "\(n) automations failed"; symbol = "exclamationmark.triangle"
        } else {
            title = "\(n) alerts"; symbol = "bell"
        }
        let kind = alerts.first?.kind ?? .info
        return NotchAlert(id: stackID, kind: kind, symbol: symbol, title: title,
                          message: alerts.prefix(3).map(\.title).joined(separator: ", ") + (n > 3 ? "…" : ""),
                          actions: [.init("Show", id: NotchAlert.expandAction, primary: true), .init("Later", id: "later")],
                          stack: alerts)
    }

    /// Starts the countdown of visible timed alerts that do not have one.
    mutating func startTimers(now: Date) {
        let ids = Set(visible.map(\.alert.id))
        for i in entries.indices where ids.contains(entries[i].alert.id) && entries[i].deadline == nil {
            if let seconds = NotchTiming.seconds(for: entries[i].alert.kind, failureSeconds: failureSeconds) {
                entries[i].deadline = now.addingTimeInterval(seconds)
            }
        }
    }

    /// Stops every countdown, for example while the pointer is over the notch. `startTimers` begins them again in full.
    mutating func pauseTimers() {
        for i in entries.indices { entries[i].deadline = nil }
    }

    /// Removes alerts whose time is up and returns them.
    mutating func expire(now: Date) -> [NotchAlert] {
        let due = Set(entries.filter { $0.deadline.map { $0 <= now } ?? false }.map(\.alert.id))
        return removeAll { due.contains($0.id) }
    }

    var nextDeadline: Date? { entries.compactMap(\.deadline).min() }
}
