import Foundation

/// The alerts the notch has reported as drawn, by what they showed. Run alerts keep their ID through every state of the
/// run, so the key also holds the kind and the visible words: a second question, or an approval that became a success,
/// is a new key and is reported again. A key goes when its alert leaves the queue or changes there.
struct NotchPresentedLog {
    struct Key: Hashable {
        let id: String
        let kind: NotchAlert.Kind
        let title: String
        let message: String
        let choices: [String]
        let actions: [String]
    }

    private(set) var keys: Set<Key> = []

    static func key(_ alert: NotchAlert) -> Key {
        Key(id: alert.id, kind: alert.kind, title: alert.title, message: alert.message, choices: alert.choices,
            actions: alert.actions.map(\.title))
    }

    /// Forgets every alert that is not in `alerts` as it is now. Call with the queue after each change.
    mutating func keep(_ alerts: [NotchAlert]) {
        keys.formIntersection(alerts.map(Self.key))
    }

    /// Records `drawn` and returns the alerts not reported before, in order.
    mutating func record(_ drawn: [NotchAlert]) -> [NotchAlert] {
        drawn.filter { keys.insert(Self.key($0)).inserted }
    }
}
