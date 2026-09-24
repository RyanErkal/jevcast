import SwiftUI

struct SearchSettings: View {
    @ObservedObject var preferences: Preferences
    @ObservedObject var catalogue: AppCatalogue
    /// The sheet on screen: a new keyword, an existing keyword, or a new alias.
    private enum Sheet: Identifiable {
        case keyword(Quicklink?), alias
        var id: String {
            switch self {
            case .keyword(let link): return "keyword:" + (link?.id ?? "")
            case .alias: return "alias"
            }
        }
    }
    @State private var sheet: Sheet?

    private struct AliasRow: Identifiable { let id: String; let app: String }
    private var aliasRows: [AliasRow] {
        preferences.aliases.keys.sorted().map { key in
            AliasRow(id: key, app: catalogue.entries.first { $0.id == preferences.aliases[key] }?.name ?? "App unavailable")
        }
    }
    private var missingDefaults: [Quicklink] {
        let existing = Set(preferences.quicklinks.map(\.id))
        return Quicklink.defaults.filter { !existing.contains($0.id) }
    }
    var body: some View {
        Form {
            Section {
                FolderList(folders: $preferences.fileFolders, emptyText: "No folders. Add one to search files.")
                Text("File search stays inside these folders. Results depend on Spotlight indexing.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("File search folders") }
            Section {
                if aliasRows.isEmpty { Text("No aliases").foregroundStyle(.secondary) }
                ForEach(aliasRows) { row in
                    HStack(spacing: 8) {
                        Text(row.id).fontWeight(.medium)
                        Image(systemName: "arrow.right").font(.caption).foregroundStyle(.tertiary).accessibilityHidden(true)
                        Text(row.app).foregroundStyle(.secondary)
                        Spacer()
                        RemoveButton(label: "Remove alias " + row.id) { preferences.aliases.removeValue(forKey: row.id) }
                    }
                }
                HStack {
                    AddButton(title: "Add alias…") { sheet = .alias }
                    Spacer()
                }
            } header: { Text("App aliases") }
            Section {
                if preferences.hiddenApps.isEmpty { Text("No hidden apps. ⌘K on an app offers Hide from Search.").foregroundStyle(.secondary) }
                ForEach(preferences.hiddenApps, id: \.self) { id in
                    HStack {
                        Text(catalogue.entries.first { $0.id == id }?.name ?? (id.split(separator: "/").last.map(String.init) ?? id))
                        Spacer()
                        Button("Show Again") { preferences.hiddenApps.removeAll { $0 == id } }.controlSize(.small)
                    }
                }
            } header: { Text("Hidden apps") }
            Section {
                if preferences.quicklinks.isEmpty { Text("No search keywords").foregroundStyle(.secondary) }
                ForEach(preferences.quicklinks) { link in
                    HStack(spacing: 8) {
                        Button { sheet = .keyword(link) } label: { KeywordLabel(link: link) }
                            .buttonStyle(.plain)
                            .help("Edit keyword")
                        RemoveButton(label: "Remove keyword " + link.keyword) { preferences.quicklinks.removeAll { $0.id == link.id } }
                    }
                }
                HStack {
                    AddButton(title: "Add keyword…") { sheet = .keyword(nil) }
                    Spacer()
                    if !missingDefaults.isEmpty {
                        Button("Restore defaults") { preferences.quicklinks += missingDefaults }.controlSize(.small)
                    }
                }
                Text("Type a keyword and a search in the launcher, for example “gh swiftui”.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("Search keywords") }
            Section {
                // Disclosed content is one cell in a grouped Form, so stack and divide the rows here.
                DisclosureGroup("Advanced") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Additional app folders").font(.caption).foregroundStyle(.secondary)
                        FolderList(folders: $preferences.appFolders, emptyText: "No additional app folders", addTitle: "Add app folder…") {
                            catalogue.refresh(extra: preferences.appFolders)
                        }
                        Divider()
                        HStack {
                            Text(catalogue.scanning ? "Finding apps…" : "\(catalogue.entries.count) apps found. Standard app folders are always included.")
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("Refresh") { catalogue.refresh(extra: preferences.appFolders) }.controlSize(.small)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 8)
                }
            }
        }
        .formStyle(.grouped)
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .keyword(let link):
                KeywordSheet(original: link, existing: preferences.quicklinks) { saved in
                    if let link, let index = preferences.quicklinks.firstIndex(where: { $0.id == link.id }) {
                        preferences.quicklinks[index] = saved
                    } else {
                        preferences.quicklinks.append(saved)
                    }
                }
            case .alias:
                AliasSheet(apps: catalogue.entries) { alias, app in preferences.aliases[alias] = app }
            }
        }
    }
}

/// `keyword · Name · host` for one search keyword row.
private struct KeywordLabel: View {
    let link: Quicklink
    private var host: String {
        let base = URL(string: link.template.replacingOccurrences(of: Quicklink.placeholder, with: ""))?.host ?? link.template
        return base.hasPrefix("www.") ? String(base.dropFirst(4)) : base
    }
    var body: some View {
        HStack(spacing: 6) {
            Text(link.keyword).fontWeight(.medium)
            Text("·").foregroundStyle(.tertiary)
            Text(link.name)
            Text("·").foregroundStyle(.tertiary)
            Text(host).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
