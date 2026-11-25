import AppKit
import SwiftUI

/// The composer's own choices that last: whether the formatting bar shows. It is hidden until
/// the Aa button shows it, and stays as you left it. Nil defaults (snapshots, tests) keep nothing.
@MainActor
final class MailComposerPreferences: ObservableObject {
    private let defaults: UserDefaults?
    @Published var showsFormatting: Bool {
        didSet { defaults?.set(showsFormatting, forKey: MailReading.formattingKey) }
    }

    init(defaults: UserDefaults?, showsFormatting: Bool? = nil) {
        self.defaults = defaults
        self.showsFormatting = showsFormatting ?? defaults?.object(forKey: MailReading.formattingKey) as? Bool ?? false
    }
}

/// Formatting keys in the composer's text, as in Apple Mail. They work while the formatting bar
/// is hidden. Read as characters, so they match the key caps on every layout.
enum MailFormattingKey: Equatable {
    case bold, italic, underline, increaseIndent, decreaseIndent

    static func command(characters: String?, flags: NSEvent.ModifierFlags) -> MailFormattingKey? {
        guard flags.intersection([.command, .control, .option, .shift]) == .command else { return nil }
        switch characters?.lowercased() {
        case "b": return .bold
        case "i": return .italic
        case "u": return .underline
        case "]": return .increaseIndent
        case "[": return .decreaseIndent
        default: return nil
        }
    }

    @MainActor func run(_ commands: MailEditorCommands) {
        switch self {
        case .bold: commands.trait(.boldFontMask)
        case .italic: commands.trait(.italicFontMask)
        case .underline: commands.underline()
        case .increaseIndent: commands.indent(by: MailEditorCommands.indentStep)
        case .decreaseIndent: commands.indent(by: -MailEditorCommands.indentStep)
        }
    }
}
