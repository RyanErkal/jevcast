import Foundation
import SwiftUI
import LauncherCore

/// One recipient as it appears in a To, Cc, or Bcc chip.
struct MailRecipient: Codable, Equatable, Hashable, Identifiable, Sendable {
    let name: String
    let address: String

    var id: String { address.lowercased() }
    var contact: MailContact { MailContact(name: name, address: address) }
    var title: String { name.isEmpty ? address : "\(name) <\(address)>" }

    init(name: String = "", address: String) {
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.address = address.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
struct MailRecipientToken: Identifiable, Equatable, Sendable {
    let raw: String
    let recipient: MailRecipient?
    let problem: String?
    let index: Int

    var id: String { "\(index):\(raw)" }
    var isValid: Bool { recipient != nil }
}

/// Parsing and validation shared by the chip editor and send validation. It deliberately accepts
/// display names, but never treats an incomplete address as a valid recipient.
enum MailRecipientParser {
    static func tokens(_ value: String) -> [String] {
        var result: [String] = []
        var current = ""
        var quoted = false
        var angleDepth = 0
        for character in value {
            if character == "\"" { quoted.toggle() }
            if !quoted && character == "<" { angleDepth += 1 }
            if !quoted && character == ">" { angleDepth = max(0, angleDepth - 1) }
            if !quoted && angleDepth == 0 && (character == "," || character == ";" || character.isNewline) {
                let token = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !token.isEmpty { result.append(token) }
                current = ""
            } else {
                current.append(character)
            }
        }
        let token = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !token.isEmpty { result.append(token) }
        return result
    }

    static func parse(_ value: String) -> [MailRecipientToken] {
        tokens(value).enumerated().map { index, raw in
            guard let parsed = parseOne(raw) else {
                return MailRecipientToken(raw: raw, recipient: nil,
                                          problem: "\u{201c}\(raw)\u{201d} is not an email address.", index: index)
            }
            return MailRecipientToken(raw: raw, recipient: parsed, problem: nil, index: index)
        }
    }

    static func parseOne(_ value: String) -> MailRecipient? {
        let parts = MailAddress.list(value)
        guard parts.count == 1, let part = parts.first else { return nil }
        let address = part.address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isAddress(address) else { return nil }
        return MailRecipient(name: part.name, address: address)
    }

    static func isAddress(_ address: String) -> Bool {
        guard !address.isEmpty, !address.contains(where: { $0.isWhitespace || $0.isNewline }),
              address.split(separator: "@", omittingEmptySubsequences: false).count == 2,
              let at = address.firstIndex(of: "@"), at != address.startIndex,
              at < address.index(before: address.endIndex) else { return false }
        return !address.contains(where: { $0 == "<" || $0 == ">" || $0 == "\"" || $0 == "\0" })
    }

    static func problem(_ value: String, required: Bool) -> String? {
        let values = parse(value)
        if values.isEmpty { return required ? "Add a recipient." : nil }
        return values.first(where: { !$0.isValid })?.problem
    }

    static func serialize(_ recipients: [MailRecipient]) -> String {
        recipients.map { recipient in
            guard !recipient.name.isEmpty,
                  recipient.name.caseInsensitiveCompare(recipient.address) != .orderedSame else {
                return recipient.address
            }
            let name = recipient.name.rangeOfCharacter(from: CharacterSet(charactersIn: ",;\"<>") ) == nil
                ? recipient.name
                : "\"" + recipient.name.replacingOccurrences(of: "\"", with: "'") + "\""
            return "\(name) <\(recipient.address)>"
        }.joined(separator: ", ")
    }

    static func normalize(_ value: String) -> String {
        serialize(parse(value).compactMap(\.recipient))
    }
}
/// A recipient suggestion is either explicitly permitted Contacts data or data already present
/// in this local mail store. No provider or network lookup is performed.
struct MailRecipientSuggestion: Identifiable, Equatable, Sendable {
    enum Source: String, Equatable, Sendable { case localMail, contacts, alias }

    let contact: MailContact
    let source: Source
    var id: String { contact.address.lowercased() }
    var title: String { contact.name.isEmpty ? contact.address : "\(contact.name) <\(contact.address)>" }
}

/// Pending typing is part of the saved header immediately, even before Return or a focus change.
struct MailRecipientEditingState {
    var committed: String
    var pending = ""

    var header: String { [committed, pending].filter { !$0.isEmpty }.joined(separator: ", ") }

    mutating func commit() {
        committed = MailRecipientParser.tokens(header).joined(separator: ", ")
        pending = ""
    }

    mutating func remove(_ token: MailRecipientToken) {
        committed = MailRecipientParser.parse(committed).filter { $0.id != token.id }.map(\.raw).joined(separator: ", ")
    }

    mutating func choose(_ contact: MailContact) {
        pending = MailRecipientParser.serialize([MailRecipient(name: contact.name, address: contact.address)])
        commit()
    }
}

/// A compact chip field that keeps the draft's persisted representation as a normal header string.
/// Invalid tokens stay visible in red and can be removed or edited; they are never silently fixed.
struct MailRecipientChipField: View {
    let placeholder: String
    @Binding var value: String
    let suggestionProvider: (String) -> [MailRecipientSuggestion]
    let requestContacts: ((String) async -> [MailRecipientSuggestion])?
    @FocusState private var focused: Bool
    @State private var editor: MailRecipientEditingState
    @State private var contactsBusy = false
    @State private var contacts = [MailRecipientSuggestion]()

    init(_ placeholder: String, value: Binding<String>, suggestions: @escaping (String) -> [MailRecipientSuggestion],
         requestContacts: ((String) async -> [MailRecipientSuggestion])? = nil) {
        self.placeholder = placeholder
        _value = value
        _editor = State(initialValue: MailRecipientEditingState(committed: value.wrappedValue))
        self.suggestionProvider = suggestions
        self.requestContacts = requestContacts
    }

    private var currentSuggestions: [MailRecipientSuggestion] {
        let query = editor.pending.trimmingCharacters(in: .whitespacesAndNewlines)
        guard focused, !query.isEmpty else { return [] }
        let local = suggestionProvider(query)
        var seen = Set<String>()
        return Array((local + contacts).filter { seen.insert($0.id).inserted && !editor.committed.lowercased().contains($0.contact.address.lowercased()) }.prefix(6))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(MailRecipientParser.parse(editor.committed)) { token in
                        chip(token)
                    }
                    TextField(placeholder, text: Binding(get: { editor.pending }, set: {
                        editor.pending = $0
                        value = editor.header
                    }))
                        .textFieldStyle(.plain)
                        .focused($focused)
                        .frame(minWidth: 100)
                        .onSubmit { commit() }
                }
                .padding(.vertical, 2)
            }
            if focused && (!currentSuggestions.isEmpty || requestContacts != nil) {
                HStack(spacing: 6) {
                    ForEach(currentSuggestions) { suggestion in
                        Button(suggestion.title) { add(suggestion.contact) }
                            .buttonStyle(.bordered).controlSize(.mini)
                    }
                    if requestContacts != nil && contacts.isEmpty {
                        Button(contactsBusy ? "Loading Contacts…" : "Allow Contacts") {
                            guard !contactsBusy, let requestContacts else { return }
                            contactsBusy = true
                            Task { @MainActor in
                                contacts = await requestContacts(editor.pending)
                                contactsBusy = false
                            }
                        }
                        .buttonStyle(.link).controlSize(.small).disabled(contactsBusy)
                        .help("Contacts are only read after you choose Allow Contacts.")
                    }
                }
            }
            let invalid = MailRecipientParser.parse(value).compactMap(\.problem).first
            if let invalid {
                Text(invalid).font(.caption2).foregroundStyle(.red)
            }
        }
        .onChange(of: focused) { _, active in if !active { commit() } }
        .onChange(of: value) { _, header in
            if header != editor.header { editor = MailRecipientEditingState(committed: header) }
        }
    }

    @ViewBuilder
    private func chip(_ token: MailRecipientToken) -> some View {
        HStack(spacing: 3) {
            Image(systemName: token.isValid ? "person.crop.circle" : "exclamationmark.triangle")
            Text(token.recipient?.title ?? token.raw).lineLimit(1)
            Button { remove(token) } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.plain).accessibilityLabel("Remove recipient")
        }
        .font(.caption)
        .padding(.horizontal, 6).padding(.vertical, 3)
        .foregroundStyle(token.isValid ? Color.primary : Color.red)
        .background((token.isValid ? Color.accentColor : Color.red).opacity(0.12), in: Capsule())
        .onTapGesture {
            editor.commit()
            editor.remove(token)
            editor.pending = token.raw
            value = editor.header
            focused = true
        }
    }

    private func remove(_ token: MailRecipientToken) {
        editor.remove(token)
        value = editor.header
    }

    private func commit() {
        editor.commit()
        value = editor.header
    }

    private func add(_ contact: MailContact) {
        editor.choose(contact)
        value = editor.header
        focused = true
    }
}
