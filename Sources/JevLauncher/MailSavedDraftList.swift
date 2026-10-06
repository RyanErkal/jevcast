import SwiftUI

struct MailSavedDraftList: View {
    @ObservedObject var model: MailModel

    var body: some View {
        if !model.savedDrafts.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("On this Mac").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(model.savedDrafts) { saved in
                    Button { model.restoreSavedDraft(saved) } label: {
                        HStack {
                            Image(systemName: "doc.text")
                            VStack(alignment: .leading, spacing: 2) {
                                Text(saved.subject.isEmpty ? "Untitled draft" : saved.subject).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                Text(saved.to.isEmpty ? "No recipient" : saved.to).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            if model.draft?.id == saved.id { Text("Open").font(.caption).foregroundStyle(.secondary) }
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }.padding(12)
            Divider()
        }
    }
}
