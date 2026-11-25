import Foundation
import SwiftUI
import LauncherCore

struct MailFilterEditor: View {
    @ObservedObject var model: MailModel
    @State private var draft: MailFilter
    @Environment(\.dismiss) private var dismiss

    init(model: MailModel) {
        self.model = model
        _draft = State(initialValue: model.filter)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Filter Mail").font(.headline)
            HStack {
                TextField("From", text: $draft.from)
                TextField("To", text: $draft.to)
            }
            HStack {
                Menu {
                    ForEach(model.accounts, id: \.self) { account in
                        Button {
                            if !draft.accountIDs.insert(account).inserted { draft.accountIDs.remove(account) }
                        } label: {
                            Label(model.accountTitle(account), systemImage: draft.accountIDs.contains(account) ? "checkmark" : "circle")
                        }
                    }
                } label: { Label(draft.accountIDs.isEmpty ? "Any account" : "\(draft.accountIDs.count) accounts", systemImage: "person.crop.circle") }
                Menu {
                    Button("Any folder") { draft.mailboxIDs.removeAll() }
                    ForEach(model.mailboxes) { box in
                        Button {
                            if !draft.mailboxIDs.insert(box.rowID).inserted { draft.mailboxIDs.remove(box.rowID) }
                        } label: {
                            Label("\(model.accountTitle(box.accountID)) · \(box.name)", systemImage: draft.mailboxIDs.contains(box.rowID) ? "checkmark" : "circle")
                        }
                    }
                } label: { Label(draft.mailboxIDs.isEmpty ? "Any folder" : "\(draft.mailboxIDs.count) folders", systemImage: "folder") }
            }
            HStack {
                Toggle("Unread", isOn: $draft.unreadOnly)
                Toggle("Flagged", isOn: $draft.flaggedOnly)
                Toggle("Attachments", isOn: $draft.attachmentsOnly)
            }
            MailFilterCoverageText(filter: draft)
            HStack {
                Toggle("After", isOn: Binding(get: { draft.dateFrom != nil }, set: { draft.dateFrom = $0 ? Calendar.current.startOfDay(for: Date()) : nil }))
                if draft.dateFrom != nil {
                    DatePicker("", selection: Binding(get: { draft.dateFrom ?? Date() }, set: { draft.dateFrom = $0 }), displayedComponents: .date).labelsHidden()
                }
            }
            HStack {
                Toggle("Before", isOn: Binding(get: { draft.dateTo != nil }, set: { draft.dateTo = $0 ? Calendar.current.date(bySettingHour: 23, minute: 59, second: 59, of: Date()) : nil }))
                if draft.dateTo != nil {
                    DatePicker("", selection: Binding(get: { draft.dateTo ?? Date() }, set: { date in draft.dateTo = Calendar.current.date(bySettingHour: 23, minute: 59, second: 59, of: date) ?? date }), displayedComponents: .date).labelsHidden()
                }
            }
            HStack {
                if !draft.isEmpty { Button("Clear") { draft.clear() }.buttonStyle(.link) }
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Apply") { model.setFilter(draft); dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 390)
    }
}

/// Explains the limits of MIME-dependent filters. A missing body is not a negative result,
/// so the list tools report a lower bound until those rows are downloaded.
struct MailFilterCoverageText: View {
    let filter: MailFilter
    var matchCount: Int?
    var metadataUnknownCount: Int?
    var recipientUnknownCount: Int?
    var attachmentUnknownCount: Int?

    init(filter: MailFilter, matchCount: Int? = nil, metadataUnknownCount: Int? = nil,
         recipientUnknownCount: Int? = nil, attachmentUnknownCount: Int? = nil) {
        self.filter = filter
        self.matchCount = matchCount
        self.metadataUnknownCount = metadataUnknownCount
        self.recipientUnknownCount = recipientUnknownCount
        self.attachmentUnknownCount = attachmentUnknownCount
    }

    var body: some View {
        if filter.requiresBodyMetadata {
            VStack(alignment: .leading, spacing: 3) {
                Text(filter.bodyMetadataCoverageDescription)
                    .font(.caption).foregroundStyle(.secondary)
                if let matchCount, let metadataUnknownCount {
                    if metadataUnknownCount > 0 {
                        Text(lowerBoundText(matchCount: matchCount, unknownCount: metadataUnknownCount))
                            .font(.caption).foregroundStyle(.orange)
                    } else {
                        Text("\(matchCount) matches")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func lowerBoundText(matchCount: Int, unknownCount: Int) -> String {
        var fields: [String] = []
        if let recipientUnknownCount, recipientUnknownCount > 0 {
            fields.append("\(recipientUnknownCount) recipient-field row\(recipientUnknownCount == 1 ? "" : "s")")
        }
        if let attachmentUnknownCount, attachmentUnknownCount > 0 {
            fields.append("\(attachmentUnknownCount) attachment-field row\(attachmentUnknownCount == 1 ? "" : "s")")
        }
        let unknownRows = "\(unknownCount) row\(unknownCount == 1 ? "" : "s") with unknown body metadata"
        let fieldDetail = fields.isEmpty ? unknownRows : fields.joined(separator: ", ") + "; " + unknownRows
        return "At least \(matchCount) matches · \(fieldDetail). Results are a lower bound."
    }
}

/// One-click filters under the list's title: Unread, Flagged, and Attachments set the same fields
/// as the filter form and apply at once. "+N" counts the form's other filters and opens it; × clears
/// every filter. The row is always there, so the list never moves when a filter turns on.
struct MailFilterChips: View {
    @ObservedObject var model: MailModel
    @State private var showingForm = false

    static let height: CGFloat = 22

    var body: some View {
        HStack(spacing: 5) {
            ViewThatFits(in: .horizontal) {
                chips(titles: true)
                chips(titles: false)
            }
            Spacer(minLength: 0)
            if model.filterIsActive {
                Button { model.clearFilters() } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Clear filters").accessibilityLabel("Clear filters")
            }
        }
        .frame(height: Self.height)
    }

    private func chips(titles: Bool) -> some View {
        HStack(spacing: 5) {
            ForEach(MailFilterChip.allCases, id: \.self) { chip in
                let on = chip.isOn(model.filter)
                Button { model.setFilter(chip.toggled(model.filter)) } label: {
                    if titles { Text(chip.title) } else { Image(systemName: Self.symbol(chip)) }
                }
                .buttonStyle(MailChipStyle(on: on))
                .help(on ? "Show all mail again" : "Show only \(chip.title.lowercased()) mail")
                .accessibilityLabel(chip.title).accessibilityAddTraits(on ? [.isSelected] : [])
            }
            let others = MailFilterChip.otherCount(model.filter)
            if others > 0 {
                Button("+\(others)") { showingForm = true }
                    .buttonStyle(MailChipStyle(on: true))
                    .help("\(others) more filter\(others == 1 ? "" : "s"). Click to edit them.")
                    .popover(isPresented: $showingForm, arrowEdge: .bottom) { MailFilterEditor(model: model) }
            }
        }
    }

    static func symbol(_ chip: MailFilterChip) -> String {
        switch chip {
        case .unread: return "envelope.badge"
        case .flagged: return "flag"
        case .attachments: return "paperclip"
        }
    }
}

/// A small capsule that reads as on or off.
struct MailChipStyle: ButtonStyle {
    let on: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: MailStyle.meta, weight: on ? .semibold : .regular)).lineLimit(1).fixedSize()
            .foregroundStyle(on ? Color.accentColor : Color.secondary)
            .padding(.horizontal, 8).frame(height: 20)
            .background(Capsule().fill(on ? Color.accentColor.opacity(configuration.isPressed ? 0.3 : 0.18)
                                          : Color.primary.opacity(configuration.isPressed ? 0.14 : 0.06)))
            .contentShape(Capsule())
    }
}

struct MailFilterButton: View {
    @ObservedObject var model: MailModel
    @State private var showing = false

    var body: some View {
        Button { showing.toggle() } label: {
            Label("Filter", systemImage: model.filterIsActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        }
        .buttonStyle(.borderless)
        .popover(isPresented: $showing, arrowEdge: .bottom) { MailFilterEditor(model: model) }
        .help(model.filterIsActive ? "Edit mail filters (\(model.filter.activeCount) active)" : "Filter mail")
    }
}
