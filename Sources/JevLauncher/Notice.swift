/// The one inline message the launcher shows above its footer.
struct Notice: Equatable {
    enum Tone { case warning, info }
    enum Action: Equatable {
        case allowAccessibility
        /// Asks macOS for a source's permission, or opens the Settings pane that grants it.
        case grant(SourceAccess)
        var title: String {
            switch self {
            case .allowAccessibility: return "Allow"
            case .grant(let access): return access.buttonTitle
            }
        }
    }
    let symbol: String
    let text: String
    let tone: Tone
    var action: Action? = nil
}

/// A permission a source needs before it can list anything.
enum SourceAccess: Equatable {
    case calendars, reminders, contacts
    /// Apple Events to one app, by bundle ID.
    case automation(String)
    case fullDiskAccess
    var buttonTitle: String {
        switch self {
        case .calendars, .reminders, .contacts: return "Allow"
        case .automation, .fullDiskAccess: return "Open Settings"
        }
    }
}
