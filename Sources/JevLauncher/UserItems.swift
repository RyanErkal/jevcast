import Foundation

/// A command the user writes in Settings › Commands. Jev sees only its name.
struct CustomCommand: Codable, Identifiable, Equatable, Hashable {
    enum Output: String, Codable, CaseIterable {
        case none, copy, notify
        var title: String {
            switch self {
            case .none: return "Nothing"
            case .copy: return "Copy the output"
            case .notify: return "Show the output in a notification"
            }
        }
    }
    static let inputPlaceholder = "{input}"

    var id = UUID().uuidString
    var name: String
    var command: String
    var output: Output = .none

    /// True when the command takes text typed after its name, such as "Open repo swift".
    var takesInput: Bool { command.contains(Self.inputPlaceholder) }

    init(id: String = UUID().uuidString, name: String, command: String, output: Output = .none) {
        self.id = id; self.name = name; self.command = command; self.output = output
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        command = try c.decode(String.self, forKey: .command)
        output = try c.decodeIfPresent(Output.self, forKey: .output) ?? .none
    }
}

/// Saved text. Placeholders are filled on this Mac when the snippet is used.
struct Snippet: Codable, Identifiable, Equatable, Hashable {
    var id = UUID().uuidString
    var name: String
    var text: String

    static let placeholders = ["{date}", "{time}", "{clipboard}"]

    func expanded(now: Date = Date(), clipboard: String?) -> String {
        text
            .replacingOccurrences(of: "{date}", with: now.formatted(date: .abbreviated, time: .omitted))
            .replacingOccurrences(of: "{time}", with: now.formatted(date: .omitted, time: .shortened))
            .replacingOccurrences(of: "{clipboard}", with: clipboard ?? "")
    }
}

/// A saved sequence of actions, such as "Coding": open Xcode, left two thirds,
/// open Terminal, right third. A window step moves the app the step before opened.
struct Workflow: Codable, Identifiable, Equatable, Hashable {
    struct Step: Codable, Identifiable, Equatable, Hashable {
        enum Kind: String, Codable, CaseIterable {
            case app, window, command, custom, shortcut, wait
            var title: String {
                switch self {
                case .app: return "Open app"
                case .window: return "Arrange window"
                case .command: return "Built-in command"
                case .custom: return "Your command"
                case .shortcut: return "Shortcut"
                case .wait: return "Wait"
                }
            }
        }
        var id = UUID().uuidString
        var kind: Kind
        /// An app ID, window action, command ID, custom command ID, Shortcut name, or seconds to wait.
        var value: String
    }
    var id = UUID().uuidString
    var name: String
    var steps: [Step]
}
