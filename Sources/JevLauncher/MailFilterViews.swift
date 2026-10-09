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
