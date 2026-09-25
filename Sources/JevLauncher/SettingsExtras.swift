import AppKit
import Combine
import Contacts
import EventKit
import SwiftUI

/// A one-line caption with the full explanation behind an ⓘ popover, so panes stay short.
struct InfoCaption: View {
    let text: String
    let detail: String
    @State private var showing = false
    init(_ text: String, detail: String) { self.text = text; self.detail = detail }
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(text).font(.caption).foregroundStyle(.secondary)
            Button { showing.toggle() } label: { Image(systemName: "info.circle") }
                .buttonStyle(.borderless).font(.caption).foregroundStyle(.secondary)
                .help("More about this").accessibilityLabel("More about this")
                .popover(isPresented: $showing, arrowEdge: .bottom) {
                    Text(detail).font(.callout).frame(width: 300, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true).padding(12)
                }
        }
    }
}

/// A source permission that sources ask for on use: Calendars, Reminders, Contacts,
/// Full Disk Access, and Automation. Only the first three report a status to apps.
enum SourcePermissionRowKind: CaseIterable, Identifiable {
    case calendars, reminders, contacts, fullDiskAccess, automation
    var id: Self { self }
    var title: String {
        switch self {
        case .calendars: return "Calendars"; case .reminders: return "Reminders"; case .contacts: return "Contacts"
        case .fullDiskAccess: return "Full Disk Access"; case .automation: return "Automation"
        }
    }
    var purpose: String {
        switch self {
        case .calendars: return "Reads and adds events"
        case .reminders: return "Reads and adds reminders"
        case .contacts: return "Finds people"
        case .fullDiskAccess: return "Reads Apple Mail and browser history"
        case .automation: return "Asked the first time Mail or a browser is used"
        }
    }
    /// nil when macOS gives apps no way to read the status.
    @MainActor var isGranted: Bool? {
        switch self {
        case .calendars: return EKEventStore.authorizationStatus(for: .event) == .fullAccess
        case .reminders: return EKEventStore.authorizationStatus(for: .reminder) == .fullAccess
        case .contacts: return CNContactStore.authorizationStatus(for: .contacts) == .authorized
        case .fullDiskAccess, .automation: return nil
        }
    }
    /// True before the first request, while macOS can still show its prompt.
    @MainActor var isUndetermined: Bool {
        switch self {
        case .calendars: return EKEventStore.authorizationStatus(for: .event) == .notDetermined
        case .reminders: return EKEventStore.authorizationStatus(for: .reminder) == .notDetermined
        case .contacts: return CNContactStore.authorizationStatus(for: .contacts) == .notDetermined
        case .fullDiskAccess, .automation: return false
        }
    }
    var access: SourceAccess {
        switch self {
        case .calendars: return .calendars; case .reminders: return .reminders; case .contacts: return .contacts
        case .fullDiskAccess: return .fullDiskAccess; case .automation: return .automation("")
        }
    }
}

struct SourcePermissionRow: View {
    let kind: SourcePermissionRowKind
    @State private var granted: Bool?
    private let refresh = Timer.publish(every: 2, on: .main, in: .common).autoconnect()
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: granted == true ? "checkmark.circle.fill" : granted == nil ? "questionmark.circle" : "circle")
                .foregroundStyle(granted == true ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(kind.title)
                Text(granted == true ? "Allowed" : kind.purpose).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if granted != true {
                Button(granted == nil ? "Open Settings" : "Allow…") { Task { await Permissions.request(kind.access); granted = kind.isGranted } }
                    .controlSize(.small)
            }
        }
        .onAppear { granted = kind.isGranted }
        .onReceive(refresh) { _ in granted = kind.isGranted }
    }
}

/// A segmented picker for panes with several parts. The choice is stored, so the
/// window's height probe renders the same part the user sees.
struct PaneSections<Part: Hashable & CaseIterable & RawRepresentable>: View where Part.AllCases: RandomAccessCollection, Part.RawValue == String {
    @Binding var selection: Part
    var body: some View {
        Picker("", selection: $selection) {
            ForEach(Part.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented).labelsHidden()
        .frame(maxWidth: .infinity)
    }
}
